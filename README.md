# Token Bar

[![CI](https://github.com/ManuOtel/token-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/ManuOtel/token-bar/actions/workflows/ci.yml)

Native macOS menu bar utility that totals token usage from local Codex,
OpenCode, and Claude Code history. File reads only, plus one strictly
opt-in pricing refresh (public catalog GET, no usage data sent).
No accounts, no cookies.

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

## Install (packaged app)

```sh
./scripts/build-app.sh --version 0.1.0            # dist/TokenBar.app
./scripts/package-release.sh --version 0.1.0 --format zip
(cd dist && shasum -a 256 -c TokenBar-0.1.0-macos.zip.sha256)
```

Unzip, drag `TokenBar.app` to Applications, open. Dev loop needs no bundle:
`./scripts/run-token-bar.sh`. The dashboard has a launch-at-login toggle
(`SMAppService.mainApp`); under `swift run` it stays disabled with dev-run
copy. Uninstall: toggle login off, quit, delete the app. Full path
(signing, `notarytool`, staple, DMG, troubleshooting): `docs/MACOS_PACKAGING.md`.

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
  `bestMonth`, `bySource`, `byModel`, `byOrigin` (`source/origin` pairs),
  sanitized `warnings`).
- `--refresh-pricing`: fetch the public model pricing catalog before
  reporting (`GET https://openrouter.ai/api/v1/models`; no usage data
  sent). Without it the CLI is fully offline and uses the static table.
- `--help` / `-h`: usage.

What each report means:

- **today**: local calendar day `[startOfDay(now), now]`.
- **24h / 7d / 30d**: rolling windows ending at `now`, inclusive.
- **best month**: the local `yyyy-MM` month with max total tokens over the
  filtered lifetime set (ties go to the earliest month); header shows the
  winning month key.
- **lifetime**: everything, no date filter.
- **source splits**: per-source tokens/requests/cost, sorted tokens desc.
- **cost**: always labelled `Estimated cost ... (estimate only; static table,
  not a bill; subscription use is not an API invoice)`; with
  `--refresh-pricing` (or the app Update pricing button) a `Pricing:` line
  names the rate basis (`dynamic catalog` / `cached catalog` / `static
  estimates` with host, model count, age). Resolution: fresh catalog, cached
  catalog, exact provider/model static table, family static table, fallback.
  Unknown models use the fallback rate.
- **warnings**: sanitized counts only (for example `Codex sessions not
  found (checked default location or TOKENBAR_CODEX_ROOT)`). No absolute
  paths are ever printed.

## Data sources (local only)

| Source  | Path | Format |
|---|---|---|
| Codex | `~/.codex/sessions/**/*.jsonl` | JSONL, `token_usage_record` payloads + `turn_context` model map |
| OpenCode | `~/.local/share/opencode/opencode.db` | SQLite, per-message `message` + `session_message` (authoritative); per-session `session_v2` + `session` rollups fill uncovered sessions only |
| OpenCode extras | `TOKENBAR_OPENCODE_DB_EXTRA` (extra read-only DB copies) | Same SQLite shape, origin `homeserver` |
| OpenCode snapshot | `TOKENBAR_OPENCODE_USAGE_JSON` (sanitized snapshot files) | JSON array from `scripts/export-opencode-usage.py` (token counts only) |
| Claude | `~/.claude/projects/**/*.jsonl` | JSONL, assistant `message.usage` records |

Overrides for testing: `TOKENBAR_CODEX_ROOT`, `TOKENBAR_OPENCODE_DB`,
`TOKENBAR_CLAUDE_ROOT`. Multi-machine merge (offline only, no network):
`TOKENBAR_OPENCODE_DB_EXTRA` (comma- or newline-separated extra read-only DB
paths, empty entries ignored) and `TOKENBAR_OPENCODE_USAGE_JSON`
(comma- or newline-separated sanitized snapshot paths). Colons and
semicolons never split: both are legal filename characters, so colon-bearing
paths stay whole. Extra DB rows load
with origin `homeserver`; snapshot rows keep their embedded origin
(`homeserver` when missing). Snapshot origin labels are allowlisted to a
short `[A-Za-z0-9_.-]` form (anything else falls back to `homeserver`).
With only `TOKENBAR_OPENCODE_DB` set, behavior
is exactly as before. Missing extras are warnings only and never stop
Codex/Claude/local usage. The `By origin` CLI section prints only when more
than one distinct origin is present, so local-only output never duplicates
`By source`.

Homeserver-to-Mac workflow (you copy the file; the app never fetches it):

```sh
# On the homeserver (read-only export, token counts only):
python3 scripts/export-opencode-usage.py --db ~/.local/share/opencode/opencode.db \
    --out /tmp/opencode-usage.json --origin homeserver
# Copy /tmp/opencode-usage.json to the Mac by any means you operate
# (USB stick, existing file sync, manual copy). No HTTP API exists and no
# SSH hostname is assumed.
# On the Mac:
TOKENBAR_OPENCODE_USAGE_JSON=/tmp/opencode-usage.json ./scripts/show-usage.sh --preset 7d
```

`7D` (and every rolling preset) is based on record timestamps: a session
created weeks ago still counts when its messages fall in the window.
Lifetime can be nonzero when recent data lives on another host: import the
homeserver snapshot and the combined total appears.

Privacy: all adapters open files read-only. Usage data never leaves the
machine. The only network call in the codebase is the strictly opt-in
pricing refresh (`PricingService`: one `GET` of public model/pricing
metadata, no prompts/counts/paths/credentials sent; see
`docs/PRICING.md`). No subscription auth, no provider APIs, no cookies
(verify: `rg -i "URLSession" Sources` hits only `PricingService.swift`;
`rg -i "cookie|Authorization" Sources` hits only documented never-send
comments).

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
`cached_input_tokens`, ...). Codex model attribution is file-sequential:
per-record `model|model_name` wins, else the latest `turn_context` entry for
the same `turn_id` applies, else a single-model `thread_id` fallback, else
`"unknown"` (never empty, never invented; raw strings group exactly).
Unknown models are kept as-is (empty becomes
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

- `requests` = records in scope (Codex/Claude: one per usage line;
  OpenCode: one per assistant message, or one per session for rollup
  fallback rows). `sessions` = distinct non-empty `sessionId`.
- `last updated` = max record timestamp in scope.
- Breakdowns group by model and by source (tokens desc, key asc on ties).
- Daily trend buckets by local calendar day (`yyyy-MM-dd`), ascending.

### Cost (static estimate only, never a bill)

Per model per 1M tokens: `(input-cached)*inputRate + cached*cachedRate +
output*outputRate`, all /1M, USD. Reasoning rides inside output, never extra.
Cached is capped with `min(cached, input)`; `total` is never used for cost.

Resolution order (deterministic, case-insensitive): 1. fresh dynamic
catalog entry (refreshed live this session), 2. cached catalog entry
(on-disk snapshot), 3. exact normalized `provider/model` match (for example
`github-copilot/gpt-5.6-sol`, `openai/gpt-5.6-luna`,
`opencode-go/muse-spark-1.3-contributor`), 4. family/substring match
(`gpt-5`, `claude-sonnet`, ...), 5. fallback. Unknown models use the
fallback ($3.00 / $12.00 / $1.50), never zero, and stay visible in the
report. Every dollar figure is labelled `Estimated cost ... (estimate
only; static table, not a bill; subscription use is not an API invoice)`,
and refreshed runs add a `Pricing: <dynamic/cached catalog|static
estimates> (...)` line naming the rate basis (see `docs/PRICING.md`).

Rates are hardcoded static approximations in `Pricing.swift` (one place to
bump them) and drift from provider price lists. Subscription or flat-rate
usage is not an API invoice: Copilot / Luna / Muse Spark contributor
entries reuse the nearest family rate already in the project and are
clearly labeled approximations.

### Dedup and malformed data

- Same `source` + same non-empty `requestId` collapses to the larger
  `totalTokens` (stale mirrors never shadow fresh data); exact ties break to
  the earliest `(timestamp, id)` so repeated loads agree. Order-independent.
  Records without a `requestId` collapse by `source` + `id`: cloned id-less
  snapshot rows (identical stable IDs) count once, distinct id-less rows
  (distinct content hashes) all survive.
- OpenCode identity: per-session rollup IDs are `sessionID#epochSeconds`
  (mirror pairs collapse, different timestamps stay distinct); message IDs
  are shared across the `message` / `session_message` mirror pair. Snapshot
  rollups rejoin the global combine via the `#` heuristic (rollup IDs
  contain `#`, message IDs never do). Message rows win for covered sessions
  across all origins; rollups fill uncovered sessions only.
- `origin` (`local` vs `homeserver`) never changes `source`: OpenCode rows
  from every host keep `source=.opencode` and share the combined OpenCode
  total; `byOrigin` (`source/origin` pairs) shows the split.
- Claude `requestId` prefers the per-message API id (`message.id`), then the
  outer request id; lines without either stay unique via a stable
  root-relative `path:line` id.
- Malformed JSONL lines, unknown types without token fields, bad timestamps,
  and undecodable DB rows are skipped and counted (`LoadReport`), surfaced in
  the dashboard as warnings. Missing files/tables degrade to empty + warning.

## Menu bar dashboard

Dark usage cockpit in the macOS menu bar popover (400pt, macOS 14 SwiftUI, no extra chart dependency).

- **Compact (initial, no scroll):** hero token total for the active source/range, estimated cost (estimate only), `Source` chips (All / Codex / OpenCode / Claude with per-source tokens in range) and `Range` chips (Today / 24H / 7D / 30D / Best / All), a compact visual summary (input/output composition ring with cached/reasoning labelled as subsets, stacked source bar, 14-day mini trend), and a clear `Details` expand action plus a one-line notices/login status footer.
- **Expanded (Details, scrollable):** toggles back to compact via `Show less` in the header. Exposes input/output/cached/reasoning cards (cached reads "subset of input", reasoning "subset of output"), a composition card whose ring splits the total into input vs output only with subset percentages in text, an always-visible source breakdown (zero sources stay listed as `no records`) with a stacked distribution bar, top-5 model bars with share tooltips, the full 14-day trend with date range, sanitized notices, and the launch-at-login toggle.
- Charts are custom SwiftUI (`DashboardCharts.swift`: ring, stacked bar, model bars, daily bars) fed by `DashboardInsights` shares in `TokenBarCore`. Cached and reasoning tokens never render as extra ring slices.
- Preserved in both modes: source/range filtering, refresh button + loading state, empty-range states (with one-tap jumps to All sources / Lifetime), sanitized warnings (never paths), the OpenCode combined total plus local vs homeserver sub-lines when both origins are present, best-month key, last-updated line, and launch-at-login (`SMAppService.mainApp`; disabled dev-run copy under `swift run`).
- Below the dashboard, a pricing footer shows the rate basis (`Pricing: ...` line) with an `Update pricing` button (user-initiated catalog GET, cancellable, offline-safe) and any refresh error. It never blocks usage loading.

## Testing

```sh
swift test            # Mac / any host with Swift 5.9+
python3 scripts/verify_logic.py   # this Linux host (mirrors core semantics + report format)
```

CI (`.github/workflows/ci.yml`, runs on `main` and PRs) mirrors this split:

- macOS 14 job: `swift build` + `swift test` (source of truth).
- Linux job: `PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_logic.py`
  plus shell syntax checks (`bash -n` / `sh -n`) on `scripts/*.sh`.
- Privacy gate: `URLSession` is confined to `Sources/TokenBarCore/PricingService.swift`
  (the single opt-in catalog GET; every other hit fails the gate), catalog
  URL hosts are allowlisted to `openrouter.ai`, and no `Cookie` /
  `Authorization` header is ever set (the gate greps for those). The old
  `No auth, no cookies, no network` comment in `Store.swift` still holds
  for usage loading, which never touches the network.

Covers: Codex valid/alias/nested/type-gate/malformed/epoch/unknown-model,
OpenCode column-form/legacy/JSON-blob/missing-timestamp/no-counts/fallback/
nulls plus per-message nested-tokens/flat-model-IDs/nested-model-object/
role-gate/all-zero-skip/message-beats-rollup/stale-mirror/range-attribution,
multi-origin local/homeserver merge (dual inputs, old-record `local` default,
missing extras warn-only, snapshot schema + `#` rollup heuristic, mirror
selection both orders, tie-break earliest, id-less clone collapse, origin
breakdowns, sanitized extra warnings, no prompt/path leakage),
Claude valid/cache-pair/type-gate/missing-usage/malformed/epoch-ISO/
dedupe/source-isolation/sanitizer, plus filtering (source, today-vs-24h, 7d/30d, inclusive bounds),
best-month max + earliest-tiebreak, totals/sessions/cost/breakdowns,
cached-subset accounting (OpenCode cache fold-in, explicit-total-wins),
dedupe, empty aggregation, plus CLI report
formatting (lifetime totals labels, warning path sanitizing, best-month key,
deterministic JSON, no raw paths in output), plus dynamic pricing
(`PricingCatalogTests`: OpenRouter decode/normalization, catalog-first
precedence incl. suffix match, stale/offline cache behavior, privacy
boundary of the catalog GET, malformed catalog rejection, fixtures under
`Fixtures/pricing-*.json`; no test touches the network).

## Limitations

- Estimates only: the static table drifts from provider lists; the opt-in
  catalog refresh (`Update pricing` / `--refresh-pricing`, OpenRouter
  metadata) narrows the drift for listed models but stays an estimate, and
  subscription-only ids keep static approximations (see `docs/PRICING.md`).
- OpenCode schema drift is handled heuristically; exotic future schemas may
  skip rows (counted, visible).
- Multi-machine merge is offline file copy only: no live sync, no network
  fetch, no HTTP API, no assumed SSH hostname. Snapshot rollups rejoin the
  global combine via the `#` ID heuristic; a message UUID containing `#`
  (not observed) would misclassify. ID-less drift rows hash full column
  content, so the same logical row in `message` vs `session_message` keeps
  two IDs (real tables always carry IDs; drift-only edge).
- Extra DB copies share the single `homeserver` origin label; per-host
  labels need separate snapshots with distinct `origin` values.
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
  When the database is present, per-message tables (`message`,
  `session_message`) attribute usage to the day and model that spent it;
  per-session rollups (`session_v2`, `session`) fill only sessions with no
  message rows, so a session created weeks ago still shows recent usage in
  7d/today views.
- `OpenCode extra database not found (checked TOKENBAR_OPENCODE_DB_EXTRA)` /
  `OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON)`:
  an extra input path is missing. Warnings only; local data still loads.
  Unset the var or fix the path, then re-copy the snapshot yourself.
- `OpenCode snapshot contained extra non-token fields (ignored)`: the
  snapshot file held prompt/path/tool-like keys; they were ignored and only
  token counts loaded. Re-export with `scripts/export-opencode-usage.py`.
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
