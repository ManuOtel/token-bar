#!/usr/bin/env python3
"""Export a sanitized OpenCode token-only snapshot from a local SQLite file.

Reads the OpenCode database strictly read-only (`mode=ro`, no writes, no
network) and emits a JSON array of normalized token records only:

  id, source ("opencode"), timestamp (UTC ISO8601), model ("provider/id"),
  inputTokens, outputTokens, cachedTokens, reasoningTokens, totalTokens,
  sessionId, requestId, origin

Never emits prompts, tool calls, file paths, credentials, or message text.
Only token counts, timestamps, model labels, and session/message IDs leave
the host. Copy the resulting file to the Mac yourself (for example with a
USB stick or any file copy you operate); Token Bar never fetches it.

Semantics mirror `OpenCodeStore` in Swift exactly:
- Per-message tables (`message`, `session_message`) are authoritative with
  message-time attribution (nested `data.time.created` beats flat columns).
- Per-session rollups (`session_v2`, `session`) fill only sessions with zero
  message rows (never summed over covered messages).
- Mirror selection on both levels: larger `totalTokens` wins (stale mirror
  never shadows fresh data); exact ties break to the earliest
  `(timestamp, id)` so repeated exports agree byte-for-byte.
- Rows without a message ID get deterministic content-hashed fallback IDs
  (FNV-1a over the sorted column projection, same contract as
  `OpenCodeStore.stableRowHash`); identical rows share an ID, distinct rows
  stay distinct.

Usage:
  python3 scripts/export-opencode-usage.py --db ~/.local/share/opencode/opencode.db \\
      --out /tmp/opencode-usage.json --origin homeserver
  # On the Mac:
  TOKENBAR_OPENCODE_USAGE_JSON=/tmp/opencode-usage.json ./scripts/show-usage.sh --preset 7d
"""
import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone


MESSAGE_TABLES = ("message", "session_message")
ROLLUP_TABLES = ("session_v2", "session")


def parse_ts(raw):
    if raw is None:
        return None
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        v = float(raw)
        if v > 10_000_000_000:
            v /= 1000.0
        if v > 1_000_000_000:
            return datetime.fromtimestamp(v, tz=timezone.utc)
        return None
    if isinstance(raw, str):
        s = raw.strip()
        if not s:
            return None
        try:
            f = float(s)
            if f > 1_000_000_000:
                return parse_ts(f)
        except ValueError:
            pass
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        except ValueError:
            return None
    return None


def get(d, *keys):
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    low = {str(k).lower(): v for k, v in d.items()}
    for k in keys:
        if k in low and low[k] is not None:
            return low[k]
    return None


def to_int(v):
    if v is None or isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v)
    try:
        return int(str(v))
    except ValueError:
        try:
            return int(float(str(v)))
        except ValueError:
            return None


def model_label(raw):
    if raw is None:
        return None
    s = str(raw).strip()
    if not s:
        return None
    if not s.startswith("{"):
        return s
    try:
        obj = json.loads(s)
    except (json.JSONDecodeError, ValueError):
        return s
    if isinstance(obj, str) and obj:
        return obj
    if not isinstance(obj, dict):
        return s
    mid = obj.get("id") or obj.get("model") or obj.get("name")
    prov = obj.get("providerID") or obj.get("providerId") or obj.get("provider")
    variant = obj.get("variant")
    if prov and mid:
        return f"{prov}/{mid}"
    return mid or prov or variant


def fnv1a_hex(cols):
    h = 14695981039346656037
    for key in sorted(cols):
        v = cols[key]
        for byte in f"{key}={v if v is not None else 'null'}".encode("utf-8"):
            h ^= byte
            h = (h * 1099511628211) % (1 << 64)
    return f"{h:016x}"


def fallback_message_id(table, cols, msg_id, session, ts_epoch):
    if msg_id:
        return f"{table}:{msg_id}:{ts_epoch}"
    sess = session if session else "nosession"
    return f"{table}:{sess}:{ts_epoch}:{fnv1a_hex(cols)}"


