# ARCHITECTURE

## Layout

```
Package.swift
Sources/TokenBarCore/   # pure logic, Foundation only (no network, no auth)
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
  Pricing.swift         # static per-1M rates + cost formula
  Aggregator.swift      # filter / aggregate / bestMonth / dailyTrend (pure, clock-injected)
  Store.swift           # orchestrates adapters, env overrides, deterministic dedupe
  Report.swift          # privacy-safe CLI sections: sanitize, human + JSON render (pure)
Sources/TokenBarCLI/    # thin terminal front-end (Foundation only)
  main.swift            # --preset/--source/--all-presets/--json parsing, prints Report
Sources/TokenBarApp/    # SwiftUI + AppKit menu bar shell (macOS 14+)
  TokenBarApp.swift     # @main App, MenuBarExtra, accessory AppDelegate, refresh
  DashboardView.swift   # dark cockpit: source/range chips, hero total,
                        # metric cards, always-visible source rows, models,
                        # trend, empty/notice states (display only)
  LaunchAtLoginController.swift # SMAppService.mainApp wrapper, unbundled fallback
Sources/TokenBarCore/LaunchAtLogin.swift # pure bundled/status policy (tested)
Tests/TokenBarCoreTests/
  CodexParserTests.swift / OpenCodeParserTests.swift / AggregatorTests.swift
  ReportTests.swift     # pure formatter: totals, sanitizer, best-month, JSON determinism
Fixtures/               # synthetic samples only, safe to commit
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
  sums. Resolution is explicit provider-aware: exact normalized
  `provider/model` first, then family/substring, then fallback. Static
  estimate only, never a bill; subscription use is not an API invoice.
  Fallback rate keeps unknown models visible instead of zeroed.
- **File reads only**: adapters use `FileManager` / read-only `sqlite3_open_v2`.
  No `URLSession`, no keychain, no cookies anywhere.
- **Test roots overrideable**: `TOKENBAR_CODEX_ROOT` / `TOKENBAR_OPENCODE_DB`
  / `TOKENBAR_CLAUDE_ROOT` env vars redirect all adapters; tests use temp
  dirs + inline rows. Offline merge adds `TOKENBAR_OPENCODE_DB_EXTRA`
  (extra read-only DBs, origin `homeserver`) and
  `TOKENBAR_OPENCODE_USAGE_JSON` (sanitized snapshots); empty entries are
  ignored and missing extras warn only.
- **SQLite optional**: the live DB loader compiles only under
  `#if canImport(SQLite3)`; `decodeRow` stays pure and fully tested on hosts
  without SQLite (like this Linux worker).
- **App is thin**: all semantics live in `TokenBarCore`; the SwiftUI dashboard
  only renders `AggregatedStats` and forwards refresh. AppKit appears solely
  as the accessory-policy delegate + `MenuBarExtra` host. Launch at login is
  split the same way: pure `LaunchAtLoginPolicy` in Core, thin
  `SMAppService.mainApp` controller in the App target (no entitlements).
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
homeserver db --export-opencode-usage.py (read-only)--> snapshot JSON
  --user-operated file copy--> TOKENBAR_OPENCODE_USAGE_JSON (no network)
```

## Failure model

| Input | Behavior |
|---|---|
| Missing Codex / Claude root / DB file | empty + warning |
| Missing SQLite table | table skipped |
| Malformed line / row | skipped + counted |
| Unknown model | `"unknown"` label, fallback price |
| Future timestamps | excluded by preset upper bound |
| Duplicate requestIds | larger total kept, earliest breaks ties |
| Duplicate id-less IDs | identical IDs collapse, distinct survive |
| Covered rollups (any origin) | dropped, messages win |
