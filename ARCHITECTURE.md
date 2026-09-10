# ARCHITECTURE

## Layout

```
Package.swift
Sources/TokenBarCore/   # pure logic, Foundation only (no network, no auth)
  Models.swift          # UsageSource, SourceFilter, DatePreset, NormalizedUsage,
                        # AggregatedStats, BreakdownEntry, DailyBucket, BestMonth, LoadReport
  CodexParser.swift     # recursive *.jsonl reader, tolerant line decoder
  ClaudeParser.swift    # recursive *.jsonl reader for ~/.claude/projects
  OpenCodeStore.swift   # pure decodeRow + optional SQLite loader (read-only)
  Pricing.swift         # static per-1M rates + cost formula
  Aggregator.swift      # filter / aggregate / bestMonth / dailyTrend (pure, clock-injected)
  Store.swift           # orchestrates adapters, env overrides, deterministic dedupe
  Report.swift          # privacy-safe CLI sections: sanitize, human + JSON render (pure)
Sources/TokenBarCLI/    # thin terminal front-end (Foundation only)
  main.swift            # --preset/--source/--all-presets/--json parsing, prints Report
Sources/TokenBarApp/    # SwiftUI + AppKit menu bar shell (macOS 14+)
  TokenBarApp.swift     # @main App, MenuBarExtra, accessory AppDelegate, refresh
  DashboardView.swift   # filters, presets, stats, breakdowns, trend, empty states
Tests/TokenBarCoreTests/
  CodexParserTests.swift / OpenCodeParserTests.swift / AggregatorTests.swift
  ReportTests.swift     # pure formatter: totals, sanitizer, best-month, JSON determinism
Fixtures/               # synthetic samples only, safe to commit
scripts/verify_logic.py # host-side mirror of core semantics (no Swift here)
scripts/show-usage.sh   # one-command CLI wrapper: swift run TokenBarCLI "$@"
scripts/run-token-bar.sh # one-command menu bar launcher: swift run TokenBarApp
```

## Design decisions

- **Isolated adapters**: Codex (JSONL walk), Claude Code (JSONL walk), and
  OpenCode (SQLite read) never share code except the `NormalizedUsage`
  struct. Each degrades independently.
- **Normalized records**: every event becomes one `NormalizedUsage` with
  clamped non-negative counts and `total` derived deterministically.
  OpenCode folds `tokens_cache_read`/`tokens_cache_write` into normalized
  input (the schema stores them separately); Codex input already includes
  cached input, and Claude Code `message.usage.input_tokens` already
  includes cached input, so cached stays a subset of input on all three
  sources.
- **Deterministic aggregation**: explicit `now` + `Calendar` inputs, stable
  `(timestamp, id)` sort, documented tie-breaks (earliest month, key asc).
- **Pricing separated**: `Pricing.swift` owns all money math; aggregation only
  sums. Fallback rate keeps unknown models visible instead of zeroed.
- **File reads only**: adapters use `FileManager` / read-only `sqlite3_open_v2`.
  No `URLSession`, no keychain, no cookies anywhere.
- **Test roots overrideable**: `TOKENBAR_CODEX_ROOT` / `TOKENBAR_OPENCODE_DB`
  / `TOKENBAR_CLAUDE_ROOT` env vars redirect all adapters; tests use temp
  dirs + inline rows.
- **SQLite optional**: the live DB loader compiles only under
  `#if canImport(SQLite3)`; `decodeRow` stays pure and fully tested on hosts
  without SQLite (like this Linux worker).
- **App is thin**: all semantics live in `TokenBarCore`; the SwiftUI dashboard
  only renders `AggregatedStats` and forwards refresh. AppKit appears solely
  as the accessory-policy delegate + `MenuBarExtra` host.
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
files/db --CodexParser/ClaudeParser/OpenCodeStore--> [NormalizedUsage]
  --TokenBarStore.dedupe--> LoadReport --Aggregator.filter--> scoped
  --Aggregator.aggregate / .bestMonth--> AggregatedStats --> DashboardView
  --ReportFormatter.section/render--> TokenBarCLI terminal report
```

## Failure model

| Input | Behavior |
|---|---|
| Missing Codex / Claude root / DB file | empty + warning |
| Missing SQLite table | table skipped |
| Malformed line / row | skipped + counted |
| Unknown model | `"unknown"` label, fallback price |
| Future timestamps | excluded by preset upper bound |
| Duplicate requestIds | earliest kept |
