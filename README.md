# Token Bar

Native macOS menu bar utility that totals token usage from local Codex and
OpenCode history. File reads only. No accounts, no cookies, no network.

## Requirements

- Minimum macOS **14.0 (Sonoma)**, Xcode 15+ with Swift 5.9 SDK for the app.
- Linux (this host): Swift toolchain is **not** installed, so `swift build` /
  `swift test` cannot run here. Core logic is mirrored by a Python
  verification script (see Testing). Full Xcode remains unavailable on this
  host; build the app on a Mac.

## Build / Run (on a Mac)

```sh
swift build
swift test
swift run TokenBarApp
```

Xcode alternative: open the folder in Xcode (`File > Open`), select the
`TokenBarApp` scheme, Run. The app lives in the menu bar (accessory policy,
`MenuBarExtra` + `NSApplicationDelegate`).

## Data sources (local only)

| Source  | Path | Format |
|---|---|---|
| Codex | `~/.codex/sessions/**/*.jsonl` | JSONL, `token_usage_record` payloads |
| OpenCode | `~/.local/share/opencode/opencode.db` | SQLite, `session_v2` + legacy `session` |

Overrides for testing: `TOKENBAR_CODEX_ROOT`, `TOKENBAR_OPENCODE_DB`.

Privacy: both adapters open files read-only. Nothing leaves the machine.
No subscription auth, no provider APIs, no cookies, no network calls exist
in this codebase (verify: `rg -i "URLSession|http|cookie|token.*api" Sources`).

## Semantics

### Tokens

Per record: `input`, `output`, `cached`, `reasoning`, `total`.
`total = explicit total_tokens` when positive, else `input + output`.
`cached` is a subset of input; `reasoning` a subset of output. Neither is
ever added on top of the total.

Field aliases are accepted (`prompt_tokens`, `completion_tokens`,
`cached_input_tokens`, ...). Unknown models are kept as-is (empty becomes
`"unknown"`) and priced at fallback rates.

### Presets (upper bound is always `now`, inclusive)

- **Today**: local calendar day, `[startOfDay(now), now]`.
- **Last 24 hours**: rolling `[now-24h, now]`.
- **Last 7 days**: rolling `[now-7d, now]`.
- **Last 30 days**: rolling `[now-30d, now]`.
- **Best month**: over the filtered lifetime set, the local calendar month
  (`yyyy-MM`) with max total tokens; ties break to the earliest month.
- **Lifetime**: everything, no date filter.

Filters: **All / Codex / OpenCode**.

### Counts

- `requests` = records in scope. `sessions` = distinct non-empty `sessionId`.
- `last updated` = max record timestamp in scope.
- Breakdowns group by model and by source (tokens desc, key asc on ties).
- Daily trend buckets by local calendar day (`yyyy-MM-dd`), ascending.

### Cost (estimate)

Per model per 1M tokens: `(input-cached)*inputRate + cached*cachedRate +
output*outputRate`, all /1M, USD. Reasoning rides inside output, never extra.
Rates are hardcoded public-listing approximations in `Pricing.swift`;
unknown models use the fallback ($3.00 / $12.00 / $1.50). Treat every dollar
figure as an estimate.

### Dedup and malformed data

- Same `source` + same non-empty `requestId` collapses to the earliest
  `(timestamp, id)` record. Records without a `requestId` are unique by `id`.
- Malformed JSONL lines, unknown types without token fields, bad timestamps,
  and undecodable DB rows are skipped and counted (`LoadReport`), surfaced in
  the dashboard as warnings. Missing files/tables degrade to empty + warning.

## Testing

```sh
swift test            # Mac / any host with Swift 5.9+
python3 scripts/verify_logic.py   # this Linux host (mirrors core semantics)
```

Covers: Codex valid/alias/nested/type-gate/malformed/epoch/unknown-model,
OpenCode column-form/legacy/JSON-blob/missing-timestamp/no-counts/fallback/
nulls, plus filtering (source, today-vs-24h, 7d/30d, inclusive bounds),
best-month max + earliest-tiebreak, totals/sessions/cost/breakdowns,
cached-subset accounting, dedupe, empty aggregation.

## Limitations

- Estimates only: pricing table is static and drifts from provider lists.
- OpenCode schema drift is handled heuristically; exotic future schemas may
  skip rows (counted, visible).
- No live sync, no multi-machine merge, no export in the MVP.
- App target needs macOS 14+; Linux runs logic verification only.

## Contributing

Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).
Add synthetic fixtures only under `Fixtures/` - never real session logs.
Update tests when touching `TokenBarCore` semantics.