def decode_rollup(cols, table, origin):
    merged = {}
    for k, v in cols.items():
        if v is None or v == "":
            continue
        try:
            merged[k] = int(v)
            continue
        except (ValueError, TypeError):
            pass
        try:
            merged[k] = float(v)
            continue
        except (ValueError, TypeError):
            pass
        merged[k] = v
    for blob_key in ("data", "payload", "info", "value", "content", "meta"):
        raw = cols.get(blob_key)
        if not raw:
            continue
        try:
            blob = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(blob, dict):
            for k, v in blob.items():
                merged.setdefault(k.lower(), v)
                merged.setdefault(k, v)
    ts = parse_ts(get(merged, "timestamp", "time", "time_created", "timecreated",
                        "created_at", "createdat", "createdAt", "created",
                        "updated_at", "updatedat", "updated", "time_updated",
                        "timeupdated", "date"))
    if ts is None:
        return None
    raw_in = to_int(get(merged, "input_tokens", "inputtokens", "prompt_tokens",
                          "prompttokens", "tokens_input", "tokensinput", "input"))
    out = to_int(get(merged, "output_tokens", "outputtokens", "completion_tokens",
                       "completiontokens", "tokens_output", "tokensoutput", "output"))
    c_read = to_int(get(merged, "cached_tokens", "cachedtokens", "cached_input_tokens",
                          "cachedinputtokens", "tokens_cache_read", "tokenscacheread"))
    c_write = to_int(get(merged, "cache_write_input_tokens", "cachewriteinputtokens",
                           "tokens_cache_write", "tokenscachewrite"))
    c = None if (c_read is None and c_write is None) else (c_read or 0) + (c_write or 0)
    i = None if (raw_in is None and c is None) else (raw_in or 0) + (c or 0)
    r = to_int(get(merged, "reasoning_tokens", "reasoningtokens",
                     "reasoning_output_tokens", "reasoningoutputtokens",
                     "tokens_reasoning", "tokensreasoning"))
    tot = to_int(get(merged, "total_tokens", "totaltokens", "tokens_total",
                       "tokenstotal", "total", "tokens"))
    if all(v is None for v in (i, out, c, r, tot)):
        return None
    i, out = i or 0, out or 0
    tot_val = tot if isinstance(tot, (int, float)) and tot > 0 else None
    session = get(merged, "session_id", "sessionid", "session", "id", "key") or ""
    request = get(merged, "request_id", "requestid", "message_id", "rowid") or ""
    if not request and session:
        request = f"{session}#{int(ts.timestamp())}"
    cc = min(max(0, c or 0), i)
    rec_id = "opencode:" + request if request else \
        f"opencode:{table}:{session if session else 'nosession'}:{int(ts.timestamp())}"
    return {"id": rec_id, "source": "opencode", "ts": ts,
            "model": model_label(get(merged, "model", "model_name")) or "unknown",
            "input": i, "output": out, "cached": cc, "reasoning": r or 0,
            "total": tot_val if tot_val else i + out,
            "session": session, "request": request, "origin": origin}


def _msg_int_blob(blob, keys):
    if not isinstance(blob, dict):
        return None
    for k in keys:
        v = blob.get(k)
        if isinstance(v, bool):
            continue
        if isinstance(v, (int, float)):
            return int(v)
        try:
            return int(str(v))
        except (ValueError, TypeError):
            try:
                return int(float(str(v)))
            except (ValueError, TypeError):
                continue
    return None


