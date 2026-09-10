# Token Bar - Project Plan

Status: draft roadmap. Base: `feat/direct-usage-cli` (PR #2).
Scope: local-only macOS menu-bar usage totals. No accounts, no network, no auth.

## Goals

- Ship a trustworthy local-only totals bar for Codex + OpenCode, then Claude Code.
- Every number reproducible: deterministic parse, filter, aggregate, price.
- Every dollar figure clearly labelled estimate.
- Mac-native install: `.app`, launch at login, signed.
- Full test gate on Mac + mirror gate on Linux.

## Non-goals

- No live sync, multi-machine merge, or cloud dashboard.
- No provider APIs, cookies, keychain reads, or network calls.
- No prompt/message body storage, export, or log upload.
- No auto-updater or paid billing in this phase.
- No Windows/Linux app target (Linux stays logic-verification only).

## Milestones (dependency order)

### M0 - Baseline acceptance, merge direct-usage PR

Merge order: PR #1 (MVP) then PR #2 (direct-usage CLI), or close #1 if #2 already contains it. Keep history linear.

Acceptance:

- `scripts/show-usage.sh --preset lifetime --source all` prints totals, source splits, top models, estimated cost, last updated, sanitized warnings only.
- `--all-presets`, `--preset today|24h|7d|30d|best-month|lifetime`, `--source all|codex|opencode`, `--json` all work per README.
- `python3 scripts/verify_logic.py` passes on Linux.
- No absolute paths, prompt text, or message bodies in terminal or JSON output.
- No `URLSession|http|cookie` hits in `Sources` (rg check).

### M1 - Full XCTest/Xcode validation and CI

Blocker for all later milestones. Linux host has no Swift toolchain; Mac is source of truth.

Acceptance:

- `swift build` + `swift test` green on Mac (Xcode 15+, macOS 14 SDK).
- Existing suites pass: `CodexParserTests`, `OpenCodeParserTests`, `AggregatorTests`, `ReportTests`.
- Add CI (GitHub Actions, macOS 14 runner): build + test on `main` and PRs. Linux job runs `scripts/verify_logic.py`.
- Document Mac vs Linux test split in README. CI badge or checks required before merge.

### M2 - Codex model attribution

Problem: Codex records keep raw model strings; empty becomes `unknown`. Attribution must be stable across schema drift without inventing data.

Acceptance:

- Per-record `model` = first present `model|model_name`, else `unknown`. Never empty downstream.
- Preserve full raw string (including provider prefixes/variant suffixes) for grouping; no silent truncation.
- `byModel` breakdown groups exact strings, sorted tokens desc then key asc.
- Unknown-model counts and fallback pricing visible in report (not zeroed, not hidden).
- Tests: valid, alias, nested `payload.usage`, unknown/empty model, epoch + ISO timestamps.

### M3 - Provider-aware pricing, clear estimate semantics

Current `Pricing.swift` is one substring table + fallback ($3/$12/$1.50). Keep formula, make provider handling explicit.

Acceptance:

- Price resolution order documented: exact `provider/model` match, then substring/family match, then fallback. Case-insensitive.
- Formula unchanged: `(input-cached)*inputRate + cached*cachedRate + output*outputRate`, per 1M, USD. Cached is subset of input (`min(cached,input)`); reasoning rides inside output.
- Every UI/CLI/JSON dollar figure labelled `Estimated cost ... (estimate)`. Pricing header cites static-table drift.
- Add/refresh family entries actually observed (Codex GPT/o-series, Claude, Gemini) with one place to bump rates. Unknown models use fallback, never zero.
- Tests: cached-subset cap, reasoning-not-double-counted, fallback path, explicit-total-wins for token totals.

### M4 - Claude Code support

New third source. Real local shape (Mac-observed, generic default only):

- Root: `~/.claude/projects/**/*.jsonl` (override `TOKENBAR_CLAUDE_ROOT` for tests).
- One JSON object per line. Assistant records carry `message.usage` with `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, plus top-level `model`, `timestamp`, `sessionId`.
- Non-assistant lines (user, system, tool, summary) carry no `message.usage` and are skipped + counted.

Acceptance:

- New `UsageSource.claude` + `SourceFilter` gains `claude` (keep `all`). CLI `--source all|codex|opencode|claude`. Dashboard filter adds Claude.
- Parser: recursive `*.jsonl` walk, read-only. Map `cache_read + cache_creation` into normalized `cachedTokens` (subset of input); `input_tokens` already includes cache, so no fold-in (same rule as Codex, unlike OpenCode). `total = input + output` unless an explicit positive total exists.
- Dedupe: reuse `TokenBarStore.dedupe` (`source:requestId`, earliest `(timestamp,id)` wins). Derive `requestId` from message/request id when present; else stable `file:line` fallback; empty `requestId` stays unique by `id`. Session count from distinct non-empty `sessionId`.
- Privacy: warnings sanitized to generic labels (`TOKENBAR_CLAUDE_ROOT` hint). No paths, prompts, or message bodies in output or JSON.
- Missing root/table degrades to empty + warning, same as Codex/OpenCode.
- Tests + fixtures: synthetic assistant valid, cache pair, missing usage skipped, malformed line counted, epoch/ISO timestamps, dedupe, source-filter isolation. Fixtures under `Fixtures/` only, never real logs.
- Docs: README source table + troubleshooting + semantics updated for Claude.

### M5 - macOS .app packaging, login, signing, install

Acceptance:

- Versioned `.app` bundle built from `TokenBarApp` target (macOS 14+, accessory policy, `MenuBarExtra`).
- Launch at login via `SMAppService` (macOS 13+ API), toggle in UI, graceful fallback when unavailable.
- Signed + notarized build path documented (`Developer ID`, `notarytool`, staple). Unsigned local `swift run` still works for dev.
- Simple install: downloadable `.dmg` or `.zip` with drag-to-Applications, plus one-command dev run (`scripts/run-token-bar.sh`). Checksum or signed artifact noted.
- No new filesystem/network entitlements beyond read-only history + login item.

### M6 - Release checklist, future sources

Acceptance:

- Release checklist checked in: version bump, `swift test` Mac green, `verify_logic.py` green, CLI smoke (`--all-presets`, `--json`), privacy rg check, signed artifact, release notes with estimate disclaimer.
- Future sources tracked, not built: Gemini CLI, Copilot, Cursor, other JSONL/SQLite histories. Each needs: default path, record shape, token-field map, cache semantics, dedupe key, privacy review, fixtures + tests.
- Open follow-up issues per source; close this plan when M0-M5 ship.

## Test strategy

- Mac (truth): `swift build`, `swift test`. Covers parsers, aggregator (presets, bounds inclusive of `now`, best-month earliest-tiebreak, empty agg), pricing, report sanitizer + JSON determinism, store dedupe.
- Linux (mirror): `python3 scripts/verify_logic.py`. Same semantics, no Swift required.
- Fixtures: synthetic only under `Fixtures/`. Never commit real session logs, DBs, or secrets (`*.codex/`, `opencode.db`, `sessions/`, `.env*` stay ignored).
- Privacy gate: `rg -i "URLSession|http|cookie" Sources` empty; CLI/JSON output contains no absolute paths or prompt text (covered by `ReportTests` + manual smoke).
- CI: macOS job (build+test) + Linux job (verify script). Green required to merge.

## Known limitations

- Cost is always an estimate; static table drifts from provider price lists.
- Parser heuristics skip exotic future schemas (counted, visible as warnings).
- No live sync, no multi-machine merge, no export.
- App needs macOS 14+; Linux runs verification only.
- Best-month ties go to earliest month by design.
- Future timestamps excluded by preset upper bound (`now`).

## Next worker tasks (exact, in order)

1. `gh pr diff 2` review + `python3 scripts/verify_logic.py`; record pass/fail in PR #2.
2. Decide PR #1 vs #2 merge order; merge baseline into `main` (keep `feat/direct-usage-cli` history intact).
3. On Mac: `swift build && swift test`; paste results into PR or issue. Fix failures before M2.
4. Add CI workflow (macOS `swift test` + Linux `verify_logic.py`); open PR, require green checks.
5. Implement M2 (Codex attribution hardening) + tests; open PR against `main`.
6. Implement M3 (provider-aware pricing table + estimate labels) + tests; open PR.
7. Implement M4 Claude parser (`UsageSource.claude`, `TOKENBAR_CLAUDE_ROOT`, CLI `--source claude`, dashboard filter, fixtures, docs); open PR.
8. Implement M5 packaging (bundle, `SMAppService` login toggle, signing/notarization doc, `.dmg`/`.zip` path); verify on clean Mac profile.
9. Cut M6 release: run full checklist, tag, attach signed artifact, file future-source issues.
