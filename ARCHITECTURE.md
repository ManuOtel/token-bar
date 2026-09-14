# ARCHITECTURE

## Layout

```
Package.swift
Sources/TokenBarCore/   # pure logic, Foundation only (no auth; network
                        # only via the two opt-in paths: pricing GET, sync SSH pull)
  Models.swift          # UsageSource, SourceFilter, DatePreset, NormalizedUsage
                        # (+ origin host label, old rows default local),
                        # AggregatedStats (+ byOrigin source/origin pairs),
                        # BreakdownEntry, DailyBucket, BestMonth, LoadReport
  CodexParser.swift     # recursive *.jsonl reader, tolerant line decoder
  ClaudeParser.swift    # recursive *.jsonl reader for ~/.claude/projects
  OpenCodeStore.swift   # pure decodeRow (rollups) + decodeMessageRow
                        # (per-message) + message-beats-rollup combine;
                        # optional SQLite loader (read-only) + sanitized
                        # snapshot loader (token counts only)
  Pricing.swift         # static per-1M rates + cost formula + catalog-aware
                        # resolve (dynamic/cached catalog first, then exact/
                        # family static, then fallback) with PriceOrigin labels
  PricingCatalog.swift  # PriceOrigin, pluggable normalized catalog format,
                        # OpenRouter GET decoder, strict cache codec, freshness
   PricingService.swift  # ONLY network in the codebase: one bounded,
                         # cancellable, user-initiated catalog GET + disk cache
   OpenCodeSync.swift    # ONLY subprocess in the codebase: opt-in SSH/scp
                         # snapshot pull (system executable, argv arrays, no
                         # shell, BatchMode=yes) + config/status/cache files;
                         # validate-before-replace, atomic cache write,
                         # last-good-cache fallback (pure + tested)
   Aggregator.swift      # filter / aggregate / bestMonth / dailyTrend (pure, clock-injected)
   Store.swift           # orchestrates adapters, env overrides, deterministic dedupe
                         # (file reads only; the sync pull runs before load,
                         # never inside it; sync cache loads as one more
                         # snapshot, same combine/dedupe, origin homeserver)
  StartupReportCache.swift # privacy-safe startup envelope (versioned LoadReport
                         # + sanitized warnings, atomic Application Support
                         # write) + StartupRefreshState generation guard
  Report.swift          # privacy-safe CLI sections: sanitize, human + JSON render (pure)
Sources/TokenBarCLI/    # thin terminal front-end (Foundation only)
  main.swift            # --preset/--source/--all-presets/--json/--refresh-pricing/--sync-now
                        # parsing, prints Report (offline static by default;
                        # --sync-now pulls first, failures only add a warning)
Sources/TokenBarApp/    # SwiftUI + AppKit menu bar shell (macOS 14+)
  TokenBarApp.swift     # @main App, MenuBarExtra, accessory AppDelegate, refresh
                        # + settings surface (header gear opens SettingsView;
                        # launch-at-login + pricing + homeserver sync live
                        # there, never in the dashboard footer); startup,
                        # periodic, and Sync Now run sync-then-load off-main
  OpenCodeSyncController.swift # @MainActor-publishing ObservableObject over
                        # OpenCodeSyncService: config edit/save, cancellable
                        # pull, 60s poll ticker honoring the saved interval,
                        # one-line sanitized status; usage reload stays the
                        # app's job so sync never blocks the popover
  PricingController.swift # @MainActor ObservableObject over PricingService:
                        # offline cache at startup, cancellable Task refresh,
                        # usage loading never blocks on pricing
  DashboardView.swift   # dark cockpit: header with refresh + settings gear,
                        # source/range chips, hero total, metric cards,
                        # always-visible source rows, models, trend,
                        # empty/notice states (display only); Settings gear
                        # opens the SettingsView popover
  SettingsView.swift    # secondary settings surface (~300pt popover):
                        # launch-at-login toggle + pricing refresh group
                        # (status line, user-initiated refresh, error) +
                        # homeserver sync group (enable toggle, host alias,
                        # remote path/command, interval stepper, Sync Now,
                        # status line, error); usage filters/details stay
                        # in DashboardView
  LaunchAtLoginController.swift # SMAppService.mainApp wrapper, unbundled fallback
Sources/TokenBarCore/LaunchAtLogin.swift # pure bundled/status policy (tested)
Tests/TokenBarCoreTests/
  CodexParserTests.swift / OpenCodeParserTests.swift / AggregatorTests.swift
  ReportTests.swift     # pure formatter: totals, sanitizer, best-month, JSON determinism
  PricingCatalogTests.swift # OpenRouter decode, precedence, stale/offline,
                        # privacy boundary, malformed catalogs (fixtures only)
Fixtures/               # synthetic samples only, safe to commit
  pricing-openrouter-sample.json # OpenRouter GET shape + broken rows (skipped)
  pricing-cache-sample.json      # persisted cache v1 (2 entries)
  pricing-malformed-sample.json  # wrong version + negative rate (rejected)
scripts/verify_logic.py # host-side mirror of core semantics (no Swift here)
scripts/export-opencode-usage.py # read-only homeserver exporter: SQLite
                        # mode=ro to sanitized token-only JSON (user copies
                        # the file; no network, no HTTP API)
scripts/show-usage.sh   # one-command CLI wrapper: swift run TokenBarCLI "$@"
scripts/run-token-bar.sh # one-command menu bar launcher: swift run TokenBarApp
scripts/build-app.sh     # versioned TokenBar.app bundle into dist/ (Info.plist, LSUIElement)
scripts/package-release.sh # zip/DMG + .sha256 (sign + staple before packaging)
docs/MACOS_PACKAGING.md  # signing, notarytool, install, uninstall, login items
```

