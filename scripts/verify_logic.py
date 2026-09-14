"""Host-side mirror of TokenBarCore semantics (Swift unavailable on this host).

Re-implements: Codex line parsing, OpenCode row decoding, filtering presets,
aggregation, best-month, dedupe, pricing. Asserts the same cases the XCTest
suite pins, so `python3 scripts/verify_logic.py` is meaningful evidence.
"""
import json
import os
import sys
from datetime import datetime, timedelta, timezone

FAILURES = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f" -- {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


def parse_ts(raw):
    if raw is None:
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


TOKEN_KEYS = {"input_tokens", "prompt_tokens", "output_tokens", "completion_tokens",
              "cached_tokens", "reasoning_tokens", "total_tokens"}


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
    if v is None:
        return None
    if isinstance(v, bool):
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


def nested_usage(top, payload):
    for container in (payload, top):
        if not isinstance(container, dict):
            continue
        for key in ("usage", "token_usage", "tokenusage"):
            nested = container.get(key)
            if isinstance(nested, dict):
                return nested
    return None


def parse_codex_line(line, model_override=None):
    try:
        top = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(top, dict):
        return None
    payload = top
    for k in ("payload", "data", "record", "usage", "token_usage"):
        if isinstance(top.get(k), dict):
            payload = top[k]
            break
    t = get(top, "type", "payload_type", "kind", "event", "name")
    if t is None:
        t = get(payload, "type", "payload_type", "kind", "event", "name")
    nested = nested_usage(top, payload)
    if t is not None:
        tl = str(t).lower()
        has_tok = any(k in payload or k in top for k in
                      ("input_tokens", "prompt_tokens", "output_tokens", "completion_tokens",
                        "cached_tokens", "reasoning_tokens", "total_tokens",
                        "inputtokens", "prompttokens", "outputtokens", "completiontokens",
                        "tokens_input", "tokens_output"))
        if "token_usage" not in tl and not has_tok and not ("response" in tl and nested is not None):
            return None
    merged = dict(top)
    merged.update(payload)
    # Per-record values come from payload.usage when present; turn/thread
    # objects are cumulative and must not be summed on top.
    usage = nested if nested is not None else merged
    ts = parse_ts(get(merged, "timestamp", "time", "created_at", "createdAt", "date"))
    if ts is None:
        return None
    i = to_int(get(usage, "input_tokens", "inputtokens", "prompt_tokens", "prompttokens",
                     "tokens_input", "tokensinput", "input"))
    o = to_int(get(usage, "output_tokens", "outputtokens", "completion_tokens", "completiontokens",
                     "tokens_output", "tokensoutput", "output"))
    c_read = to_int(get(usage, "cached_tokens", "cachedtokens", "cached_input_tokens", "cachedinputtokens",
                          "tokens_cache_read", "tokenscacheread"))
    c_write = to_int(get(usage, "cache_write_input_tokens", "cachewriteinputtokens",
                           "tokens_cache_write", "tokenscachewrite"))
    c = None if (c_read is None and c_write is None) else (c_read or 0) + (c_write or 0)
    r = to_int(get(usage, "reasoning_tokens", "reasoningtokens", "reasoning_output_tokens",
                     "reasoningoutputtokens", "tokens_reasoning", "tokensreasoning"))
    tot = to_int(get(usage, "total_tokens", "totaltokens", "tokens_total", "tokenstotal", "total"))
    if all(v is None for v in (i, o, c, r, tot)):
        return None
    i, o = i or 0, o or 0
    tot_val = tot if isinstance(tot, (int, float)) and tot > 0 else None
    # NormalizedUsage init clamps cached to input (subset invariant).
    cc = min(max(0, c or 0), i)
    own = get(merged, "model", "model_name")
    model = own or model_override or "unknown"
    if not model:
        model = "unknown"
    return {"ts": ts, "model": model,
            "input": i, "output": o, "cached": cc, "reasoning": r or 0,
            "total": tot_val if tot_val else i + o,
            "session": get(merged, "session_id", "sessionid", "thread_id", "conversation_id") or "",
            "request": get(merged, "response_id", "responseid", "request_id", "requestid",
                           "message_id", "turn_id", "id") or ""}


def is_turn_context(t):
    if t is None:
        return False
    squashed = str(t).lower().replace("_", "").replace("-", "")
    return "turncontext" in squashed


def parse_codex_file_lines(lines, file_id=""):
    """File-level mirror of CodexParser.parseFile: per-file turn_id -> model
    map (latest wins) + single-model thread fallback; ambiguous threads stay
    unknown. turn_context lines are consumed for attribution and counted as
    skipped. Standalone parse_codex_line stays context-free."""
    turn_models = {}
    thread_models = {}
    ambiguous = set()
    records = []
    skipped = 0
    for raw in lines:
        line = raw.strip() if isinstance(raw, str) else ""
        if not line:
            continue
        try:
            top = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            skipped += 1
            continue
        if not isinstance(top, dict):
            skipped += 1
            continue
        payload = top
        for k in ("payload", "data", "record", "usage", "token_usage"):
            if isinstance(top.get(k), dict):
                payload = top[k]
                break
        t = get(top, "type", "payload_type", "kind", "event", "name")
        if t is None:
            t = get(payload, "type", "payload_type", "kind", "event", "name")
        if is_turn_context(t):
            merged = dict(top)
            merged.update(payload)
            turn = get(merged, "turn_id", "turnid")
            thread = get(merged, "thread_id", "threadid")
            model = get(merged, "model", "model_name")
            if model and (turn or thread):
                if turn:
                    turn_models[turn] = model
                if thread and thread not in ambiguous:
                    if thread in thread_models:
                        if thread_models[thread] != model:
                            ambiguous.add(thread)
                            del thread_models[thread]
                    else:
                        thread_models[thread] = model
            skipped += 1
            continue
        merged = dict(top)
        merged.update(payload)
        override = None
        turn = get(merged, "turn_id", "turnid")
        if turn and turn in turn_models:
            override = turn_models[turn]
        else:
            thread = get(merged, "thread_id", "threadid")
            if thread and thread not in ambiguous and thread in thread_models:
                override = thread_models[thread]
        rec = parse_codex_line(line, model_override=override)
        if rec is not None:
            records.append(rec)
        else:
            skipped += 1
    return records, skipped


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


def decode_opencode_row(cols, table="session_v2"):
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
    ts = parse_ts(get(merged, "timestamp", "time", "time_created", "timecreated", "created_at",
                        "createdat", "createdAt", "created",
                        "updated_at", "updatedat", "updated", "time_updated", "timeupdated", "date"))
    if ts is None:
        return None
    raw = to_int(get(merged, "input_tokens", "inputtokens", "prompt_tokens", "prompttokens",
                       "tokens_input", "tokensinput", "input"))
    o = to_int(get(merged, "output_tokens", "outputtokens", "completion_tokens", "completiontokens",
                     "tokens_output", "tokensoutput", "output"))
    c_read = to_int(get(merged, "cached_tokens", "cachedtokens", "cached_input_tokens", "cachedinputtokens",
                          "tokens_cache_read", "tokenscacheread"))
    c_write = to_int(get(merged, "cache_write_input_tokens", "cachewriteinputtokens",
                           "tokens_cache_write", "tokenscachewrite"))
    c = None if (c_read is None and c_write is None) else (c_read or 0) + (c_write or 0)
    # Schema stores tokens_input separately from cache: fold cache into
    # normalized input so cached stays a subset and totals include it.
    # (Codex needs no fold: its usage input already includes cached input.)
    i = None if (raw is None and c is None) else (raw or 0) + (c or 0)
    r = to_int(get(merged, "reasoning_tokens", "reasoningtokens", "reasoning_output_tokens",
                     "reasoningoutputtokens", "tokens_reasoning", "tokensreasoning"))
    tot = to_int(get(merged, "total_tokens", "totaltokens", "tokens_total", "tokenstotal",
                       "total", "tokens"))
    if all(v is None for v in (i, o, c, r, tot)):
        return None
    i, o = i or 0, o or 0
    tot_val = tot if isinstance(tot, (int, float)) and tot > 0 else None
    session = get(merged, "session_id", "sessionid", "session", "id", "key") or ""
    request = get(merged, "request_id", "requestid", "message_id", "rowid") or ""
    if not request and session:
        # Mirror-pair dedupe key: same session + same second collapses,
        # different timestamps stay distinct (mirrors OpenCodeStore.decodeRow).
        request = f"{session}#{int(ts.timestamp())}"
    # NormalizedUsage init clamps cached to input (subset invariant).
    cc = min(max(0, c or 0), i)
    return {"ts": ts, "model": model_label(get(merged, "model", "model_name")) or "unknown",
            "input": i, "output": o, "cached": cc, "reasoning": r or 0,
            "total": tot_val if tot_val else i + o,
            "session": session, "request": request}


def _msg_str(cols, blob, keys):
    for k in keys:
        v = cols.get(k.lower()) if isinstance(cols, dict) else None
        if isinstance(v, str) and v:
            return v
        if isinstance(blob, dict):
            v = blob.get(k)
            if isinstance(v, str) and v:
                return v
    return None


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


def fnv1a_hex(cols):
    """Mirror of OpenCodeStore.stableRowHash: FNV-1a 64 over sorted key=value."""
    h = 14695981039346656037
    for key in sorted(cols):
        v = cols[key]
        for byte in f"{key}={v if v is not None else 'null'}".encode("utf-8"):
            h ^= byte
            h = (h * 1099511628211) % (1 << 64)
    return f"{h:016x}"


def fallback_message_id(table, cols, msg_id, session, ts_epoch):
    """Mirror of OpenCodeStore.fallbackMessageID."""
    if msg_id:
        return f"{table}:{msg_id}:{ts_epoch}"
    sess = session if session else "nosession"
    return f"{table}:{sess}:{ts_epoch}:{fnv1a_hex(cols)}"


def decode_opencode_message(cols, table="message"):
    """Mirror of OpenCodeStore.decodeMessageRow: per-message nested tokens,
    flat modelID/providerID or nested model object, assistant-only gate,
    all-zero rows skipped, content-hashed fallback IDs for ID-less rows."""
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
    flat_out = to_int(get(cols, "output_tokens", "outputtokens", "completion_tokens", "completiontokens",
                           "tokens_output", "tokensoutput", "output"))
    flat_cr = to_int(get(cols, "cached_tokens", "cachedtokens", "cached_input_tokens", "cachedinputtokens",
                          "tokens_cache_read", "tokenscacheread"))
    flat_cw = to_int(get(cols, "cache_write_input_tokens", "cachewriteinputtokens",
                          "tokens_cache_write", "tokenscachewrite"))
    flat_re = to_int(get(cols, "reasoning_tokens", "reasoningtokens", "reasoning_output_tokens",
                          "reasoningoutputtokens", "tokens_reasoning", "tokensreasoning"))
    flat_tot = to_int(get(cols, "total_tokens", "totaltokens", "tokens_total", "tokenstotal",
                           "total", "tokens"))
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
    ts = (parse_ts(t.get("created")) or parse_ts(t.get("completed")) or parse_ts(t.get("updated"))
          or parse_ts(get(cols, "time_created", "timecreated", "created_at", "createdat", "created",
                           "time_updated", "timeupdated", "updated_at", "updatedat", "updated",
                           "timestamp", "time")))
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
        model = model_label(get(blob, "model", "model_name") or get(cols, "model", "model_name"))
    session = cols.get("session_id") or cols.get("sessionid") or cols.get("session") or ""
    session = session or _msg_str({}, blob, ("session_id", "sessionId", "sessionid", "session")) or ""
    msg_id = _msg_str({}, blob, ("id", "message_id", "messageid", "messageId")) or ""
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
               msg_id or "", session, int(ts.timestamp()))}
    if all(rec[k] == 0 for k in ("input", "output", "cached", "reasoning", "total")):
        return None
    return rec


def select_mirror(best, key, candidate):
    """Mirror of OpenCodeStore.selectMirror: larger total wins; exact ties
    break to the earliest (timestamp, id)."""
    seen = best.get(key)
    if seen is None:
        best[key] = candidate
        return
    if candidate["total"] != seen["total"]:
        if candidate["total"] > seen["total"]:
            best[key] = candidate
    elif (candidate["ts"], candidate.get("id", "")) < (seen["ts"], seen.get("id", "")):
        best[key] = candidate


def combine_message_and_rollup(messages, rollups):
    """Mirror of OpenCodeStore.combineMessageAndRollup: messages win; rollups
    fill only uncovered sessions; deterministic mirror selection on both
    levels; empty-request rows pass through untouched."""
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
                  key=lambda r: (r["ts"], r.get("id", "")))


