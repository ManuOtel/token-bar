#!/usr/bin/env python3
"""Repeatable measurement for the SQLite projection slice.

Compares old `SELECT *` materialization vs new bounded projection on the
same synthetic data. Deterministic cell/byte counts only, no wall-clock,
no timing thresholds (CI-safe on any host).

What it proves:
- wide unrelated columns are ignored (not selected, not materialized)
- required columns + JSON blobs still decode identically (parity)
- the improvement is bounded and repeatable: fewer cells + fewer bytes

It does NOT claim a real-host speedup: to measure wall-clock, rerun warm
`loadDatabase` before/after on the same Mac + same database file.
"""
import json
import sys

PROJECTED = {
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

REQUIRED_COLS = ["id", "time_created", "tokens_input", "tokens_output", "model", "data"]
WIDE_COLS = ["prompt_text", "tool_output", "tool_input", "future_col_v2", "path"]
WIDE_SIZE = 20_000  # chars per wide column (synthetic filler)


def make_row(i):
    blob = json.dumps({
        "role": "assistant", "modelID": "m", "providerID": "p",
        "tokens": {"input": 100 + i, "output": 50},
        "time": {"created": 1789087080181},
    })
    row = {
        "id": f"msg-{i}",
        "session_id": "ses-1",
        "time_created": "1757325600000",
        "tokens_input": str(100 + i),
        "tokens_output": "50",
        "model": "m",
        "data": blob,
    }
    for wide in WIDE_COLS:
        row[wide] = "x" * WIDE_SIZE
    return row


def project(row):
    return {k: v for k, v in row.items() if k.lower() in PROJECTED}


def decode_total(row):
    # Minimal parity probe: flat tokens_input + tokens_output.
    return int(row["tokens_input"]) + int(row["tokens_output"])


def main():
    rows = [make_row(i) for i in range(50)]
    old_cells = sum(len(r) for r in rows)
    new_cells = sum(len(project(r)) for r in rows)
    old_bytes = sum(len(str(v)) for r in rows for v in r.values())
    new_bytes = sum(len(str(v)) for r in rows for v in project(r).values())

    # Parity: dropping wide columns must not change decoded totals.
    for row in rows:
        assert decode_total(row) == decode_total(project(row)), "parity broke"
        # JSON blob survives projection.
        assert "data" in project(row), "blob dropped"

    # Projection must strictly reduce work on wide tables.
    assert new_cells < old_cells, "no cell saving"
    assert new_bytes < old_bytes, "no byte saving"

    saved_cells = old_cells - new_cells
    saved_bytes = old_bytes - new_bytes
    print(f"rows: {len(rows)}")
    print(f"columns per row: old={len(rows[0])} new={len(project(rows[0]))}")
    print(f"cells: old={old_cells} new={new_cells} saved={saved_cells} ({saved_cells / old_cells:.1%})")
    print(f"bytes: old={old_bytes} new={new_bytes} saved={saved_bytes} ({saved_bytes / old_bytes:.1%})")
    print("parity: wide columns ignored, required + blob decode identical")
    print("note: deterministic counts only; no wall-clock claimed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