## Design decisions

- **Isolated adapters**: Codex (JSONL walk), Claude Code (JSONL walk), and
  OpenCode (SQLite read) never share code except the `NormalizedUsage`
  struct. Each degrades independently.
- **Two OpenCode granularities, never double counted**: per-message rows
  (`message`, `session_message`) win where they exist (accurate day/model
  attribution); per-session rollups (`session_v2`, `session`) fill only
  sessions with zero message rows. Stale rollup mirrors lose to the larger
  total; message mirrors share stable message IDs so existing dedupe
  collapses them.
- **Normalized records**: every event becomes one `NormalizedUsage` with
  clamped non-negative counts and `total` derived deterministically, plus an
  `origin` host label (`local` default; `homeserver` for extra DB copies and
  snapshots missing the key). `source` stays `.opencode` on every host; only
  `byOrigin` (`source/origin` pairs) splits the combined total.
  Codex resolves models per file (line-local `model|model_name` wins, else
  latest `turn_context` for the same `turn_id`, else a single-model
  `thread_id` fallback, else `"unknown"`; ambiguous threads never guess).
  OpenCode folds `tokens_cache_read`/`tokens_cache_write` into normalized
  input (the schema stores them separately); Claude Code folds
  `cache_read_input_tokens`/`cache_creation_input_tokens` into normalized
  input the same way (Anthropic semantics sum all three input components).
  Codex input already includes cached input, so no fold there. Cached
  stays a subset of input on all three sources.
- **Deterministic aggregation**: explicit `now` + `Calendar` inputs, stable
  `(timestamp, id)` sort, documented tie-breaks (earliest month, key asc).
- **Pricing separated**: `Pricing.swift` owns all money math; aggregation only
  sums. Resolution is explicit provider-aware: fresh dynamic catalog entry,
  then cached catalog entry, then exact normalized `provider/model`, then
  family/substring, then fallback. Every rate carries a `PriceOrigin`
  (`dynamicCatalog | cachedCatalog | staticEstimate | fallback`) surfaced in
  the Settings pricing status line and CLI `Pricing:` line. Static estimate only, never a
  bill; subscription use is not an API invoice.
  Fallback rate keeps unknown models visible instead of zeroed.
- **Two bounded opt-in network uses, nothing else**: `PricingService` owns
  the one catalog GET (public model/pricing metadata, default OpenRouter
  `/api/v1/models`, 15s timeout, 5MB cap, cancellable `Task`, user-initiated
  only); `OpenCodeSync` owns the homeserver snapshot pull (system
  `ssh`/`scp` via `Process` argv arrays, never a shell, `BatchMode=yes` so
  no password prompt, per-attempt timeout default 60s, 32MB snapshot cap,
  cancellable `Task`, disabled by default). Neither sends prompts, token
  counts, paths, credentials, cookies, or usage records. Everything else is
  file reads only.
- **Sync pulls before the load, never inside it**: `OpenCodeSyncService`
  fetches, validates (`OpenCodeSync.validateSnapshotData`: JSON array with
  at least one decodable opencode record, or empty), and atomically
  replaces the local cache (temp file + `replaceItemAt` swap, no
  remove-then-move gap; readers never see halves). A valid empty `[]`
  honestly replaces the cache with zero rows (remote has no usage); only
  malformed or all-skipped payloads preserve the last good cache. Any
  failure (invalid config, timeout, unreachable host, invalid payload,
  cancellation) preserves the last good cache and surfaces one sanitized
  generic message. Trust split: the snapshot-path pull executes nothing
  remote, while the exporter command runs through the remote sshd shell --
  trusted user-supplied read-only invocation only; local argv safety does
  not sanitize remote execution. `TokenBarStore.load` then reads that cache as one more
  snapshot input with the shared combine/dedupe, so synced rows land with
  `origin=homeserver`, `source=.opencode` and aggregation semantics are
  byte-identical to the manual-copy path.
