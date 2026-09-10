# Token Bar

[![CI](https://github.com/ManuOtel/token-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/ManuOtel/token-bar/actions/workflows/ci.yml)

Native macOS menu bar utility that totals token usage from local Codex,
OpenCode, and Claude Code history. File reads only. No accounts, no cookies,
no network.

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

## Direct terminal usage (no menu bar)

Default report is **lifetime / all sources**: total/input/output/cached/
reasoning tokens, requests, sessions, clearly labelled estimated cost,
last updated, plus Codex/OpenCode/Claude source splits and top models. Output never
includes file paths or prompt text.

```sh
./scripts/show-usage.sh
./scripts/show-usage.sh --preset today
./scripts/show-usage.sh --preset 7d --source codex
./scripts/show-usage.sh --preset 7d --source claude
./scripts/show-usage.sh --all-presets
./scripts/show-usage.sh --preset lifetime --json
./scripts/run-token-bar.sh   # menu bar launcher (macOS 14+)
```

Raw Swift equivalents:

```sh
swift run TokenBarCLI
swift run TokenBarCLI --preset today --source all
swift run TokenBarCLI --preset 24h --source codex
swift run TokenBarCLI --all-presets --source all
swift run TokenBarCLI --preset lifetime --json
swift run TokenBarApp
```

Flags:

- `--preset today | 24h | 7d | 30d | best-month | lifetime`
  (default `lifetime`).
- `--source all | codex | opencode | claude` (default `all`).
- `--all-presets`: print today, 24h, 7d, 30d, best month, lifetime in one
  fixed-order pass for the chosen source.
- `--json`: machine-readable array of per-preset objects (same totals plus
  `bestMonth`, `bySource`, `byModel`, sanitized `warnings`).
- `--help` / `-h`: usage.

What each report means:

- **today**: local calendar day `[startOfDay(now), now]`.
- **24h / 7d / 30d**: rolling windows ending at `now`, inclusive.
- **best month**: the local `yyyy-MM` month with max total tokens over the
  filtered lifetime set (ties go to the earliest month); header shows the
  winning month key.
- **lifetime**: everything, no date filter.
- **source splits**: per-source tokens/requests/cost, sorted tokens desc.
- **cost**: always labelled `Estimated cost ... (estimate ...)`; static
  per-1M table in `Pricing.swift`, unknown models use the fallback rate.
- **warnings**: sanitized counts only (for example `Codex sessions not
  found (checked default location or TOKENBAR_CODEX_ROOT)`). No absolute
  paths are ever printed.

## Data sources (local only)

| Source  | Path | Format |
|---|---|---|
| Codex | `~/.codex/sessions/**/*.jsonl` | JSONL, `token_usage_record` payloads |
| OpenCode | `~/.local/share/opencode/opencode.db` | SQLite, `session_v2` + legacy `session` |
| Claude | `~/.claude/projects/**/*.jsonl` | JSONL, assistant `message.usage` records |

Overrides for testing: `TOKENBAR_CODEX_ROOT`, `TOKENBAR_OPENCODE_DB`,
`TOKENBAR_CLAUDE_ROOT`.

Privacy: all adapters open files read-only. Nothing leaves the machine.
No subscription auth, no provider APIs, no cookies, no network calls exist
in this codebase (verify: `rg -i "URLSession|http|cookie|token.*api" Sources`).

## Semantics

### Tokens

Per record: `input`, `output`, `cached`, `reasoning`, `total`.
`total = explicit total_tokens` when positive, else `input + output`.
`cached` is a subset of input; `reasoning` a subset of output. Neither is
ever added on top of the total.

OpenCode note: the schema stores `tokens_input` separately from
`tokens_cache_read`/`tokens_cache_write`, so normalized `input` folds
cache back in (`tokens_input + cache_read + cache_write`) and the total
fallback includes cached usage. Codex needs no fold: its
`payload.usage` input already includes cached input. Claude Code folds
like OpenCode: Anthropic usage semantics sum all three input components,
so normalized `input = input_tokens + cache_read_input_tokens +
cache_creation_input_tokens`. Cost stays
consistent either way: cached is billed at the cached rate on
`min(cached, input)`.

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

Filters: **All / Codex / OpenCode / Claude**.

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
  Claude `requestId` prefers the per-message API id (`message.id`), then the
  outer request id; lines without either stay unique via a stable
  root-relative `path:line` id.
- Malformed JSONL lines, unknown types without token fields, bad timestamps,
  and undecodable DB rows are skipped and counted (`LoadReport`), surfaced in
  the dashboard as warnings. Missing files/tables degrade to empty + warning.

## Testing

```sh
swift test            # Mac / any host with Swift 5.9+
python3 scripts/verify_logic.py   # this Linux host (mirrors core semantics + report format)
```

CI (`.github/workflows/ci.yml`, runs on `main` and PRs) mirrors this split:

- macOS 14 job: `swift build` + `swift test` (source of truth).
- Linux job: `PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_logic.py`
  plus shell syntax checks (`bash -n` / `sh -n`) on `scripts/*.sh`.
- Privacy gate: fails if `Sources` contains `URLSession` / `http` / `cookie`
  indicators, except the documented local-only comment
  (`No auth, no cookies, no network` in `Store.swift`).

Covers: Codex valid/alias/nested/type-gate/malformed/epoch/unknown-model,
OpenCode column-form/legacy/JSON-blob/missing-timestamp/no-counts/fallback/
nulls, Claude valid/cache-pair/type-gate/missing-usage/malformed/epoch-ISO/
dedupe/source-isolation/sanitizer, plus filtering (source, today-vs-24h, 7d/30d, inclusive bounds),
best-month max + earliest-tiebreak, totals/sessions/cost/breakdowns,
cached-subset accounting (OpenCode cache fold-in, explicit-total-wins),
dedupe, empty aggregation, plus CLI report
formatting (lifetime totals labels, warning path sanitizing, best-month key,
deterministic JSON, no raw paths in output).

## Limitations

- Estimates only: pricing table is static and drifts from provider lists.
- OpenCode schema drift is handled heuristically; exotic future schemas may
  skip rows (counted, visible).
- No live sync, no multi-machine merge, no export in the MVP.
- App target needs macOS 14+; Linux runs logic verification only.

## Troubleshooting missing data

- `No usage records in this scope`: the filter/preset matched zero records.
  Retry `./scripts/show-usage.sh --preset lifetime --source all`.
- `Codex sessions not found (...)`: default `~/.codex/sessions/**/*.jsonl`
  is absent. Point testing data with
  `TOKENBAR_CODEX_ROOT=/tmp/fake-codex ./scripts/show-usage.sh`.
- `OpenCode database not found (...)`: default
  `~/.local/share/opencode/opencode.db` is absent. Point testing data with
  `TOKENBAR_OPENCODE_DB=/tmp/fake.db ./scripts/show-usage.sh`.
- `Claude sessions not found (...)`: default
  `~/.claude/projects/**/*.jsonl` is absent. Point testing data with
  `TOKENBAR_CLAUDE_ROOT=/tmp/fake-claude ./scripts/show-usage.sh`.
- `N Codex line(s) skipped` / `N OpenCode row(s) skipped` / `N Claude line(s)
  skipped`: malformed or non-usage entries were counted, not fatal. CLI output never prints paths
  or prompt text, only sanitized warning counts and labels.
- Linux worker host: `swift` is not installed, so use
  `python3 scripts/verify_logic.py`. Build and run `TokenBarCLI` /
  `TokenBarApp` on a Mac with Xcode 15+.

## Contributing

Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).
Add synthetic fixtures only under `Fixtures/` - never real session logs.
Update tests when touching `TokenBarCore` semantics.