def decode_message(cols, table, origin):
    blob = {}
    raw = cols.get("data")
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                blob = parsed
        except (json.JSONDecodeError, ValueError):
            pass
    role = cols.get("type") or cols.get("role") or blob.get("role") or blob.get("type")
    if role and "assistant" not in str(role).lower():
        return None
    tokens = blob.get("tokens") if isinstance(blob.get("tokens"), dict) else {}
    cache = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
    nested_in = _msg_int_blob(tokens, ("input", "input_tokens", "tokens_input"))
    nested_out = _msg_int_blob(tokens, ("output", "output_tokens", "tokens_output"))
    nested_re = _msg_int_blob(tokens, ("reasoning", "reasoning_tokens", "tokens_reasoning"))
    nested_cr = _msg_int_blob(cache, ("read", "input_tokens", "tokens_cache_read"))
    nested_cw = _msg_int_blob(cache, ("write", "tokens_cache_write"))
    nested_tot = _msg_int_blob(tokens, ("total", "total_tokens", "tokens_total"))
    flat_in = to_int(get(cols, "input_tokens", "inputtokens", "prompt_tokens", "prompttokens",
                          "tokens_input", "tokensinput", "input"))
    flat_out = to_int(get(cols, "output_tokens", "outputtokens", "completion_tokens",
                            "completiontokens", "tokens_output", "tokensoutput", "output"))
    flat_cr = to_int(get(cols, "cached_tokens", "cachedtokens", "cached_input_tokens",
                          "cachedinputtokens", "tokens_cache_read", "tokenscacheread"))
    flat_cw = to_int(get(cols, "cache_write_input_tokens", "cachewriteinputtokens",
                          "tokens_cache_write", "tokenscachewrite"))
    flat_re = to_int(get(cols, "reasoning_tokens", "reasoningtokens",
                          "reasoning_output_tokens", "reasoningoutputtokens",
                          "tokens_reasoning", "tokensreasoning"))
    flat_tot = to_int(get(cols, "total_tokens", "totaltokens", "tokens_total",
                            "tokenstotal", "total", "tokens"))
    raw_in = nested_in if nested_in is not None else flat_in
    out = nested_out if nested_out is not None else flat_out
    cr = nested_cr if nested_cr is not None else flat_cr
    cw = nested_cw if nested_cw is not None else flat_cw
    c = None if (cr is None and cw is None) else (cr or 0) + (cw or 0)
    i = None if (raw_in is None and c is None) else (raw_in or 0) + (c or 0)
    r = nested_re if nested_re is not None else flat_re
    tot = nested_tot if nested_tot is not None else flat_tot
    if all(v is None for v in (i, out, c, r, tot)):
        return None
    t = blob.get("time") if isinstance(blob.get("time"), dict) else {}
    ts = (parse_ts(t.get("created")) or parse_ts(t.get("completed"))
          or parse_ts(t.get("updated"))
          or parse_ts(get(cols, "time_created", "timecreated", "created_at", "createdat",
                           "created", "time_updated", "timeupdated", "updated_at",
                           "updatedat", "updated", "timestamp", "time")))
    if ts is None:
        return None
    mid = blob.get("modelID") or blob.get("modelId") or blob.get("model_id")
    prov = blob.get("providerID") or blob.get("providerId") or blob.get("provider")
    model = None
    if isinstance(mid, str) and mid:
        model = f"{prov}/{mid}" if isinstance(prov, str) and prov else mid
    if model is None and isinstance(blob.get("model"), dict):
        m = blob["model"]
        m_id = m.get("id") or m.get("model") or m.get("name")
        m_prov = m.get("providerID") or m.get("providerId") or m.get("provider")
        if m_id and m_prov:
            model = f"{m_prov}/{m_id}"
        else:
            model = m_id or m_prov
    if model is None:
        model = model_label(get(blob, "model", "model_name")
                            or get(cols, "model", "model_name"))
    session = cols.get("session_id") or cols.get("sessionid") or cols.get("session") or ""
    if not session:
        for k in ("session_id", "sessionId", "sessionid", "session"):
            v = blob.get(k)
            if isinstance(v, str) and v:
                session = v
                break
    msg_id = ""
    for k in ("id", "message_id", "messageid", "messageId"):
        v = blob.get(k)
        if isinstance(v, str) and v:
            msg_id = v
            break
    if not msg_id:
        msg_id = cols.get("id") or cols.get("message_id") or cols.get("messageid") or ""
    i, out = i or 0, out or 0
    cc = min(max(0, c or 0), i)
    tot_val = tot if isinstance(tot, (int, float)) and tot > 0 else None
    rec = {"ts": ts, "model": model or "unknown",
           "input": i, "output": out, "cached": cc, "reasoning": r or 0,
           "total": tot_val if tot_val else i + out,
           "session": session, "request": msg_id or "",
           "id": "opencode:" + fallback_message_id(
               table, {k: (None if v is None else str(v)) for k, v in cols.items()},
               msg_id or "", session, int(ts.timestamp())),
           "source": "opencode", "origin": origin}
    if all(rec[k] == 0 for k in ("input", "output", "cached", "reasoning", "total")):
        return None
    return rec