- **File reads only**: adapters use `FileManager` / read-only `sqlite3_open_v2`.
  No keychain, no cookies anywhere. `URLSession` appears only in
  `PricingService.swift` (confined, CI-pinned); `Process(` appears only in
  `OpenCodeSync.swift` (confined, CI-pinned: no shell, discrete argv).
- **Test roots overrideable**: `TOKENBAR_CODEX_ROOT` / `TOKENBAR_OPENCODE_DB`
  / `TOKENBAR_CLAUDE_ROOT` env vars redirect all adapters; tests use temp
  dirs + inline rows. Merge adds `TOKENBAR_OPENCODE_DB_EXTRA`
  (extra read-only DBs, origin `homeserver`),
  `TOKENBAR_OPENCODE_USAGE_JSON` (sanitized snapshots), and
  `TOKENBAR_OPENCODE_SYNC_CACHE` (the auto-synced cache; default
  `Application Support/TokenBar/opencode-homeserver.json`, silent when
  absent); sync config/status file locations redirect via
  `TOKENBAR_OPENCODE_SYNC_CONFIG` / `TOKENBAR_OPENCODE_SYNC_STATUS`.
  Empty entries are ignored and missing extras warn only.
- **SQLite optional**: the live DB loader compiles only under
  `#if canImport(SQLite3)`; `decodeRow` stays pure and fully tested on hosts
  without SQLite (like this Linux worker).
- **App is thin**: all semantics live in `TokenBarCore`; the SwiftUI dashboard
  only renders `AggregatedStats` and forwards refresh. AppKit appears solely
  as the accessory-policy delegate + `MenuBarExtra` host. Launch at login is
  split the same way: pure `LaunchAtLoginPolicy` in Core, thin
  `SMAppService.mainApp` controller in the App target (no entitlements).
  Settings surface: the dashboard header gear opens `SettingsView` (launch
  at login + pricing refresh + homeserver sync); usage filters and details stay in
  `DashboardView`, so the main popover never carries a pricing footer.
- **CLI is thin**: `TokenBarCLI/main.swift` only parses
  `--preset/--source/--all-presets/--json`, calls `TokenBarStore.load`, then
  `ReportFormatter.section/render/encodeJSON`. All formatting lives in pure
  `Report.swift` so it is unit-testable without touching the filesystem.
- **Privacy by construction**: `ReportFormatter` sanitizes every warning to
  generic location labels (`TOKENBAR_CODEX_ROOT` / `TOKENBAR_OPENCODE_DB` /
  `TOKENBAR_CLAUDE_ROOT` hints). No absolute paths, prompt text, or message
  bodies ever reach terminal output or JSON.

## Data flow

```
files/db/snapshots --CodexParser/ClaudeParser/OpenCodeStore--> [NormalizedUsage]
  --OpenCodeStore.combineMessageAndRollup (global across local + extras +
    snapshots; messages win, rollups fill uncovered only)
  --TokenBarStore.dedupe (max-total wins, earliest tiebreak, id-less by id)
  --> LoadReport --Aggregator.filter--> scoped
  --Aggregator.aggregate / .bestMonth--> AggregatedStats (+ byOrigin)
  --> DashboardView (combined OpenCode row + local/homeserver sub-lines)
  --ReportFormatter.section/render--> TokenBarCLI terminal report
    (+ By origin when >1 origin; JSON carries byOrigin)
  catalog GET --PricingService.refresh (user-initiated only)--> cache file
    --snapshot--> Aggregator/Report cost basis (offline static when absent)
  homeserver db --export-opencode-usage.py (read-only)--> snapshot JSON
    --manual copy--> TOKENBAR_OPENCODE_USAGE_JSON (no network), or
    --OpenCodeSyncService (opt-in ssh/scp pull, validated, atomic)-->
      opencode-homeserver.json sync cache (last-good preserved on failure)
    --TokenBarStore.load (file reads only)--> same combine/dedupe as manual
```

## Failure model

| Input | Behavior |
|---|---|
| Missing Codex / Claude root / DB file | empty + warning |
| Missing SQLite table | table skipped |
| Malformed line / row | skipped + counted |
| Unknown model | `"unknown"` label, fallback price |
| Pricing refresh fails / offline | cached catalog when present, else static estimates; usage loading unaffected |
| Sync disabled / never ran | sync cache absent, silent; local data only, unchanged |
| Sync pull fails / times out / cancelled | last good cache preserved; one sanitized message; usage loading unaffected |
| Remote snapshot invalid (HTML, truncated, all-skipped) | cache NOT replaced; last good preserved; sanitized message |
| Sync config invalid / disabled at CLI `--sync-now` | no subprocess spawned; sanitized line added to report; local load continues |
| Malformed pricing payload / cache | ignored with an offline message, previous rates kept |
| Future timestamps | excluded by preset upper bound |
| Duplicate requestIds | larger total kept, earliest breaks ties |
| Duplicate id-less IDs | identical IDs collapse, distinct survive |
| Covered rollups (any origin) | dropped, messages win |