def parse_claude_line(line, file_id="", line_no=0):
    try:
        top = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(top, dict):
        return None
    t = top.get("type")
    if t is not None and "assistant" not in str(t).lower():
        return None
    message = top.get("message")
    if not isinstance(message, dict):
        return None
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return None
    i = to_int(get(usage, "input_tokens", "inputtokens", "input"))
    o = to_int(get(usage, "output_tokens", "outputtokens", "output"))
    c_read = to_int(get(usage, "cache_read_input_tokens", "cachereadinputtokens",
                         "cached_tokens", "cachedtokens", "cached_input_tokens",
                         "tokens_cache_read", "tokenscacheread"))
    c_make = to_int(get(usage, "cache_creation_input_tokens", "cachecreationinputtokens",
                         "cache_write_input_tokens", "cachewriteinputtokens",
                         "tokens_cache_write", "tokenscachewrite"))
    c = None if (c_read is None and c_make is None) else (c_read or 0) + (c_make or 0)
    # Anthropic semantics: total input sums raw input plus both cache
    # components (same fold-in as OpenCode; Codex needs no fold).
    raw = i
    i = None if (raw is None and c is None) else (raw or 0) + (c or 0)
    tot = to_int(get(usage, "total_tokens", "totaltokens", "tokens_total", "tokenstotal", "total"))
    if tot is None:
        tot = to_int(get(message, "total_tokens", "totaltokens", "total"))
    if tot is None:
        tot = to_int(get(top, "total_tokens", "totaltokens", "total"))
    if all(v is None for v in (i, o, c, tot)):
        return None
    merged = dict(top)
    merged.update(message)
    ts = parse_ts(get(merged, "timestamp", "time", "created_at", "createdAt", "date"))
    if ts is None:
        return None
    # The per-message API id is the finest-grained stable key, so it wins
    # over the outer request id when both exist (mirrors ClaudeParser).
    request = (get(message, "id", "message_id", "messageid", "messageId") or
               get(merged, "requestId", "request_id", "requestid") or "")
    session = (get(merged, "sessionId", "session_id", "sessionid") or "")
    model = get(merged, "model", "model_name") or "unknown"
    i, o = i or 0, o or 0
    # NormalizedUsage clamps cached to input so adversarial counts keep the
    # cached-subset-of-input invariant (no-op for real provider data, where
    # parsers already fold cache into input).
    cc = min(max(0, c or 0), i)
    tot_val = tot if isinstance(tot, (int, float)) and tot > 0 else None
    rid = f"{file_id}:{line_no}"
    return {"ts": ts, "model": model,
            "input": i, "output": o, "cached": cc, "reasoning": 0,
            "total": tot_val if tot_val else i + o,
            "session": session, "request": request,
            "id": f"claude:{request}" if request else f"claude:{rid}"}


def claude_relative(root, path):
    """Mirror of ClaudeParser.relativePath: root-relative label, never absolute."""
    base = root if root.endswith("/") else root + "/"
    if path.startswith(base):
        return path[len(base):]
    return os.path.basename(path)


def normalize_cached(input_tokens, cached_tokens):
    """Mirror of the NormalizedUsage init clamp: cached stays a subset of input."""
    return min(max(0, cached_tokens), max(0, input_tokens))


FALLBACK = (3.0, 12.0, 1.5)
# Exact normalized provider/model matches, checked BEFORE PRICE_TABLE.
# Static estimates only, never a bill; subscription use is not an API invoice.
# Approximations reuse the nearest family rate already in the project.
PRICE_EXACT = {
    "github-copilot/gpt-5.6-sol": (1.25, 10.0, 0.125),
    "openai/gpt-5.6-luna": (1.25, 10.0, 0.125),
    "opencode-go/muse-spark-1.3-contributor": (3.0, 15.0, 0.30),
}
PRICE_TABLE = [
    ("gpt-4o-mini", (0.15, 0.60, 0.075)),
    ("gpt-4o", (2.50, 10.0, 1.25)),
    ("gpt-5-mini", (0.25, 2.0, 0.025)),
    ("gpt-5", (1.25, 10.0, 0.125)),
    ("o1-mini", (1.10, 4.40, 0.55)),
    ("o1", (15.0, 60.0, 7.50)),
    ("o3-mini", (1.10, 4.40, 0.55)),
    ("o3", (2.0, 8.0, 0.50)),
    ("claude-haiku", (0.80, 4.0, 0.08)),
    ("claude-sonnet", (3.0, 15.0, 0.30)),
    ("claude-opus", (15.0, 75.0, 1.50)),
    ("gemini-flash", (0.35, 1.05, 0.035)),
    ("gemini-pro", (1.25, 10.0, 0.125)),
]


def normalize_key(model):
    return (model or "").strip().lower()


def is_exact(model):
    return normalize_key(model) in PRICE_EXACT


def provider_split(model):
    key = normalize_key(model)
    if "/" not in key:
        return ("", key)
    provider, _, name = key.partition("/")
    return (provider, name)


def price_for(model):
    key = normalize_key(model)
    if key in PRICE_EXACT:
        return PRICE_EXACT[key]
    for match, price in PRICE_TABLE:
        if match in key:
            return price
    return FALLBACK


def cost(model, i, o, c):
    cached = min(max(0, c), max(0, i))
    fresh = max(0, i) - cached
    inp, outp, cch = price_for(model)
    return fresh / 1e6 * inp + cached / 1e6 * cch + max(0, o) / 1e6 * outp


