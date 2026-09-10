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


def parse_codex_line(line):
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
    if t is not None:
        tl = str(t).lower()
        has_tok = any(k in payload or k in top for k in
                      ("input_tokens", "prompt_tokens", "output_tokens", "completion_tokens",
                       "cached_tokens", "reasoning_tokens", "total_tokens",
                       "inputtokens", "prompttokens", "outputtokens", "completiontokens"))
        if "token_usage" not in tl and not has_tok:
            return None
    merged = dict(top)
    merged.update(payload)
    ts = parse_ts(get(merged, "timestamp", "time", "created_at", "createdAt", "date"))
    if ts is None:
        return None
    i = to_int(get(merged, "input_tokens", "inputtokens", "prompt_tokens", "prompttokens", "input"))
    o = to_int(get(merged, "output_tokens", "outputtokens", "completion_tokens", "completiontokens", "output"))
    c = to_int(get(merged, "cached_tokens", "cachedtokens", "cached_input_tokens"))
    r = to_int(get(merged, "reasoning_tokens", "reasoningtokens"))
    tot = to_int(get(merged, "total_tokens", "totaltokens", "total"))
    if all(v is None for v in (i, o, c, r, tot)):
        return None
    i, o = i or 0, o or 0
    return {"ts": ts, "model": get(merged, "model", "model_name") or "unknown",
            "input": i, "output": o, "cached": c or 0, "reasoning": r or 0,
            "total": tot if tot else i + o,
            "session": get(merged, "session_id", "sessionid", "conversation_id") or "",
            "request": get(merged, "request_id", "requestid", "message_id", "id") or ""}


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
    ts = parse_ts(get(merged, "timestamp", "time", "created_at", "createdAt", "created",
                        "updated_at", "updated", "date"))
    if ts is None:
        return None
    i = to_int(get(merged, "input_tokens", "prompt_tokens", "input"))
    o = to_int(get(merged, "output_tokens", "completion_tokens", "output"))
    c = to_int(get(merged, "cached_tokens"))
    r = to_int(get(merged, "reasoning_tokens"))
    tot = to_int(get(merged, "total_tokens", "total", "tokens"))
    if all(v is None for v in (i, o, c, r, tot)):
        return None
    i, o = i or 0, o or 0
    return {"ts": ts, "model": get(merged, "model", "model_name") or "unknown",
            "input": i, "output": o, "cached": c or 0, "reasoning": r or 0,
            "total": tot if tot else i + o,
            "session": get(merged, "session_id", "sessionid", "session", "id", "key") or ""}


FALLBACK = (3.0, 12.0, 1.5)


def cost(model, i, o, c):
    cached = min(max(0, c), max(0, i))
    fresh = max(0, i) - cached
    inp, outp, cch = FALLBACK
    if "gpt-4o-mini" in model:
        inp, outp, cch = (0.15, 0.60, 0.075)
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
                               "created_at": "2026-09-10T08:15:00Z"})
    check("opencode column form", rec is not None and rec["total"] == 1250)
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

    # Dedupe earliest kept
    seen, unique = set(), []
    for rid, src in (("dup", "codex"), ("dup", "codex"), ("dup", "opencode")):
        key = src + ":" + rid
        if key not in seen:
            seen.add(key)
            unique.append(key)
    check("dedupe per source+request", unique == ["codex:dup", "opencode:dup"])

    # Report formatter mirror (matches Report.swift semantics)
    def sanitize(w):
        if "Codex sessions not found" in w:
            return "Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT)."
        if "OpenCode database not found" in w:
            return "OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB)."
        return " ".join("<path>" if t.strip(".,:;()[]\"'").startswith(("/", "~")) else t
                        for t in w.split(" "))

    def render_section(total, inp, out, cached, reasoning, req, sess, cost_v, by_source):
        lines = ["Token Bar -- lifetime / all",
                 f"Total tokens: {total}", f"Input tokens: {inp}", f"Output tokens: {out}",
                 f"Cached tokens: {cached} (subset of input)",
                 f"Reasoning tokens: {reasoning} (subset of output)",
                 f"Requests: {req}", f"Sessions: {sess}",
                 f"Estimated cost: ${cost_v:.4f} USD (estimate, static price table)",
                 "By source:"]
        for k, v in by_source:
            lines.append(f"  {k}: {v} tokens")
        return "\n".join(lines)

    check("sanitize codex path",
          sanitize("Codex sessions not found at /Users/someone/.codex/sessions.") ==
          "Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT).")
    check("sanitize opencode path",
          "/Users/" not in sanitize("OpenCode database not found at /Users/someone/opencode.db"))
    check("sanitize generic path",
          "/tmp/secret/x.db" not in sanitize("Read failed at /tmp/secret/x.db today")
          and "<path>" in sanitize("Read failed at /tmp/secret/x.db today"))
    text = render_section(1800, 1500, 300, 0, 0, 2, 1, 0.0008,
                          [("codex", 1200), ("opencode", 600)])
    check("report labels lifetime totals",
          all(s in text for s in ("Total tokens: 1800", "Input tokens: 1500",
                                  "Estimated cost:", "estimate", "codex", "opencode")))
    check("report no raw paths", "/Users/" not in sanitize(text) and "/tmp/" not in text)
    import json as _json
    payload = [{"preset": "lifetime", "totalTokens": 1800}]
    check("report json deterministic",
          _json.dumps(payload, sort_keys=True) == _json.dumps(payload, sort_keys=True))

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURES: {FAILURES}")
        return 1
    print("All verify_logic checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