def mirror_winner(seen, candidate):
    # Mirror of OpenCodeStore.mirrorWinner: larger total wins; ties break to
    # the earliest (timestamp, id), then to the lexically smallest origin.
    if candidate["total"] != seen["total"]:
        return candidate if candidate["total"] > seen["total"] else seen
    if (candidate["ts"], candidate.get("id", "")) != (seen["ts"], seen.get("id", "")):
        return candidate if (candidate["ts"], candidate.get("id", "")) < (seen["ts"], seen.get("id", "")) else seen
    return candidate if candidate["origin"] < seen["origin"] else seen


def select_mirror(best, key, candidate):
    seen = best.get(key)
    if seen is None:
        best[key] = candidate
        return
    best[key] = mirror_winner(seen, candidate)


def combine(messages, rollups):
    covered = {m["session"] for m in messages if m["session"]}
    best_msg, best_roll, passthrough = {}, {}, []
    for m in messages:
        if not m["request"]:
            passthrough.append(m)
        else:
            select_mirror(best_msg, "opencode:" + m["request"], m)
    for r in rollups:
        if covered and r["session"] and r["session"] in covered:
            continue
        if not r["request"]:
            passthrough.append(r)
        else:
            select_mirror(best_roll, "opencode:" + r["request"], r)
    return sorted(passthrough + list(best_msg.values()) + list(best_roll.values()),
                  key=lambda rec: (rec["ts"], rec.get("id", "")))


def read_table(conn, table):
    try:
        cur = conn.execute(f'SELECT * FROM "{table}"')
    except sqlite3.Error:
        return [], 0
    names = [d[0].lower() for d in cur.description]
    rows = []
    for raw_row in cur.fetchall():
        cols = {}
        for name, value in zip(names, raw_row):
            if value is None:
                cols[name] = None
            elif isinstance(value, bytes):
                try:
                    cols[name] = value.decode("utf-8", errors="replace")
                except Exception:
                    cols[name] = None
            else:
                cols[name] = str(value)
        rows.append(cols)
    return rows, 0


def export_db(db_path, origin):
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        messages, rollups, skipped = [], [], 0
        for table in MESSAGE_TABLES:
            rows, _ = read_table(conn, table)
            for cols in rows:
                rec = decode_message(cols, table, origin)
                if rec is None:
                    skipped += 1
                else:
                    messages.append(rec)
        for table in ROLLUP_TABLES:
            rows, _ = read_table(conn, table)
            for cols in rows:
                rec = decode_rollup(cols, table, origin)
                if rec is None:
                    skipped += 1
                else:
                    rollups.append(rec)
    finally:
        conn.close()
    return combine(messages, rollups), skipped


def to_snapshot(rec):
    ts = rec["ts"]
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    iso = ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    return {
        "id": rec["id"],
        "source": "opencode",
        "timestamp": iso,
        "model": rec["model"],
        "inputTokens": rec["input"],
        "outputTokens": rec["output"],
        "cachedTokens": rec["cached"],
        "reasoningTokens": rec["reasoning"],
        "totalTokens": rec["total"],
        "sessionId": rec["session"],
        "requestId": rec["request"],
        "origin": rec["origin"],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description="Export sanitized OpenCode token snapshot (read-only).")
    parser.add_argument("--db", required=True, help="OpenCode SQLite path (opened read-only).")
    parser.add_argument("--out", required=True, help="Output JSON path for the sanitized snapshot.")
    parser.add_argument("--origin", default="homeserver", help="Origin label for exported rows.")
    args = parser.parse_args(argv)
    origin = args.origin.strip() or "homeserver"
    records, skipped = export_db(args.db, origin)
    payload = [to_snapshot(r) for r in records]
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
    total = sum(r["total"] for r in records)
    print(f"exported {len(records)} records ({total} tokens), skipped {skipped} rows -> {args.out}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