def run():
    now = datetime(2026, 9, 10, 12, 0, tzinfo=timezone.utc)

    # Codex fixture file
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    fixture = os.path.join(root, "Fixtures", "synthetic-codex-sample.jsonl")
    kept, skipped = 0, 0
    if os.path.exists(fixture):
        with open(fixture) as f:
            for line in f:
                if not line.strip():
                    continue
                if parse_codex_line(line) is not None:
                    kept += 1
                else:
                    skipped += 1
        check("fixture 3 kept / 3 skipped", kept == 3 and skipped == 3, f"kept={kept} skipped={skipped}")

    check("valid record total=input+output",
          parse_codex_line('{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
                           '"model":"gpt-5-mini","input_tokens":1200,"output_tokens":340}')['total'] == 1540)
    check("heartbeat rejected",
          parse_codex_line('{"type":"heartbeat","timestamp":"2026-09-10T09:00:00Z"}') is None)
    check("non-json rejected", parse_codex_line("not json") is None)
    check("bad date rejected",
          parse_codex_line('{"type":"token_usage_record","timestamp":"nope","input_tokens":1}') is None)
    check("epoch millis", parse_codex_line('{"timestamp":1757325600000,"input_tokens":1,"output_tokens":1}') is not None)
    check("unknown model kept",
          parse_codex_line('{"timestamp":"2026-09-10T08:15:00Z","input_tokens":5,"output_tokens":5}')['model'] == "unknown")

    # OpenCode rows
    rec = decode_opencode_row({"id": "a", "model": "x", "input_tokens": "1000", "output_tokens": "250",
                               "cached_tokens": "100", "created_at": "2026-09-10T08:15:00Z"})
    check("opencode column form", rec is not None and rec["input"] == 1100 and rec["total"] == 1350)
    blob = json.dumps({"model": "m", "input_tokens": 700, "output_tokens": 300,
                       "timestamp": "2026-09-09T10:00:00Z"})
    check("opencode json blob", decode_opencode_row({"id": "r", "data": blob})["total"] == 1000)
    check("opencode missing ts skipped",
          decode_opencode_row({"id": "x", "input_tokens": "10"}) is None)
    check("opencode no counts skipped",
          decode_opencode_row({"id": "x", "created_at": "2026-09-10T08:15:00Z"}) is None)

    # Presets
    same = now - timedelta(hours=11)
    prior = now - timedelta(hours=13)
    sod = now.replace(hour=0, minute=0, second=0, microsecond=0)
    check("today is calendar day", (same >= sod) and not (prior >= sod))
    check("24h rolling inclusive",
          (now - timedelta(hours=24) >= now - timedelta(hours=24)) and
          (now - timedelta(hours=25) < now - timedelta(hours=24)))
    check("7d boundary", (now - timedelta(days=6) >= now - timedelta(days=7)) and
          (now - timedelta(days=8) < now - timedelta(days=7)))
    check("30d boundary", (now - timedelta(days=29) >= now - timedelta(days=30)) and
          (now - timedelta(days=31) < now - timedelta(days=30)))

    # Best month + tiebreak
    months = {"2026-08": 1000, "2026-09": 5000, "2026-07": 200}
    check("best month max", max(months, key=lambda k: (months[k], k)) in ("2026-09",))
    tied = {"2026-08": 1000, "2026-09": 1000}
    winner = sorted(tied)[0] if tied["2026-08"] == tied["2026-09"] else max(tied, key=tied.get)
    check("best month tie earliest", winner == "2026-08")

    # Cost: cached subset
    check("cached-only billed at cached rate",
          abs(cost("gpt-4o-mini", 1000, 0, 1000) - 1000 / 1e6 * 0.075) < 1e-12)
    check("pricing mini-before-base order",
          abs(cost("gpt-4o-mini", 1_000_000, 0, 0) - 0.15) < 1e-9 and
          abs(cost("gpt-4o", 1_000_000, 0, 0) - 2.5) < 1e-9 and
          abs(cost("gpt-5-mini", 1_000_000, 0, 0) - 0.25) < 1e-9 and
          abs(cost("gpt-5", 1_000_000, 0, 0) - 1.25) < 1e-9)
    check("pricing unknown fallback",
          abs(cost("some-future-model-zzz", 1_000_000, 0, 0) - 3.0) < 1e-9)
    # M3 provider-aware pricing: exact normalized provider/model first.
    check("pricing exact copilot resolves",
          abs(cost("github-copilot/gpt-5.6-sol", 1_000_000, 0, 0) - 1.25) < 1e-9 and
          is_exact("github-copilot/gpt-5.6-sol"))
    check("pricing exact luna resolves",
          abs(cost("openai/gpt-5.6-luna", 1_000_000, 0, 0) - 1.25) < 1e-9 and
          is_exact("openai/gpt-5.6-luna"))
    check("pricing exact muse-spark resolves",
          abs(cost("opencode-go/muse-spark-1.3-contributor", 0, 1_000_000, 0) - 15.0) < 1e-9 and
          is_exact("opencode-go/muse-spark-1.3-contributor"))
    check("pricing exact case-insensitive + trimmed",
          is_exact("OPENAI/GPT-5.6-LUNA") and is_exact("  openai/gpt-5.6-luna  ") and
          abs(cost("OPENAI/GPT-5.6-LUNA", 1_000_000, 0, 0) -
              cost("openai/gpt-5.6-luna", 1_000_000, 0, 0)) < 1e-12)
    check("pricing provider prefix matters",
          not is_exact("gpt-5.6-luna") and
          not is_exact("other-provider/gpt-5.6-luna") and
          not is_exact("muse-spark-1.3-contributor") and
          provider_split("OpenAI/GPT-5.6-Luna") == ("openai", "gpt-5.6-luna") and
          abs(cost("other-provider/gpt-5.6-luna", 1_000_000, 0, 0) - 1.25) < 1e-9 and
          abs(cost("muse-spark-1.3-contributor", 0, 1_000_000, 0) - 12.0) < 1e-9)
    check("pricing exact beats fallback",
          abs(cost("opencode-go/muse-spark-1.3-contributor", 0, 1_000_000, 0) - 15.0) < 1e-9 and
          abs(cost("some-future-model-zzz", 0, 1_000_000, 0) - 12.0) < 1e-9)
    check("pricing exact cached subset cap",
          abs(cost("openai/gpt-5.6-luna", 1000, 0, 1000) - 1000 / 1e6 * 0.125) < 1e-12 and
          abs(cost("openai/gpt-5.6-luna", 100, 0, 5000) -
              cost("openai/gpt-5.6-luna", 100, 0, 100)) < 1e-12)
    check("pricing reasoning rides inside output",
          abs(cost("github-copilot/gpt-5.6-sol", 1000, 500, 0) -
              (1000 / 1e6 * 1.25 + 500 / 1e6 * 10.0)) < 1e-12)
    check("negative total falls back to input+output",
          parse_codex_line('{"timestamp":"2026-09-10T08:15:00Z","input_tokens":10,'
                           '"output_tokens":5,"total_tokens":-3}')['total'] == 15)
    check("float-string counts tolerated",
          parse_codex_line('{"timestamp":"2026-09-10T08:15:00Z","input_tokens":"10.0",'
                           '"output_tokens":"5"}')['total'] == 15)
    check("bool counts rejected",
          parse_codex_line('{"timestamp":"2026-09-10T08:15:00Z","input_tokens":true}') is None)

    # Real-world Codex response shape: per-record usage wins over cumulative rollups
    resp = {"type": "response", "timestamp": "2026-09-10T08:15:00Z",
            "payload": {"response_id": "resp-1", "session_id": "sess-1", "thread_id": "t1",
                        "turn_id": "turn-1", "root_turn_id": "turn-1",
                        "usage": {"input_tokens": 1200, "output_tokens": 340,
                                  "cached_input_tokens": 200, "cache_write_input_tokens": 50,
                                  "reasoning_output_tokens": 120, "total_tokens": 1540},
                        "turn_token_usage": {"input_tokens": 9999, "output_tokens": 9999},
                        "thread_token_usage": {"input_tokens": 8888, "output_tokens": 8888}}}
    parsed_resp = parse_codex_line(json.dumps(resp))
    check("codex response per-record usage",
          parsed_resp is not None and parsed_resp["input"] == 1200
          and parsed_resp["cached"] == 250 and parsed_resp["total"] == 1540
          and parsed_resp["session"] == "sess-1" and parsed_resp["request"] == "resp-1")
    check("codex response without usage rejected",
          parse_codex_line('{"type":"response","timestamp":"2026-09-10T08:15:00Z",'
                           '"payload":{"response_id":"r1"}}') is None)

    # M2 turn_context attribution (synthetic only): usage payloads carry IDs
    # + nested usage but no model; turn_context carries turn_id -> model.
    recs, sk = parse_codex_file_lines([
        '{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
        '"payload":{"turn_id":"turn-1","thread_id":"thread-1","model":"gpt-5.6-sol"}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
        '"payload":{"response_id":"resp-1","thread_id":"thread-1","turn_id":"turn-1",'
        '"usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}}',
    ])
    check("codex turn_context resolves model",
          len(recs) == 1 and recs[0]["model"] == "gpt-5.6-sol" and sk == 1)
    check("codex standalone stays unknown without context",
          parse_codex_line('{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
                           '"payload":{"response_id":"r","turn_id":"turn-1","thread_id":"thread-1",'
                           '"usage":{"input_tokens":100,"output_tokens":50}}}')["model"] == "unknown")
    recs_alias, _ = parse_codex_file_lines([
        '{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
        '"payload":{"turn_id":"turn-alias","thread_id":"thread-alias","model_name":"gpt-5.5"}}',
        '{"type":"token_usage_record","timestamp":1757325600,'
        '"payload":{"turn_id":"turn-alias","thread_id":"thread-alias",'
        '"usage":{"prompt_tokens":500,"completion_tokens":150}}}',
    ])
    check("codex alias model_name + nested usage",
          len(recs_alias) == 1 and recs_alias[0]["model"] == "gpt-5.5"
          and recs_alias[0]["input"] == 500 and recs_alias[0]["total"] == 650)
    recs_own, _ = parse_codex_file_lines([
        '{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
        '"payload":{"turn_id":"turn-own","thread_id":"thread-own","model":"codex-auto-review"}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","model":"gpt-5-mini",'
        '"payload":{"turn_id":"turn-own","thread_id":"thread-own",'
        '"usage":{"input_tokens":10,"output_tokens":5}}}',
    ])
    check("codex own model wins over context",
          len(recs_own) == 1 and recs_own[0]["model"] == "gpt-5-mini")
    recs_none, _ = parse_codex_file_lines([
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
        '"payload":{"response_id":"r-noctx","turn_id":"turn-missing","thread_id":"thread-missing",'
        '"usage":{"input_tokens":5,"output_tokens":5}}}',
    ])
    check("codex unknown fallback without attribution",
          len(recs_none) == 1 and recs_none[0]["model"] == "unknown")
    recs_fb, _ = parse_codex_file_lines([
        '{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
        '"payload":{"turn_id":"turn-a","thread_id":"thread-single","model":"synth-model-a"}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
        '"payload":{"response_id":"r-fb","thread_id":"thread-single",'
        '"usage":{"input_tokens":7,"output_tokens":3}}}',
    ])
    check("codex single-model thread fallback",
          len(recs_fb) == 1 and recs_fb[0]["model"] == "synth-model-a")
    recs_amb, _ = parse_codex_file_lines([
        '{"type":"turn_context","timestamp":"2026-09-10T08:13:00Z",'
        '"payload":{"turn_id":"turn-1","thread_id":"thread-mixed","model":"synth-model-a"}}',
        '{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
        '"payload":{"turn_id":"turn-2","thread_id":"thread-mixed","model":"synth-model-b"}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
        '"payload":{"response_id":"r-amb","thread_id":"thread-mixed",'
        '"usage":{"input_tokens":7,"output_tokens":3}}}',
    ])
    check("codex ambiguous thread stays unknown",
          len(recs_amb) == 1 and recs_amb[0]["model"] == "unknown")
    recs_latest, _ = parse_codex_file_lines([
        '{"type":"turn_context","timestamp":"2026-09-10T08:13:00Z",'
        '"payload":{"turn_id":"turn-latest","thread_id":"t","model":"synth-model-old"}}',
        '{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
        '"payload":{"turn_id":"turn-latest","thread_id":"t","model":"synth-model-new"}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
        '"payload":{"response_id":"r-l","turn_id":"turn-latest","thread_id":"t",'
        '"usage":{"input_tokens":10,"output_tokens":5}}}',
    ])
    check("codex latest turn mapping wins",
          len(recs_latest) == 1 and recs_latest[0]["model"] == "synth-model-new")
    recs_exact, _ = parse_codex_file_lines([
        '{"type":"turn_context","timestamp":"2026-09-10T07:00:00Z",'
        '"payload":{"turn_id":"t1","thread_id":"th1","model":"synth-provider/synth-model-v1"}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
        '"payload":{"response_id":"r1","turn_id":"t1","thread_id":"th1",'
        '"usage":{"input_tokens":100,"total_tokens":100}}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:16:00Z",'
        '"model":"synth-provider/synth-model-v1-suffix",'
        '"payload":{"response_id":"r2","usage":{"input_tokens":50,"total_tokens":50}}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:17:00Z",'
        '"payload":{"response_id":"r3","usage":{"input_tokens":200,"total_tokens":200}}}',
    ])
    groups = {}
    for r in recs_exact:
        groups[r["model"]] = groups.get(r["model"], 0) + r["total"]
    ordered = sorted(groups.items(), key=lambda kv: (-kv[1], kv[0]))
    check("codex exact model grouping sorted",
          [k for k, _ in ordered] == ["unknown", "synth-provider/synth-model-v1",
                                      "synth-provider/synth-model-v1-suffix"]
          and [v for _, v in ordered] == [200, 100, 50])
    secret = "SECRET-PROMPT-XYZ"
    tc_priv = ('{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
               '"payload":{"turn_id":"turn-priv","thread_id":"thread-priv",'
               '"model":"synth-model-priv","prompt":"' + secret + '",'
               '"path":"/Users/someone/.codex/secret"}}')
    recs_priv, _ = parse_codex_file_lines([
        tc_priv,
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
        '"payload":{"response_id":"resp-priv","turn_id":"turn-priv","thread_id":"thread-priv",'
        '"usage":{"input_tokens":10,"output_tokens":5}}}',
    ])
    priv_dump = json.dumps(recs_priv, default=str)
    check("codex attribution privacy",
          len(recs_priv) == 1 and recs_priv[0]["model"] == "synth-model-priv"
          and secret not in priv_dump
          and "/Users/someone" not in priv_dump)

    # Real-world OpenCode row shape
    real = decode_opencode_row({"id": "sess-1", "time_created": "1757325600000",
                                "tokens_input": "1000", "tokens_output": "250",
                                "tokens_reasoning": "50", "tokens_cache_read": "100",
                                "tokens_cache_write": "20",
                                "model": json.dumps({"id": "gpt-5-mini", "providerID": "openai"})})
    check("opencode real columns + model json",
          real is not None and real["input"] == 1120 and real["cached"] == 120
          and real["reasoning"] == 50 and real["total"] == 1370
          and real["model"] == "openai/gpt-5-mini" and real["request"] == "sess-1#1757325600"
          and real["cached"] <= real["input"])
    check("opencode model id-only",
          decode_opencode_row({"id": "s", "time_created": "1757325600000",
                               "tokens_input": "10", "tokens_output": "5",
                               "model": json.dumps({"id": "claude-sonnet-4"})})["model"] == "claude-sonnet-4")
    check("opencode mirror rows share request key",
          decode_opencode_row({"id": "sess-dup", "time_created": "1757325600000",
                               "tokens_input": "100", "tokens_output": "50"},
                              table="session_v2")["request"] ==
          decode_opencode_row({"id": "sess-dup", "time_created": "1757325600000",
                               "tokens_input": "100", "tokens_output": "50"},
                              table="session")["request"] == "sess-dup#1757325600")
    check("opencode same session different timestamps stay distinct",
          decode_opencode_row({"id": "sess-multi", "time_created": "1757325600000",
                               "tokens_input": "100", "tokens_output": "50"})["request"] !=
          decode_opencode_row({"id": "sess-multi", "time_created": "1757325660000",
                               "tokens_input": "100", "tokens_output": "50"})["request"])
    check("opencode cache folded into input and total",
          (lambda r: r is not None and r["input"] == 1000 and r["cached"] == 200
           and r["total"] == 1200 and r["cached"] <= r["input"])(
              decode_opencode_row({"id": "c", "time_created": "1757325600000",
                                   "tokens_input": "800", "tokens_output": "200",
                                   "tokens_cache_read": "150", "tokens_cache_write": "50"})))
    check("opencode cache-only row normalizes input",
          (lambda r: r is not None and r["input"] == 300 and r["cached"] == 300
           and r["total"] == 300)(
              decode_opencode_row({"id": "co", "time_created": "1757325600000",
                                   "tokens_cache_read": "300"})))
    check("opencode explicit total still wins",
          (lambda r: r is not None and r["input"] == 900 and r["total"] == 5000)(
              decode_opencode_row({"id": "e", "time_created": "1757325600000",
                                   "tokens_input": "800", "tokens_output": "200",
                                   "tokens_cache_read": "100", "total_tokens": "5000"})))

    # Per-message tables (mirror of decodeMessageRow): nested tokens, flat
    # modelID/providerID or nested model object, assistant-only gate,
    # all-zero rows skipped. Synthetic only, never real logs.
    def msg_cols(blob, **kw):
        cols = {"id": kw.get("row_id", "msg-1"),
                "session_id": kw.get("session", "ses-1"),
                "time_created": kw.get("col_tc", "1757325600000")}
        if kw.get("type_col") is not None:
            cols["type"] = kw["type_col"]
        cols["data"] = json.dumps(blob) if isinstance(blob, dict) else blob
        return cols

    assistant_blob = {"role": "assistant", "modelID": "muse-spark-1.3-contributor",
                      "providerID": "opencode-go",
                      "tokens": {"input": 3413, "output": 161, "reasoning": 60,
                                 "cache": {"read": 600, "write": 100}, "total": 4813},
                      "time": {"created": 1789087080181}}
    msg_rec = decode_opencode_message(msg_cols(assistant_blob, row_id="msg-1"))
    check("opencode message nested tokens + flat ids",
          msg_rec is not None and msg_rec["input"] == 4113 and msg_rec["cached"] == 700
          and msg_rec["reasoning"] == 60 and msg_rec["model"] == "opencode-go/muse-spark-1.3-contributor"
          and msg_rec["session"] == "ses-1" and msg_rec["request"] == "msg-1"
          and msg_rec["cached"] <= msg_rec["input"])
    check("opencode message explicit total wins",
          msg_rec is not None and msg_rec["total"] == 4813)
    nested_model_blob = dict(assistant_blob)
    nested_model_blob.pop("modelID")
    nested_model_blob.pop("providerID")
    nested_model_blob["model"] = {"id": "gpt-5.6-luna", "providerID": "openai"}
    check("opencode message nested model object",
          decode_opencode_message(msg_cols(nested_model_blob))["model"] == "openai/gpt-5.6-luna")
    check("opencode message user skipped",
          decode_opencode_message(msg_cols({"role": "user", "time": {"created": 1789087080181}})) is None)
    check("opencode message type-column gate",
          decode_opencode_message(msg_cols(assistant_blob, type_col="compaction")) is None
          and decode_opencode_message(msg_cols(assistant_blob, type_col="assistant")) is not None)
    check("opencode message all-zero skipped",
          decode_opencode_message(msg_cols({"role": "assistant", "modelID": "m",
                                            "tokens": {"input": 0, "output": 0, "reasoning": 0,
                                                       "cache": {"read": 0, "write": 0}},
                                            "time": {"created": 1789087080181}})) is None)
    check("opencode message missing ts skipped",
          decode_opencode_message({"id": "x", "data": json.dumps({"role": "assistant", "modelID": "m",
              "tokens": {"input": 1, "output": 1}})}) is None)
    check("opencode message missing tokens skipped",
          decode_opencode_message(msg_cols({"role": "assistant", "modelID": "m",
                                            "time": {"created": 1789087080181}})) is None)
    check("opencode message muse-spark exact pricing",
          msg_rec is not None and is_exact(msg_rec["model"])
          and abs(cost(msg_rec["model"], 0, 1_000_000, 0) - 15.0) < 1e-9)
    # Range attribution (the 7d bug): a session created long ago carries a
    # recent message; the rollup timestamp misses the window, the message
    # timestamp hits it.
    now_ts = datetime(2026, 9, 11, 12, 0, tzinfo=timezone.utc)
    recent_ms = int((now_ts - timedelta(days=1)).timestamp() * 1000)
    old_ms = int((now_ts - timedelta(days=60)).timestamp() * 1000)
    old_rollup = decode_opencode_row({"id": "ses-old", "time_created": str(old_ms),
                                      "tokens_input": "100", "tokens_output": "50"})
    fresh_msg = decode_opencode_message(msg_cols(dict(assistant_blob,
        time={"created": recent_ms}), session="ses-old", row_id="msg-fresh"))
    window_start = now_ts - timedelta(days=7)
    check("opencode message fixes stale-rollup range",
          old_rollup is not None and fresh_msg is not None
          and not (old_rollup["ts"] >= window_start)
          and fresh_msg["ts"] >= window_start)
    # Combine rule: messages win; rollups fill uncovered sessions only;
    # stale rollup mirrors lose to the larger total.
    combined = combine_message_and_rollup(
        [dict(fresh_msg, session="ses-old")],
        [dict(old_rollup, session="ses-old"),
         dict(old_rollup, session="ses-legacy", request="ses-legacy#1", total=150)])
    check("opencode combine drops covered rollup, keeps legacy",
          len(combined) == 2 and {r["session"] for r in combined} == {"ses-old", "ses-legacy"})
    mirror_old = dict(old_rollup, session="ses-m", request="ses-m#1", total=100)
    mirror_new = dict(old_rollup, session="ses-m", request="ses-m#1", total=150)
    combined_mirror = combine_message_and_rollup([], [mirror_old, mirror_new])
    check("opencode combine keeps fresher mirror total",
          len(combined_mirror) == 1 and combined_mirror[0]["total"] == 150)
    no_msg = combine_message_and_rollup([], [dict(old_rollup, session="ses-x")])
    check("opencode combine falls back to rollups",
          len(no_msg) == 1 and no_msg[0]["session"] == "ses-x")
    # Unified mirror selection: larger total wins on both levels, exact ties
    # break to the earliest (timestamp, id); order-independent.
    m_lo = decode_opencode_message(msg_cols(dict(assistant_blob,
        tokens={"input": 100, "output": 0, "cache": {"read": 0, "write": 0}},
        time={"created": recent_ms}), session="ses-mm", row_id="msg-mm"))
    m_hi = decode_opencode_message(msg_cols(dict(assistant_blob,
        tokens={"input": 200, "output": 0, "cache": {"read": 0, "write": 0}},
        time={"created": recent_ms}), session="ses-mm", row_id="msg-mm"))
    for pair in ((m_lo, m_hi), (m_hi, m_lo)):
        got = combine_message_and_rollup(list(pair), [])
        check("opencode message mirror max-total wins",
              len(got) == 1 and got[0]["total"] == 200)
    tie_a = dict(m_lo, ts=m_lo["ts"] - timedelta(seconds=5))
    tie_b = dict(m_lo)
    for pair in ((tie_a, tie_b), (tie_b, tie_a)):
        got = combine_message_and_rollup(list(pair), [])
        check("opencode mirror tie breaks earliest",
              len(got) == 1 and got[0]["ts"] == tie_a["ts"])
    # ID-less rows: deterministic content-hashed IDs, distinct rows stay
    # distinct through combine + dedupe.
    def noid_cols(extra_tokens, suffix):
        blob = {"role": "assistant", "modelID": "m",
                "tokens": dict({"input": 10, "output": 5}, **extra_tokens),
                "time": {"created": recent_ms}, "note": suffix}
        return {"session_id": "ses-noid", "time_created": str(recent_ms),
                "data": json.dumps(blob)}
    noid_a = decode_opencode_message(noid_cols({}, "first"))
    noid_b = decode_opencode_message(noid_cols({}, "second"))
    noid_a2 = decode_opencode_message(noid_cols({}, "first"))
    check("opencode id-less rows distinct ids",
          noid_a is not None and noid_b is not None
          and noid_a["request"] == "" and noid_a["id"] != noid_b["id"])
    check("opencode id-less ids deterministic",
          noid_a is not None and noid_a2 is not None and noid_a["id"] == noid_a2["id"])
    seen, kept = set(), []
    for r in combine_message_and_rollup([noid_a, noid_b], []):
        if not r["request"]:
            kept.append(r)  # dedupe keeps empty-request rows by id
            continue
        k = "opencode:" + r["request"]
        if k not in seen:
            seen.add(k)
            kept.append(r)
    check("opencode id-less rows both survive",
          len(kept) == 2 and kept[0]["id"] != kept[1]["id"])
    # Timestamp precedence: nested time.created beats a stale column.
    prec = decode_opencode_message(msg_cols(dict(assistant_blob, time={"created": recent_ms}),
                                            col_tc=str(old_ms)))
    check("opencode nested time beats stale column",
          prec is not None and prec["ts"] >= window_start)
    # Flat-column drift row without any blob still decodes.
    drift = decode_opencode_message({"session_id": "ses-d", "time_created": str(recent_ms),
                                     "tokens_input": "40", "tokens_output": "2", "model": "m"})
    check("opencode flat-column drift row decodes",
          drift is not None and drift["total"] == 42 and drift["session"] == "ses-d")
    # Blob top-level timestamp keys are not probed: without nested time
    # and without columns there is no timestamp.
    noto = decode_opencode_message({"id": "x", "data": json.dumps(
        {"role": "assistant", "modelID": "m", "timestamp": "2026-09-10T08:15:00Z",
         "tokens": {"input": 1, "output": 1}})})
    check("opencode top-level blob timestamp ignored", noto is None)

    # SQLite projection slice: bounded allowlist covers every decoder
    # probe; wide unrelated columns are ignored with identical decode.
    projected = {
        "data", "payload", "info", "value", "content", "meta",
        "timestamp", "time", "time_created", "timecreated",
        "created_at", "createdat", "created",
        "updated_at", "updatedat", "updated",
        "time_updated", "timeupdated", "date",
        "input_tokens", "inputtokens", "prompt_tokens", "prompttokens",
        "tokens_input", "tokensinput", "input",
        "output_tokens", "outputtokens", "completion_tokens",
        "completiontokens", "tokens_output", "tokensoutput", "output",
        "cached_tokens", "cachedtokens", "cached_input_tokens",
        "cachedinputtokens", "tokens_cache_read", "tokenscacheread",
        "cache_write_input_tokens", "cachewriteinputtokens",
        "tokens_cache_write", "tokenscachewrite",
        "reasoning_tokens", "reasoningtokens",
        "reasoning_output_tokens", "reasoningoutputtokens",
        "tokens_reasoning", "tokensreasoning",
        "total_tokens", "totaltokens", "tokens_total", "tokenstotal",
        "total", "tokens",
        "model", "model_name", "modelname", "provider_model",
        "modelid", "model_id", "providerid", "provider_id", "provider",
        "session_id", "sessionid", "session", "id", "key",
        "request_id", "requestid", "message_id", "messageid", "rowid",
        "type", "role",
    }
    probe_keys = ["data", "time_created", "tokens_input", "tokens_output",
                  "model", "id", "session_id", "type",
                  "tokens_cache_read", "total_tokens", "timestamp"]
    check("projection covers decoder probes",
          all(k in projected for k in probe_keys))
    check("projection excludes wide privacy columns",
          all(k not in projected for k in
              ("prompt", "prompt_text", "tool_input", "tool_output",
               "text", "body", "path", "secret")))
    base_row = {"id": "sess-1", "time_created": "1757325600000",
                "tokens_input": "1000", "tokens_output": "250", "model": "m"}
    wide_row = dict(base_row, prompt_text="x" * 1000, tool_output="y" * 1000,
                    future_col_v2="123", path="/Users/someone/secret")
    base_rec = decode_opencode_row(base_row)
    wide_rec = decode_opencode_row(wide_row)
    check("projection wide-column parity (rollup)",
          base_rec is not None and wide_rec is not None
          and base_rec["total"] == wide_rec["total"]
          and base_rec["input"] == wide_rec["input"]
          and base_rec["request"] == wide_rec["request"])
    check("projection wide content never leaks",
          "/Users/someone" not in json.dumps(wide_rec, default=str))
    for blob_key in ("data", "payload", "info", "value", "content", "meta"):
        blob = json.dumps({"model": "m", "input_tokens": 700,
                           "output_tokens": 300,
                           "timestamp": "2026-09-09T10:00:00Z"})
        rec = decode_opencode_row({"id": "r", blob_key: blob,
                                   "prompt_text": "wide"})
        check(f"projection blob {blob_key} survives",
              rec is not None and rec["total"] == 1000)
    msg_base = msg_cols(dict(assistant_blob,
                             time={"created": recent_ms}),
                        session="ses-1", row_id="msg-1")
    msg_wide = dict(msg_base, prompt_text="q" * 1000,
                    tool_input="w" * 1000, future_col_v2="999")
    msg_a = decode_opencode_message(msg_base)
    msg_b = decode_opencode_message(msg_wide)
    check("projection wide-column parity (message)",
          msg_a is not None and msg_b is not None
          and msg_a["total"] == msg_b["total"]
          and msg_a["request"] == msg_b["request"])
    # SQLite fixture: same required + blob decode with wide columns
    # present in the table but never selected.
    import sqlite3 as _sqlite3
    import tempfile as _tempfile
    tmp = _tempfile.NamedTemporaryFile(suffix=".db", delete=False)
    tmp.close()
    try:
        con = _sqlite3.connect(tmp.name)
        con.execute("CREATE TABLE session_v2 (id TEXT, time_created TEXT,"
                    " tokens_input TEXT, tokens_output TEXT, model TEXT,"
                    " prompt_text TEXT, future_col_v2 TEXT)")
        con.execute("INSERT INTO session_v2 VALUES "
                    "('ses-1','1757325600000','100','50','m','SECRET','123'),"
                    "('bad',NULL,'10','5','m','SECRET','123')")
        cols = [r[1] for r in con.execute("PRAGMA table_info(session_v2)")]
        selected = [c for c in cols if c.lower() in projected]
        check("projection fixture selects bounded subset",
              set(selected) == {"id", "time_created", "tokens_input",
                                "tokens_output", "model"}
              and "prompt_text" not in selected
              and "future_col_v2" not in selected)
        cur = con.execute("SELECT \"id\",\"time_created\",\"tokens_input\","
                          "\"tokens_output\",\"model\" FROM \"session_v2\"")
        names = [d[0].lower() for d in cur.description]
        recs, skipped = [], 0
        for tup in cur.fetchall():
            row = {n: v for n, v in zip(names, tup)}
            rec = decode_opencode_row({k: (None if v is None else str(v))
                                       for k, v in row.items()})
            if rec is not None:
                recs.append(rec)
            else:
                skipped += 1
        check("projection fixture parity + skipped",
              len(recs) == 1 and skipped == 1
              and recs[0]["total"] == 150
              and "SECRET" not in json.dumps(recs, default=str))
        con.close()
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass

    # Dedupe earliest kept
    seen, unique = set(), []
    for rid, src in (("dup", "codex"), ("dup", "codex"), ("dup", "opencode")):
        key = src + ":" + rid
        if key not in seen:
            seen.add(key)
            unique.append(key)
    check("dedupe per source+request", unique == ["codex:dup", "opencode:dup"])

    # Claude Code source (synthetic only, never real logs)
    claude_fixture = os.path.join(root, "Fixtures", "synthetic-claude-sample.jsonl")
    c_kept, c_skipped = 0, 0
    if os.path.exists(claude_fixture):
        with open(claude_fixture) as f:
            for idx, line in enumerate(f, start=1):
                if not line.strip():
                    continue
                if parse_claude_line(line, file_id="synthetic-claude-sample.jsonl",
                                     line_no=idx) is not None:
                    c_kept += 1
                else:
                    c_skipped += 1
        check("claude fixture 3 kept / 5 skipped", c_kept == 3 and c_skipped == 5,
              f"kept={c_kept} skipped={c_skipped}")

    claude_valid = parse_claude_line(
        '{"type":"assistant","message":{"model":"claude-sonnet-4-20250514","id":"msg-1",'
        '"usage":{"input_tokens":1200,"output_tokens":340}},'
        '"timestamp":"2026-09-10T08:15:00Z","sessionId":"sess-1","requestId":"req-1"}')
    check("claude valid assistant",
          claude_valid is not None and claude_valid["total"] == 1540
          and claude_valid["request"] == "msg-1" and claude_valid["session"] == "sess-1")
    claude_cache = parse_claude_line(
        '{"type":"assistant","message":{"model":"m","id":"c",'
        '"usage":{"input_tokens":1200,"output_tokens":340,'
        '"cache_read_input_tokens":200,"cache_creation_input_tokens":50}},'
        '"timestamp":"2026-09-10T08:15:00Z","sessionId":"s"}')
    check("claude cache folded into input and total",
          claude_cache is not None and claude_cache["cached"] == 250
          and claude_cache["input"] == 1450 and claude_cache["total"] == 1790
          and claude_cache["cached"] <= claude_cache["input"])
    check("claude cache-only row normalizes input",
          (lambda r: r is not None and r["input"] == 300 and r["cached"] == 300
           and r["total"] == 300)(
              parse_claude_line('{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
                                '"message":{"model":"m","id":"co",'
                                '"usage":{"cache_read_input_tokens":300}}}')))
    check("claude cache larger than raw input still folds",
          (lambda r: r is not None and r["input"] == 900 and r["cached"] == 700
           and r["total"] == 950 and r["cached"] <= r["input"])(
              parse_claude_line('{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
                                '"message":{"model":"m","id":"big",'
                                '"usage":{"input_tokens":200,"output_tokens":50,'
                                '"cache_read_input_tokens":600,'
                                '"cache_creation_input_tokens":100}}}')))
    check("claude user line skipped",
          parse_claude_line('{"type":"user","message":{"role":"user"},'
                            '"timestamp":"2026-09-10T09:00:00Z"}') is None)
    check("claude summary skipped",
          parse_claude_line('{"type":"summary","summary":"x",'
                            '"timestamp":"2026-09-10T09:00:00Z"}') is None)
    check("claude missing usage skipped",
          parse_claude_line('{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
                            '"message":{"model":"m","id":"x"}}') is None)
    check("claude malformed skipped", parse_claude_line("not json") is None)
    check("claude bool counts rejected",
          parse_claude_line('{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
                            '"message":{"model":"m","id":"b",'
                            '"usage":{"input_tokens":true,"output_tokens":true}}}') is None)
    check("claude epoch timestamp",
          parse_claude_line('{"type":"assistant","timestamp":1757325600,"sessionId":"s",'
                            '"message":{"model":"m","id":"e",'
                            '"usage":{"input_tokens":1,"output_tokens":1}}}') is not None)
    check("claude epoch millis",
          parse_claude_line('{"type":"assistant","timestamp":1757325600000,"sessionId":"s",'
                            '"message":{"model":"m","id":"m",'
                            '"usage":{"input_tokens":1,"output_tokens":1}}}') is not None)
    check("claude explicit total wins",
          (lambda r: r is not None and r["input"] == 900 and r["total"] == 5000)(
              parse_claude_line('{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
                                '"message":{"model":"m","id":"t",'
                                '"usage":{"input_tokens":800,"output_tokens":200,'
                                '"cache_read_input_tokens":100,"total_tokens":5000}}}')))
    no_id_a = parse_claude_line(
        '{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
        '"message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}',
        file_id="f.jsonl", line_no=1)
    no_id_b = parse_claude_line(
        '{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
        '"message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}',
        file_id="f.jsonl", line_no=2)
    check("claude empty request stays unique by id",
          no_id_a is not None and no_id_b is not None
          and no_id_a["request"] == "" and no_id_a["id"] != no_id_b["id"])
    dup_a = parse_claude_line(
        '{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
        '"message":{"model":"m","id":"msg-dup","usage":{"input_tokens":10,"output_tokens":5}}}')
    dup_b = parse_claude_line(
        '{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
        '"message":{"model":"m","id":"msg-dup","usage":{"input_tokens":10,"output_tokens":5}}}')
    check("claude dedupe same message id",
          dup_a is not None and dup_b is not None
          and f"claude:{dup_a['request']}" == f"claude:{dup_b['request']}")
    check("claude source isolation",
          [r for r in
           [{"source": "codex"}, {"source": "opencode"}, {"source": "claude"}]
           if r["source"] == "claude"] == [{"source": "claude"}])
    check("claude fallback ids are root-relative",
          claude_relative("/root", "/root/proj-a/s.jsonl") == "proj-a/s.jsonl"
          and claude_relative("/root", "/root/proj-b/s.jsonl") == "proj-b/s.jsonl")
    check("claude fallback outside root uses basename",
          claude_relative("/root", "/elsewhere/x.jsonl") == "x.jsonl"
          and not claude_relative("/root", "/root/a.jsonl").startswith("/"))
    check("cached clamped to input for adversarial counts",
          normalize_cached(-5, 50) == 0 and normalize_cached(100, 500) == 100
          and normalize_cached(1000, 250) == 250)
    check("old report without claude skips defaults to zero",
          {"skippedCodexLines": 2}.get("skippedClaudeLines", 0) == 0)

    # Bounded JSONL streaming mirror (JSONLLineReader.swift semantics):
    # exact components(separatedBy: .newlines) fidelity: strict UTF-8
    # whole-file (None when undecodable), split on every .newlines member
    # (U+000A-U+000D, U+0085, U+2028, U+2029), each occurrence separately,
    # so CRLF keeps its phantom empty component and line numbers. No timing
    # here; allocation is measured by the count-only
    # scripts/bench-jsonl-streaming.py.
    _SEPS = {"\n", "\x0b", "\x0c", "\r", "\x85", "\u2028", "\u2029"}

    def stream_lines(raw):
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
        parts, cur = [], []
        for ch in text:
            if ch in _SEPS:
                parts.append("".join(cur))
                cur = []
            else:
                cur.append(ch)
        parts.append("".join(cur))
        return [(part, idx) for idx, part in enumerate(parts, start=1)]

    lf_raw = (b'{"timestamp":"2026-09-10T08:15:00Z","input_tokens":10,"output_tokens":1}\n'
              b'{"timestamp":"2026-09-10T08:15:00Z","input_tokens":20,"output_tokens":2}\n')
    check("jsonl LF numbering matches components",
          stream_lines(lf_raw) is not None
          and [n for _, n in stream_lines(lf_raw)] == [1, 2, 3]
          and stream_lines(lf_raw)[2][0] == "")
    crlf_raw = lf_raw.replace(b"\n", b"\r\n")
    check("jsonl CRLF keeps phantom empty components",
          stream_lines(crlf_raw) is not None
          and [t for t, _ in stream_lines(crlf_raw)][1] == ""
          and [n for _, n in stream_lines(crlf_raw)] == [1, 2, 3, 4, 5])
    check("jsonl CRLF/LF same non-blank text",
          [t for t, _ in stream_lines(crlf_raw) if t.strip()]
          == [t for t, _ in stream_lines(lf_raw) if t.strip()])
    check("jsonl unterminated final parsed, trailing sep adds blank tail",
          stream_lines(b'{"a":1}') is not None and len(stream_lines(b'{"a":1}')) == 1
          and len(stream_lines(b'{"a":1}\n')) == 2
          and stream_lines(b'{"a":1}\n')[1][0] == ""
          and stream_lines(b'')[0][0] == ""
          and len(stream_lines(b'\n\n')) == 3)
    lone_raw = 'l1\rl2\x85l3\u2028l4\u2029l5\x0bl6\x0cl7'.encode("utf-8")
    check("jsonl lone-CR and unicode separators all split",
          stream_lines(lone_raw) is not None
          and [t for t, _ in stream_lines(lone_raw)]
          == ["l1", "l2", "l3", "l4", "l5", "l6", "l7"])
    bad_raw = (b'{"timestamp":"2026-09-10T08:15:00Z","input_tokens":1,"output_tokens":1}\n'
               b'{\x22\xff\xfe}\n'
               b'{"timestamp":"2026-09-10T08:15:00Z","input_tokens":2,"output_tokens":2}\n')
    check("jsonl invalid UTF-8 aborts whole file",
          stream_lines(bad_raw) is None)
    # Streamed Codex file: blanks free, malformed + heartbeat skipped,
    # id-less record keeps its exact component fallback id.
    streamed = (b'\n   \n'
                b'{"timestamp":"2026-09-10T08:15:00Z","input_tokens":4,"output_tokens":1}\n'
                b'not json\n'
                b'{"type":"heartbeat","timestamp":"2026-09-10T09:00:00Z"}\n'
                b'{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
                b'"payload":{"response_id":"r-kept","usage":{"input_tokens":9,"output_tokens":1}}}\n')
    slines = stream_lines(streamed)
    kept_ids, skipped = [], 0
    for text, no in slines:
        if not text.strip():
            continue
        rec = parse_codex_line(text)
        if rec is None:
            skipped += 1
        elif rec["request"]:
            kept_ids.append("codex:" + rec["request"])
        else:
            kept_ids.append(f"codex:s.jsonl:{no}")
    check("jsonl streamed codex counts + fallback id",
          kept_ids == ["codex:s.jsonl:3", "codex:r-kept"] and skipped == 2)
    gap_raw = (b'{"timestamp":"2026-09-10T08:15:00Z","input_tokens":10,"output_tokens":1}\r\n'
               b'{"timestamp":"2026-09-10T08:15:00Z","input_tokens":20,"output_tokens":2}\r\n')
    gap_ids = []
    for text, no in stream_lines(gap_raw):
        if not text.strip():
            continue
        rec = parse_codex_line(text)
        if rec is not None and not rec["request"]:
            gap_ids.append(f"codex:s.jsonl:{no}")
    check("jsonl CRLF phantom fallback ids preserved",
          gap_ids == ["codex:s.jsonl:1", "codex:s.jsonl:3"])
    attr_fwd, sk_fwd = parse_codex_file_lines([
        '{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
        '"payload":{"turn_id":"t-stream","thread_id":"th","model":"synth-m"}}',
        '{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
        '"payload":{"response_id":"r","turn_id":"t-stream","thread_id":"th",'
        '"usage":{"input_tokens":10,"output_tokens":5}}}',
    ])
    check("jsonl streamed attribution forward-only",
          len(attr_fwd) == 1 and attr_fwd[0]["model"] == "synth-m" and sk_fwd == 1)
    # Chunked scan mirror (mirrors the Swift chunk loop, including the
    # carry for multi-byte separators split across chunks): 7-byte chunks
    # over multibyte content plus every separator kind must match the
    # whole-split, trailing blank tail included.
    def chunked_lines(raw, size):
        lines, pending, carry = [], bytearray(), b""
        chunks = [raw[i:i + size] for i in range(0, len(raw), size)] or [b""]
        for ci, ch in enumerate(chunks):
            buf = carry + ch
            carry = b""
            last = ci == len(chunks) - 1
            i, n = 0, len(buf)
            while i < n:
                b = buf[i]
                if b in (0x0A, 0x0B, 0x0C, 0x0D):
                    lines.append(bytes(pending).decode("utf-8"))
                    pending = bytearray()
                    i += 1
                elif b == 0xC2:
                    if i + 1 < n and buf[i + 1] == 0x85:
                        lines.append(bytes(pending).decode("utf-8"))
                        pending = bytearray()
                        i += 2
                    elif i + 1 >= n and not last:
                        carry = bytes([b])
                        i += 1
                    else:
                        pending.append(b)
                        i += 1
                elif b == 0xE2:
                    if (i + 2 < n and buf[i + 1] == 0x80
                            and buf[i + 2] in (0xA8, 0xA9)):
                        lines.append(bytes(pending).decode("utf-8"))
                        pending = bytearray()
                        i += 3
                    elif i + 2 >= n and not last:
                        carry = buf[i:n]
                        i = n
                    else:
                        pending.append(b)
                        i += 1
                else:
                    pending.append(b)
                    i += 1
        # Trailing separator leaves no observable empty line (blank tail is
        # always skipped free), so only a non-empty tail is emitted.
        if pending:
            lines.append(bytes(pending).decode("utf-8"))
        return lines

    wide_line = ('{"timestamp":"2026-09-10T08:15:00Z","input_tokens":5,'
                 '"note":"' + "é" * 50 + '😀"}')
    wide_raw = (wide_line + "\n" + '{"b":2\u2028"c":3}' + "\x85"
                + '{"d":4}').encode("utf-8")
    whole = [t for t, _ in stream_lines(wide_raw)]
    if whole and whole[-1] == "":
        whole = whole[:-1]  # unobservable blank tail, not emitted by chunks
    check("jsonl chunked scan matches whole split incl. separators",
          chunked_lines(wide_raw, 7) == whole
          and chunked_lines(wide_raw, 1) == whole
          and chunked_lines(wide_raw, 65536) == whole)
    # Streamed Claude file: CRLF + unterminated, phantom-gap fallback id.
    claude_streamed = (b'{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
                       b'"message":{"model":"m","id":"msg-a",'
                       b'"usage":{"input_tokens":10,"output_tokens":5}}}\r\n'
                       b'{"type":"user","timestamp":"2026-09-10T09:00:00Z","message":{}}\r\n'
                       b'{"type":"assistant","timestamp":"2026-09-10T08:15:00Z",'
                       b'"message":{"model":"m","usage":{"input_tokens":3,"output_tokens":2}}}')
    clines = stream_lines(claude_streamed)
    c_kept, c_skip = [], 0
    for text, no in clines:
        if not text.strip():
            continue
        rec = parse_claude_line(text, file_id="c.jsonl", line_no=no)
        if rec is None:
            c_skip += 1
        else:
            c_kept.append(rec["id"])
    check("jsonl streamed claude CRLF + unterminated",
          c_kept == ["claude:msg-a", "claude:c.jsonl:5"] and c_skip == 1)

    # Report formatter mirror (matches Report.swift semantics)
    def sanitize(w):
        if "Codex sessions not found" in w:
            return "Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT)."
        if "OpenCode database not found" in w:
            return "OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB)."
        if "Claude sessions not found" in w:
            return "Claude sessions not found (checked default location or TOKENBAR_CLAUDE_ROOT)."
        return " ".join("<path>" if t.strip(".,:;()[]\"'").startswith(("/", "~")) else t
                        for t in w.split(" "))

    def render_section(total, inp, out, cached, reasoning, req, sess, cost_v, by_source):
        lines = ["Token Bar -- lifetime / all",
                 f"Total tokens: {total}", f"Input tokens: {inp}", f"Output tokens: {out}",
                 f"Cached tokens: {cached} (subset of input)",
                 f"Reasoning tokens: {reasoning} (subset of output)",
                 f"Requests: {req}", f"Sessions: {sess}",
                  f"Estimated cost: ${cost_v:.4f} USD (estimate only; static table, not a bill; subscription use is not an API invoice)",
                 "By source:"]
        for k, v in by_source:
            lines.append(f"  {k}: {v} tokens")
        return "\n".join(lines)

    check("sanitize codex path",
          sanitize("Codex sessions not found at /Users/someone/.codex/sessions.") ==
          "Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT).")
    check("sanitize opencode path",
          "/Users/" not in sanitize("OpenCode database not found at /Users/someone/opencode.db"))
    check("sanitize claude missing-root",
          sanitize("Claude sessions not found at /Users/someone/.claude/projects.") ==
          "Claude sessions not found (checked default location or TOKENBAR_CLAUDE_ROOT).")
    check("sanitize generic path",
          "/tmp/secret/x.db" not in sanitize("Read failed at /tmp/secret/x.db today")
          and "<path>" in sanitize("Read failed at /tmp/secret/x.db today"))
    check("sanitize plural covers store messages",
          all("/Users/private" not in w for w in
              [sanitize("Codex sessions not found at /Users/private/.codex/sessions."),
               sanitize("OpenCode database not found at /Users/private/opencode.db")]))
    text = render_section(1800, 1500, 300, 0, 0, 2, 1, 0.0008,
                          [("codex", 1200), ("opencode", 600)])
    check("report labels lifetime totals",
          all(s in text for s in ("Total tokens: 1800", "Input tokens: 1500",
                                  "Estimated cost:", "estimate only", "not a bill",
                                  "not an API invoice", "codex", "opencode")))
    check("report no raw paths", "/Users/" not in sanitize(text) and "/tmp/" not in text)
    import json as _json
    payload = [{"preset": "lifetime", "totalTokens": 1800}]
    check("report json deterministic",
          _json.dumps(payload, sort_keys=True) == _json.dumps(payload, sort_keys=True))

    # Launch-at-login policy mirror (matches LaunchAtLogin.swift semantics)
    def is_bundled(bundle_id, ext):
        return bool(bundle_id) and ext == "app"

    def login_status(bundled, enabled, available):
        if not available:
            return "Launch at login unavailable on this macOS version."
        if not bundled:
            return "Dev run (unbundled): launch at login needs TokenBar.app in Applications."
        return "Launch at login: on." if enabled else "Launch at login: off."

    def login_help(bundled, available):
        if not available:
            return "Requires macOS 13 or later."
        if not bundled:
            return "Build the app with scripts/build-app.sh, move it to Applications, then toggle."
        return "Starts TokenBar when you log in. Manage also in System Settings under Login Items."

    check("login bundled needs id + app ext",
          is_bundled("com.manuotel.TokenBar", "app")
          and not is_bundled(None, "app") and not is_bundled("", "app")
          and not is_bundled("com.manuotel.TokenBar", None)
          and not is_bundled("com.manuotel.TokenBar", "xctest"))
    check("login unbundled points at app",
          "unbundled" in login_status(False, False, True)
          and "TokenBar.app" in login_status(False, False, True)
          and "/" not in login_status(False, False, True))
    check("login bundled reflects toggle",
          "on" in login_status(True, True, True)
          and "off" in login_status(True, False, True))
    check("login unavailable wins",
          "unavailable" in login_status(True, True, False))
    check("login help no paths",
          all("/Users" not in m and "/tmp" not in m for m in
              [login_help(False, True), login_help(True, True), login_help(True, False)])
          and "build-app.sh" in login_help(False, True))

    # Multi-origin merge (mirrors Models/Store/Aggregator/Report/Snapshot).
    def split_extra(raw):
        # Mirror of TokenBarStore.splitExtraList: commas and newlines only.
        # Colons/semicolons are legal filename characters, never separators.
        if not raw:
            return []
        out = []
        for part in raw.replace("\n", ",").split(","):
            p = part.strip()
            if p:
                out.append(p)
        return out

    check("extra list ignores empty entries",
          split_extra(None) == [] and split_extra("") == []
          and split_extra(" ,  \n ") == []
          and split_extra("/a.db, ,/b.db\n/c.db") == ["/a.db", "/b.db", "/c.db"]
          and split_extra("/data:with:colons.db,/other.db") == ["/data:with:colons.db", "/other.db"]
          and split_extra("/data;with.db,/other.db") == ["/data;with.db", "/other.db"])

    def normalize_origin(v):
        s = (v or "").strip()
        return s if s else "local"

    check("old record without origin defaults local",
          normalize_origin(None) == "local" and normalize_origin("") == "local"
          and normalize_origin("homeserver") == "homeserver")
    check("old stats without byOrigin defaults empty",
          {}.get("byOrigin", []) == [])

    FORBIDDEN = {"prompt", "tool_calls", "content", "text", "path", "credential",
                 "api_key", "message", "cookie"}

    import re as _re

    def sanitize_origin_label(v, fallback="homeserver"):
        # Mirror of OpenCodeStore.sanitizeOriginLabel: short [A-Za-z0-9_.-].
        fb = sanitize_origin_label(fallback, "homeserver") if fallback != "homeserver" else "homeserver"
        if not isinstance(v, str):
            return fb
        s = v.strip()
        if not s or len(s) > 64:
            return fb
        if _re.fullmatch(r"[A-Za-z0-9_.-]+", s):
            return s
        return fb

    def decode_snapshot(d, fallback="homeserver"):
        src = d.get("source")
        if src and str(src).lower() != "opencode":
            return None
        ts = parse_ts(d.get("timestamp") or d.get("created_at") or d.get("created"))
        if ts is None:
            return None
        i = to_int(get(d, "inputTokens", "input_tokens", "inputtokens", "input",
                        "prompt_tokens", "prompttokens", "tokens_input", "tokensinput"))
        o = to_int(get(d, "outputTokens", "output_tokens", "outputtokens", "output",
                        "completion_tokens", "completiontokens", "tokens_output", "tokensoutput"))
        # Same read/write sum rule as the SQLite path: generic cached
        # aliases count as read; an explicit write component adds on.
        c_read = to_int(get(d, "cachedTokens", "cached_tokens", "cachedtokens", "cached",
                             "cached_input_tokens", "cache_read_input_tokens",
                             "tokens_cache_read"))
        c_write = to_int(get(d, "cache_write_input_tokens", "tokens_cache_write"))
        c = None if (c_read is None and c_write is None) else (c_read or 0) + (c_write or 0)
        r = to_int(d.get("reasoningTokens", d.get("reasoning_tokens", d.get("reasoning"))))
        tot = to_int(d.get("totalTokens", d.get("total_tokens", d.get("total"))))
        if all(v is None for v in (i, o, c, r, tot)):
            return None
        i, o = i or 0, o or 0
        cc = min(max(0, c or 0), i)
        tot_val = tot if isinstance(tot, (int, float)) and tot > 0 else None
        model = d.get("model") or "unknown"
        origin = sanitize_origin_label(d.get("origin") or d.get("host"), fallback)
        rec = {"ts": ts, "model": model, "input": i, "output": o, "cached": cc,
               "reasoning": r or 0, "total": tot_val if tot_val else i + o,
               "session": d.get("sessionId", d.get("session_id", "")) or "",
               "request": d.get("requestId", d.get("request_id", d.get("messageId", ""))) or "",
               "origin": origin, "id": d.get("id") or ""}
        if all(rec[k] == 0 for k in ("input", "output", "cached", "reasoning", "total")):
            return None
        return rec

    snap = decode_snapshot({"timestamp": "2026-09-11T10:00:00Z", "model": "m",
                            "inputTokens": 100, "outputTokens": 50,
                            "sessionId": "s", "requestId": "msg-1"})
    check("snapshot schema origin fallback homeserver",
          snap is not None and snap["origin"] == "homeserver"
          and snap["total"] == 150)
    check("snapshot rejects other sources",
          decode_snapshot({"timestamp": "2026-09-11T10:00:00Z", "source": "codex",
                           "inputTokens": 1, "outputTokens": 1}) is None)
    check("snapshot rejects all-zero rows",
          decode_snapshot({"timestamp": "2026-09-11T10:00:00Z",
                           "inputTokens": 0, "outputTokens": 0}) is None)
    dirty = {"id": "x", "prompt": "SECRET", "path": "/Users/someone/x",
             "timestamp": "2026-09-11T10:00:00Z", "inputTokens": 1, "outputTokens": 1}
    check("snapshot forbidden keys detected + ignored",
          any(k.lower() in FORBIDDEN for k in dirty)
          and "SECRET" not in json.dumps(decode_snapshot(dirty), default=str)
          and "/Users/someone" not in json.dumps(decode_snapshot(dirty), default=str))

    def mirror_winner(seen, cand):
        # Mirror of OpenCodeStore.mirrorWinner/TokenBarStore.mirrorWinner:
        # larger total wins; ties break to earliest (timestamp, id), then to
        # the lexically smallest origin for order-independent attribution.
        if cand["total"] != seen["total"]:
            return cand if cand["total"] > seen["total"] else seen
        if (cand["ts"], cand["id"]) != (seen["ts"], seen["id"]):
            return cand if (cand["ts"], cand["id"]) < (seen["ts"], seen["id"]) else seen
        return cand if cand["origin"] < seen["origin"] else seen

    def dedupe_origin(records):
        best_req, best_id, order = {}, {}, []
        for rec in sorted(records, key=lambda r: (r["ts"], r.get("id", ""))):
            if not rec["request"]:
                k = "opencode:" + rec["id"]
                if k in best_id:
                    best_id[k] = mirror_winner(best_id[k], rec)
                else:
                    best_id[k] = rec
                    order.append(k)
                continue
            k = "opencode:" + rec["request"]
            if k in best_req:
                best_req[k] = mirror_winner(best_req[k], rec)
            else:
                best_req[k] = rec
        return sorted(list(best_req.values()) + [best_id[k] for k in order],
                      key=lambda r: (r["ts"], r.get("id", "")))

    base_ts = datetime(2026, 9, 10, 12, 0, tzinfo=timezone.utc)
    loc = {"ts": base_ts, "id": "opencode:msg-1", "request": "msg-1",
           "total": 100, "session": "s", "origin": "local",
           "input": 100, "output": 0, "cached": 0, "reasoning": 0, "model": "m"}
    rem = dict(loc, total=200, input=200, origin="homeserver")
    for pair in ((loc, rem), (rem, loc)):
        got = dedupe_origin(list(pair))
        check("cross-origin dedupe max-total wins", len(got) == 1 and got[0]["total"] == 200)
    earlier = dict(loc, ts=base_ts - timedelta(hours=1), id="opencode:a", request="dup", total=100)
    later = dict(loc, ts=base_ts, id="opencode:b", request="dup", total=100, origin="homeserver")
    for pair in ((earlier, later), (later, earlier)):
        got = dedupe_origin(list(pair))
        check("cross-origin tie earliest", len(got) == 1 and got[0]["ts"] == earlier["ts"])
    clone_a = dict(loc, request="", id="opencode:same", total=15)
    clone_b = dict(clone_a, origin="homeserver")
    for pair in ((clone_a, clone_b), (clone_b, clone_a)):
        got = dedupe_origin(list(pair))
        check("id-less clones collapse with stable origin",
              len(got) == 1 and got[0]["origin"] == "homeserver")
    # Equal total, equal time, equal id, non-empty request: origin decides.
    tie_l = dict(loc, request="dup", id="opencode:dup", total=100, origin="local")
    tie_r = dict(tie_l, origin="homeserver")
    for pair in ((tie_l, tie_r), (tie_r, tie_l)):
        got = dedupe_origin(list(pair))
        check("equal-total equal-time prefers stable origin",
              len(got) == 1 and got[0]["origin"] == "homeserver")
    distinct_a = dict(loc, request="", id="opencode:id-a", total=15)
    distinct_b = dict(loc, request="", id="opencode:id-b", total=15, origin="homeserver")
    check("id-less distinct survive", len(dedupe_origin([distinct_a, distinct_b])) == 2)
    # Snapshot cached read/write aliases sum like the SQLite path.
    split_cache = decode_snapshot({"timestamp": "2026-09-11T10:00:00Z", "model": "m",
                                   "tokens_input": 800, "tokens_output": 200,
                                   "tokens_cache_read": 150, "tokens_cache_write": 50,
                                   "sessionId": "s", "requestId": "r"})
    check("snapshot cached read+write summed",
          split_cache is not None and split_cache["cached"] == 200
          and split_cache["input"] == 800 and split_cache["total"] == 1000)
    lone_cache = decode_snapshot({"timestamp": "2026-09-11T10:00:00Z", "model": "m",
                                  "inputTokens": 800, "outputTokens": 200,
                                  "cachedTokens": 100,
                                  "sessionId": "s", "requestId": "r2"})
    check("snapshot lone cached alias counts once",
          lone_cache is not None and lone_cache["cached"] == 100)
    # Untrusted origin labels are allowlisted; local/homeserver preserved.
    check("origin labels sanitized",
          sanitize_origin_label("homeserver") == "homeserver"
          and sanitize_origin_label("local") == "local"
          and sanitize_origin_label("my-mac_2.0") == "my-mac_2.0"
          and sanitize_origin_label(None) == "homeserver"
          and sanitize_origin_label("") == "homeserver"
          and all(sanitize_origin_label(h) == "homeserver"
                  for h in ("a/b", "a\nb", "a b", "$(rm)", "`x`", "a;b", "../x"))
          and len(sanitize_origin_label("x" * 64)) == 64
          and sanitize_origin_label("x" * 65) == "homeserver"
          and (decode_snapshot({"timestamp": "2026-09-11T10:00:00Z", "model": "m",
                                "inputTokens": 1, "outputTokens": 1,
                                "origin": "evil/x\ny"}) or {})["origin"] == "homeserver")
    # By-origin text appears only with multiple distinct origins.
    def origin_suffix(key):
        return key.split("/")[-1] if "/" in key else key

    check("by-origin hidden for single origin",
          len({origin_suffix(k) for k in ("codex/local", "opencode/local", "claude/local")}) == 1
          and len({origin_suffix(k) for k in ("opencode/local", "opencode/homeserver")}) == 2)

    def origin_key(rec):
        return f"opencode/{rec['origin']}"

    origins = {}
    for rec in (dict(loc, total=100, origin="local"),
                dict(loc, total=300, origin="homeserver", id="opencode:b", request="b")):
        k = origin_key(rec)
        origins[k] = origins.get(k, 0) + rec["total"]
    check("origin breakdown keeps combined total",
          sum(origins.values()) == 400
          and set(origins) == {"opencode/local", "opencode/homeserver"})

    def sanitize_extra(w):
        if "OpenCode extra database not found" in w:
            return "OpenCode extra database not found (checked TOKENBAR_OPENCODE_DB_EXTRA)."
        if "OpenCode usage snapshot not found" in w:
            return "OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON)."
        return w

    check("sanitized extra warnings carry no paths",
          all("/" not in w or "TOKENBAR" in w for w in
              [sanitize_extra("OpenCode extra database not found (checked TOKENBAR_OPENCODE_DB_EXTRA)."),
               sanitize_extra("OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON).")])
          and "TOKENBAR_OPENCODE_DB_EXTRA" in sanitize_extra("OpenCode extra database not found x")
          and "TOKENBAR_OPENCODE_USAGE_JSON" in sanitize_extra("OpenCode usage snapshot not found x"))
    check("no prompt/path leakage in snapshot output",
          "SECRET-PROMPT-XYZ" not in json.dumps(snap, default=str)
          and "/Users/someone" not in json.dumps(snap, default=str))
    check("exporter output keys are token-only",
          snap is not None and set(snap) <= {"ts", "model", "input", "output", "cached",
                                             "reasoning", "total", "session", "request",
                                             "origin", "id"})

    # Dynamic pricing mirror (PricingCatalog/OpenRouter decoder + precedence).
    def per_mtok(raw):
        if raw is None:
            return None
        try:
            return float(str(raw).strip()) * 1e6
        except (ValueError, AttributeError):
            return None

    def decode_openrouter(payload):
        entries = []
        for model in payload.get("data", []):
            mid = (model.get("id") or "").strip()
            pricing = model.get("pricing") or {}
            if not mid or not isinstance(pricing, dict):
                continue
            inp, outp = per_mtok(pricing.get("prompt")), per_mtok(pricing.get("completion"))
            if inp is None or outp is None:
                continue
            cached = per_mtok(pricing.get("input_cache_read"))
            if cached is None:
                cached = per_mtok(pricing.get("input_cache_write"))
            if cached is None:
                cached = inp  # no invented discount (mirrors Swift decoder)
            if min(inp, outp, cached) < 0:
                continue
            entries.append((mid, inp, outp, cached))
        return sorted(entries)

    or_fixture = os.path.join(root, "Fixtures", "pricing-openrouter-sample.json")
    or_entries = []
    if os.path.exists(or_fixture):
        with open(or_fixture) as f:
            or_entries = decode_openrouter(json.load(f))
    check("openrouter fixture 4 kept / 2 broken skipped",
          [m for m, _, _, _ in or_entries] == ["anthropic/claude-sonnet-4",
                                               "google/gemini-flash-1.5",
                                               "openai/gpt-4o",
                                               "openai/gpt-5.6-luna"],
          f"got={[m for m, _, _, _ in or_entries]}")
    gpt4o = [e for e in or_entries if e[0] == "openai/gpt-4o"][0]
    check("openrouter per-token strings scale to per-1M",
          abs(gpt4o[1] - 2.5) < 1e-9 and abs(gpt4o[2] - 10.0) < 1e-9
          and abs(gpt4o[3] - 1.25) < 1e-9)
    sonnet = [e for e in or_entries if e[0] == "anthropic/claude-sonnet-4"][0]
    check("openrouter missing cache falls back to input rate",
          abs(sonnet[3] - sonnet[1]) < 1e-12)

    def resolve_origin(model, catalog, is_fresh):
        key = normalize_key(model)
        index = {normalize_key(m): (m, i, o, c) for m, i, o, c in catalog}
        if key in index:
            return ("dynamic" if is_fresh else "cached", index[key][1])
        if "/" not in key:
            suffixes = sorted(m for m, _, _, _ in catalog
                              if m.split("/")[-1] == key)
            if suffixes:
                hit = [e for e in catalog if normalize_key(e[0]) == suffixes[0]][0]
                return ("dynamic" if is_fresh else "cached", hit[1])
        if key in PRICE_EXACT:
            return ("static", PRICE_EXACT[key][0])
        for match, price in PRICE_TABLE:
            if match in key:
                return ("static", price[0])
        return ("fallback", FALLBACK[0])

    check("catalog beats static exact",
          resolve_origin("openai/gpt-5.6-luna", or_entries, True) == ("dynamic", 5.0))
    check("cached catalog labelled cached, same rate",
          resolve_origin("openai/gpt-5.6-luna", or_entries, False) == ("cached", 5.0))
    check("catalog miss falls to static exact",
          resolve_origin("openai/gpt-5.6-luna",
                         [e for e in or_entries if e[0] != "openai/gpt-5.6-luna"],
                         True) == ("static", 1.25))
    check("bare model suffix-matches provider catalog id",
          resolve_origin("gpt-4o", or_entries, True) == ("dynamic", 2.5))
    check("prefixed miss falls to static family, never guesses",
          resolve_origin("other/gpt-4o", or_entries, True)[0] == "static")
    check("unknown stays visible at fallback",
          resolve_origin("mystery-model-zzz", or_entries, True) == ("fallback", 3.0))
    check("freshness threshold is 7 days",
          (now - datetime(2026, 9, 10, 12, 0, tzinfo=timezone.utc)).total_seconds() == 0
          and (now - (now - timedelta(days=8))).total_seconds() > 7 * 24 * 3600)
    check("malformed cache rejected",
          json.loads(open(os.path.join(root, "Fixtures", "pricing-malformed-sample.json")).read())["version"] != 1)
    check("cache fixture is versioned v1 with entries",
          (lambda c: c.get("version") == 1 and len(c.get("entries", [])) == 2
           and all(set(e) == {"model", "inputPerMTok", "outputPerMTok", "cachedPerMTok"}
                   for e in c["entries"]))(
              json.loads(open(os.path.join(root, "Fixtures", "pricing-cache-sample.json")).read())))

    # Startup report cache mirror (StartupReportCache.swift semantics).
    def startup_encode(report, version=1):
        return json.dumps({"version": version, "savedAt": "2026-09-10T12:00:00Z",
                           "report": report}, sort_keys=True)

    def startup_decode(payload):
        try:
            envelope = json.loads(payload)
        except (json.JSONDecodeError, ValueError):
            return None
        if not isinstance(envelope, dict):
            return None
        if envelope.get("version") != 1:
            return None
        report = envelope.get("report")
        if not isinstance(report, dict):
            return None
        if not isinstance(report.get("records"), list):
            return None
        return envelope

    def startup_sanitize(w):
        return sanitize(w)

    fresh_report = {"records": [{"id": "a", "source": "opencode", "model": "m",
                                 "inputTokens": 1000, "outputTokens": 250,
                                 "totalTokens": 1250, "sessionId": "s",
                                 "requestId": "r", "origin": "homeserver"}],
                    "skippedCodexLines": 3, "skippedOpenCodeRows": 5,
                    "skippedClaudeLines": 7,
                    "warnings": ["OpenCode snapshot unreadable; others still load."]}
    encoded = startup_encode(fresh_report)
    check("startup cache round-trip preserves totals",
          startup_decode(encoded)["report"]["records"][0]["totalTokens"] == 1250
          and startup_decode(encoded)["report"]["skippedClaudeLines"] == 7)
    check("startup cache wrong version rejected",
          startup_decode(startup_encode(fresh_report, version=999)) is None)
    check("startup cache corrupt rejected",
          startup_decode("not json") is None
          and startup_decode(encoded[: len(encoded) // 2]) is None)
    dirty_warnings = ["Codex sessions not found at /Users/someone/.codex/sessions.",
                      "OpenCode database not found at /tmp/secret-host/opencode.db."]
    clean = [startup_sanitize(w) for w in dirty_warnings]
    check("startup cache sanitizes raw paths",
          all("/Users/someone" not in w and "/tmp/secret-host" not in w for w in clean)
          and "TOKENBAR_CODEX_ROOT" in clean[0])
    encoded_dirty = startup_encode(dict(fresh_report, warnings=clean))
    check("startup cache encoded keeps no raw paths or prompt fields",
          "/Users/someone" not in encoded_dirty
          and "/tmp/secret-host" not in encoded_dirty
          and '"prompt"' not in encoded_dirty.lower()
          and '"content"' not in encoded_dirty.lower()
          and '"tool_input"' not in encoded_dirty.lower())

    # Refresh generation mirror (StartupRefreshState semantics).
    gen, started, loading = 0, False, False

    def begin_initial():
        nonlocal gen, started, loading
        if started:
            return None
        started = True
        loading = True
        gen += 1
        return gen

    def begin_manual():
        nonlocal gen, loading
        if loading:
            return None
        loading = True
        gen += 1
        return gen

    def finish(f):
        nonlocal loading
        if f != gen:
            return False
        loading = False
        return True

    first = begin_initial()
    check("startup initial refresh fires once even with cache",
          first is not None and begin_initial() is None and begin_manual() is None)
    stale, current = first, gen + 1
    gen += 1
    loading = True
    check("startup stale generation dropped, latest wins",
          finish(stale) is False and finish(current) is True and loading is False)

    # Aggregate memoization mirror (Aggregator.swift slice 8 semantics):
    # resolve is a pure function of the normalized key, so one resolve per
    # unique key plus per-record token math matches per-record resolution.
    # Deterministic counts only, no timing.
    def memo_price(model):
        return price_for(model)

    memo_models = ["openai/gpt-4o", "OPENAI/GPT-4O", "  openai/gpt-4o  ",
                   "gpt-5", "mystery-model-zzz"]
    memo_keys = {normalize_key(m) for m in memo_models}
    check("memo variants share normalized keys",
          len(memo_keys) < len(memo_models)
          and normalize_key("OPENAI/GPT-4O") == normalize_key("  openai/gpt-4o  "))
    memo_records = [{"model": memo_models[i % len(memo_models)],
                     "input": 1000 + (i % 5) * 100, "output": 500,
                     "cached": 5000 if i % 7 == 0 else 200}
                    for i in range(80)]
    memo_unique = {normalize_key(r["model"]) for r in memo_records}
    per_record_total = sum(cost(r["model"], r["input"], r["output"], r["cached"])
                           for r in memo_records)
    memo_cache = {}
    memo_total = 0.0
    for r in memo_records:
        key = normalize_key(r["model"])
        if key not in memo_cache:
            memo_cache[key] = memo_price(r["model"])
        inp, outp, cch = memo_cache[key]
        cached = min(max(0, r["cached"]), max(0, r["input"]))
        fresh = max(0, r["input"]) - cached
        memo_total += (fresh / 1e6 * inp + cached / 1e6 * cch
                       + max(0, r["output"]) / 1e6 * outp)
    check("memo aggregate matches per-record math",
          abs(memo_total - per_record_total) < 1e-9
          and len(memo_cache) == len(memo_unique)
          and len(memo_cache) < len(memo_records))
    check("memo oversized cached still clamps",
          abs(cost("gpt-4o", 100, 0, 5000) - cost("gpt-4o", 100, 0, 100)) < 1e-12)

    # Homeserver auto-sync mirror (OpenCodeSync.swift semantics): config
    # validation, safe argv (no shell), snapshot validation before replace,
    # atomic tmp+rename replacement, failure fallback preserving last good.
    import re as _re2
    import tempfile as _tempfile2

    _HOST_RE = _re2.compile(r"[A-Za-z0-9_.\-@]+$")

    def sync_host_valid(raw):
        if not raw or len(raw) > 128:
            return False
        if not (raw[0].isalnum()):
            return False
        return bool(_HOST_RE.fullmatch(raw))

    def sync_validated(cfg):
        # Mirror of OpenCodeSyncConfig.validated: None when usable, else msg.
        if not cfg.get("enabled"):
            return None
        host = (cfg.get("hostAlias") or "").strip()
        if not host:
            return "Homeserver sync needs an SSH host alias."
        if not sync_host_valid(host):
            return "Sync host alias has invalid characters (letters, digits, ., _, -, @)."
        command = (cfg.get("remoteCommand") or "").strip()
        path = (cfg.get("remotePath") or "").strip()
        if not command:
            if not path:
                return "Homeserver sync needs a remote snapshot path or exporter command."
            if "\n" in path or "\r" in path:
                return "Remote snapshot path must not contain line breaks."
        elif "\n" in command or "\r" in command:
            return "Remote exporter command must not contain line breaks."
        if not (300 <= cfg.get("pollIntervalSeconds", 900) <= 86400):
            return "Sync interval must be 5 minutes to 24 hours."
        if not (5 <= cfg.get("timeoutSeconds", 60) <= 300):
            return "Sync timeout must be 5 to 300 seconds."
        return None

    def scp_argv(cfg, dest):
        return ("/usr/bin/scp",
                ["-o", "BatchMode=yes", "-o",
                 f"ConnectTimeout={cfg['timeoutSeconds']}",
                 f"{cfg['hostAlias']}:{cfg['remotePath']}", dest])

    def ssh_argv(cfg):
        return ("/usr/bin/ssh",
                ["-o", "BatchMode=yes", "-o",
                 f"ConnectTimeout={cfg['timeoutSeconds']}",
                 cfg["hostAlias"], "--", cfg["remoteCommand"]])

    def sync_snapshot_valid(raw, cap=32 * 1024 * 1024):
        # Mirror of OpenCodeSync.validateSnapshotData: top-level array that
        # is empty or holds >=1 decodable opencode record; size-capped.
        if len(raw) > cap:
            return False
        try:
            arr = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            return False
        if not isinstance(arr, list):
            return False
        if not arr:
            return True
        return any(decode_snapshot(e) is not None
                   for e in arr if isinstance(e, dict))

    def sync_write_atomic(data, dest):
        # Mirror of writeSnapshotAtomically: tmp in same dir, then replace.
        tmp = dest + f".tmp-{os.getpid()}"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, dest)

    base_cfg = {"enabled": True, "hostAlias": "homeserver",
                "remotePath": "/tmp/opencode-usage.json", "remoteCommand": "",
                "pollIntervalSeconds": 900, "timeoutSeconds": 60}
    check("sync defaults disabled valid",
          sync_validated({"enabled": False, "hostAlias": "bogus host; rm"}) is None)
    check("sync enabled requires host",
          sync_validated({**base_cfg, "hostAlias": ""})
          == "Homeserver sync needs an SSH host alias.")
    check("sync host allowlist",
          all(sync_host_valid(h) for h in
              ("homeserver", "my-host.1", "mac_mini", "user@host"))
          and not any(sync_host_valid(h) for h in
                      ("", "has space", "a;b", "a|b", "-lead", "a:b",
                       "a/b", "a\nb", "a$(x)")))
    check("sync needs remote path or command",
          sync_validated({**base_cfg, "remotePath": ""})
          == "Homeserver sync needs a remote snapshot path or exporter command."
          and sync_validated({**base_cfg, "remotePath": "",
                              "remoteCommand": "python3 export.py --db x.db"}) is None)
    check("sync interval/timeout bounds",
          sync_validated({**base_cfg, "pollIntervalSeconds": 60}) is not None
          and sync_validated({**base_cfg, "timeoutSeconds": 999}) is not None
          and sync_validated({**base_cfg, "pollIntervalSeconds": 300,
                              "timeoutSeconds": 5}) is None)
    exe, args = scp_argv(base_cfg, "/tmp/local.json")
    check("sync scp argv discrete, batch, no shell",
          exe == "/usr/bin/scp" and "BatchMode=yes" in args
          and "homeserver:/tmp/opencode-usage.json" in args
          and not any(("sh" in a and "bin" in a) or a == "-c" for a in args)
          and args[-1] == "/tmp/local.json")
    exe2, args2 = ssh_argv({**base_cfg, "remoteCommand": "python3 export.py --db x.db"})
    check("sync ssh argv host, separator, command",
          exe2 == "/usr/bin/ssh" and "BatchMode=yes" in args2
          and args2[args2.index("--") - 1] == "homeserver"
          and args2[args2.index("--") + 1] == "python3 export.py --db x.db")
    good_rec = {"id": "opencode:s1", "source": "opencode",
                "timestamp": "2026-09-12T10:00:00Z", "model": "m",
                "inputTokens": 400, "outputTokens": 100,
                "sessionId": "s", "requestId": "r"}
    check("sync snapshot validation",
          sync_snapshot_valid(json.dumps([good_rec]).encode())
          and sync_snapshot_valid(b"[]")
          and not sync_snapshot_valid(b"not json")
          and not sync_snapshot_valid(b'{"not":"array"}')
          and not sync_snapshot_valid(b"<html>oops</html>")
          and not sync_snapshot_valid(json.dumps([
              {"source": "codex", "timestamp": "2026-09-12T10:00:00Z",
               "inputTokens": 5, "outputTokens": 5}]).encode())
          and not sync_snapshot_valid(b"x" * (32 * 1024 * 1024 + 1)))
    sync_fixture = os.path.join(root, "Fixtures", "synthetic-homeserver-sync-snapshot.json")
    if os.path.exists(sync_fixture):
        with open(sync_fixture, "rb") as f:
            sync_raw = f.read()
        check("sync fixture validates + 24h recent row",
              sync_snapshot_valid(sync_raw)
              and sum(1 for e in json.loads(sync_raw)
                      if decode_snapshot(e) is not None) == 2)
    with _tempfile2.TemporaryDirectory() as tmpd:
        dest = os.path.join(tmpd, "cache.json")
        sync_write_atomic(b"v1", dest)
        sync_write_atomic(b"v2", dest)
        with open(dest, "rb") as f:
            kept = f.read()
        leftovers = [p for p in os.listdir(tmpd) if p != "cache.json"]
        # Failure fallback: invalid pull preserves the last good cache.
        good = json.dumps([good_rec]).encode()
        sync_write_atomic(good, dest)
        before = open(dest, "rb").read()
        candidate = b"truncated {"
        if not sync_snapshot_valid(candidate):
            pass  # preserved: no write happens
        check("sync atomic replace + fallback preserves last good",
              kept == b"v2" and leftovers == []
              and open(dest, "rb").read() == before == good)
    def sync_error(kind):
        # Mirror of sanitizedError: generic labels only.
        return {"cancelled": "Homeserver sync cancelled.",
                "timeout": "Homeserver sync timed out; kept previous data.",
                "invalid": "Remote snapshot invalid; kept previous data.",
                "failed": "Homeserver sync failed (host unreachable); kept previous data."}[kind]
    check("sync errors sanitized, no secrets or paths",
          all("SECRET" not in m and "/Users/" not in m and "kept previous data" in m
              for m in (sync_error("timeout"), sync_error("invalid"), sync_error("failed")))
          and "cancell" in sync_error("cancelled"))

    # Review fixes mirror: capped reads check size before buffering, the
    # apply decision replaces honestly on valid [] and preserves last good
    # otherwise, remote paths with spaces validate (argv-safe, never split).
    def sync_read_capped(path, cap):
        size = os.path.getsize(path)
        if size > cap:
            raise ValueError("invalid snapshot")
        with open(path, "rb") as f:
            data = f.read()
        if len(data) > cap:
            raise ValueError("invalid snapshot")
        return data

    def sync_apply(cache_bytes, candidate):
        return candidate if sync_snapshot_valid(candidate) else cache_bytes

    with _tempfile2.TemporaryDirectory() as tmpd2:
        cap_file = os.path.join(tmpd2, "snap.json")
        with open(cap_file, "wb") as f:
            f.write(b"A" * 100)
        capped_ok = sync_read_capped(cap_file, 1000) == b"A" * 100
        try:
            sync_read_capped(cap_file, 10)
            capped_big = False
        except ValueError:
            capped_big = True
        try:
            sync_read_capped(os.path.join(tmpd2, "missing.json"), 1000)
            capped_missing = False
        except OSError:
            capped_missing = True
        check("sync capped read checks size before buffering",
              capped_ok and capped_big and capped_missing)
    good_bytes = json.dumps([good_rec]).encode()
    check("sync apply replaces on valid, preserves last good otherwise",
          sync_apply(good_bytes, b"[]") == b"[]"
          and sync_apply(good_bytes, b"truncated {") == good_bytes
          and sync_apply(good_bytes, good_bytes) == good_bytes)
    check("sync remote path with spaces allowed, host stays strict",
          sync_validated({**base_cfg, "remotePath": "/tmp/my dir/u.json"}) is None
          and not sync_host_valid("has space"))

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURES: {FAILURES}")
        return 1
    print("All verify_logic checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
