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

- No cloud dashboard. Multi-machine merge has two paths: the opt-in SSH
  snapshot pull (`OpenCodeSync`, disabled by default, user's own SSH setup)
  and the offline file-copy merge (extra DBs + sanitized snapshots), both
  rejoining the same combine/dedupe with no network inside usage loading.
- No provider APIs, cookies, keychain reads, or other network calls.
- No prompt/message body storage, export, or log upload. The remote
  exporter emits token counts, timestamps, model labels, and session /
  message IDs only, and the sync pull downloads that snapshot only.
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

- Price resolution order documented: exact normalized `provider/model` match (trimmed + lowercased), then substring/family match, then fallback. Case-insensitive. Exact entries: `github-copilot/gpt-5.6-sol`, `openai/gpt-5.6-luna` (GPT-5 family approximations), `opencode-go/muse-spark-1.3-contributor` (Claude Sonnet family approximation). Static estimates only, never a billing claim; subscription use is not an API invoice.
- Formula unchanged: `(input-cached)*inputRate + cached*cachedRate + output*outputRate`, per 1M, USD. Cached is subset of input (`min(cached,input)`); reasoning rides inside output.
- Every UI/CLI/JSON dollar figure labelled `Estimated cost ... (estimate only; static table, not a bill; subscription use is not an API invoice)`. Pricing header cites static-table drift.
- Add/refresh family entries actually observed (Codex GPT/o-series, Claude, Gemini) with one place to bump rates. Unknown models use fallback, never zero.
- Tests: cached-subset cap, reasoning-not-double-counted, fallback path, explicit-total-wins for token totals.

### M4 - Claude Code support

New third source. Real local shape (Mac-observed, generic default only):

- Root: `~/.claude/projects/**/*.jsonl` (override `TOKENBAR_CLAUDE_ROOT` for tests).
- One JSON object per line. Assistant records carry `message.usage` with `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, plus top-level `model`, `timestamp`, `sessionId`.
- Non-assistant lines (user, system, tool, summary) carry no `message.usage` and are skipped + counted.

Acceptance:

- New `UsageSource.claude` + `SourceFilter` gains `claude` (keep `all`). CLI `--source all|codex|opencode|claude`. Dashboard filter adds Claude.
- Parser: recursive `*.jsonl` walk, read-only. Raw `input_tokens` excludes
  the cache counters, so normalized `input = input_tokens + cache_read +
  cache_creation` (fold-in, same rule as OpenCode); Codex is the exception
  where `payload.usage` input already includes cached input and needs no
  fold. Normalized `cached = cache_read + cache_creation` (subset of
  input); `total = normalized input + output` unless an explicit positive
  total exists.
- Dedupe: reuse `TokenBarStore.dedupe` (`source:requestId`, earliest `(timestamp,id)` wins). Derive `requestId` from message/request id when present; else stable root-relative `path:line` fallback; empty `requestId` stays unique by `id`. Session count from distinct non-empty `sessionId`.
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

- Release checklist checked in (`RELEASE_CHECKLIST.md` is the gate): version bump, `swift test` Mac green, `verify_logic.py` green, CLI smoke (`--all-presets`, `--json`), privacy rg check, signed artifact, release notes with estimate disclaimer.
- Future sources tracked, not built: Gemini CLI, Copilot, Cursor, other JSONL/SQLite histories. Each needs: default path, record shape, token-field map, cache semantics, dedupe key, privacy review, fixtures + tests.
- Open follow-up issues per source; close this plan when M0-M5 ship.

### M7 - Compact/detail dashboard with subset-safe charts (next)

Status: in progress on `feat/compact-detail-dashboard`. This milestone covers
both the compact/detail dashboard and dynamic pricing (opt-in OpenRouter
catalog with offline static fallback; see `docs/PRICING.md`).

Acceptance:

- Compact initial popover (400pt, no scroll): hero token total, estimated cost + req/sess line, source/range chips, composition ring + stacked source bar + mini 14-day trend, a `Details` expand action, and a one-line notices/login-status footer. No clipped or wrapped controls.
- Expanded Details mode: toggles back via `Show less`; exposes metric cards, composition card, always-visible source rows with OpenCode local/remote sub-lines, top-5 model bars, full 14-day trend with date range, full sanitized notices, and the launch-at-login toggle. Existing filters, refresh, empty states, warnings, origin split, and login behavior all preserved.
- Charts (`DashboardCharts.swift` on SwiftUI/macOS 14 only, shares from `DashboardInsights`): ring splits the total into input vs output only; cached reads "subset of input" and reasoning "subset of output" in legend + caption; source/model bars show percent-of-total shares; trend bars scale to the peak bucket with tooltips and accessibility labels.
- Tests: `DashboardInsightsTests` covers empty scope (zero shares, no NaN), input/output split + subset ratios, share normalization/order, trend peak scaling, and top-model limits. No screenshot tests. `PricingCatalogTests` covers OpenRouter decode/normalization, catalog-first precedence, stale/offline cache behavior, the privacy boundary of the catalog GET, and malformed catalogs (fixtures only, no network). `swift build` + `swift test` green on Mac; existing pricing tests keep passing with the static offline path unchanged.
- Performance slice 1 shipped on `perf/catalog-lookup` (see `docs/PERFORMANCE.md`): immutable catalog lookup built once per `Aggregator.aggregate` call; identical pricing precedence and offline behavior, no parser/merge/UI/total changes.

## Test strategy

- Mac (truth): `swift build`, `swift test`. Covers parsers, aggregator (presets, bounds inclusive of `now`, best-month earliest-tiebreak, empty agg), pricing, report sanitizer + JSON determinism, store dedupe.
- Linux (mirror): `python3 scripts/verify_logic.py`. Same semantics, no Swift required.
- Fixtures: synthetic only under `Fixtures/`. Never commit real session logs, DBs, or secrets (`*.codex/`, `opencode.db`, `sessions/`, `.env*` stay ignored).
- Privacy gate: `rg -i "URLSession|http|cookie" Sources` empty; CLI/JSON output contains no absolute paths or prompt text (covered by `ReportTests` + manual smoke).
- CI: macOS job (build+test) + Linux job (verify script). Green required to merge.

## Known limitations

- Cost is always an estimate; static table drifts from provider price lists.
- Parser heuristics skip exotic future schemas (counted, visible as warnings).
- Multi-machine merge: manual copy is offline file copy only (no HTTP API);
  auto-sync is an opt-in SSH pull over the user's own SSH setup (no guessed
  hosts, no stored credentials). `7D` is record-timestamp based; lifetime
  can be nonzero when recent data lives on another host.
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

### M8 - Remote auto-sync (opt-in SSH pull)

Status: shipped on `feat/opencode-homeserver-sync` (historic branch name;
product terminology since generalized to remote host). Keeps the manual-copy
path intact and adds the smallest complete pull design on top.

Acceptance:

- `OpenCodeSync` service + config in `TokenBarCore`: non-secret SSH host
  alias, remote snapshot path (or remote exporter invocation), optional
  origin label, local cache
  path, poll interval (default 15 min, 5 min-24 h), timeout (default 60 s,
  5-300 s). System ssh/scp via `Process` argument arrays only, never a
  shell; `BatchMode=yes` always; no credential fields exist. Ships
  disabled with blank host/path.
- Exporter stays token-only and read-only; the pull prefers a
  pre-generated sanitized snapshot, validates JSON before replacement
  (array with at least one decodable opencode record, or empty; 32 MB
  cap), writes temp-then-atomic, and preserves the last good cache on any
  error (timeout, unreachable, invalid payload, cancellation) with one
  sanitized message.
- App startup, periodic background sync, and Sync Now run sync-then-load
  off-main without blocking the popover; local data and
  aggregation/dedupe unchanged; synced rows keep their embedded origin
  (`remote` when omitted; legacy `homeserver` still loads),
  source `opencode`. CLI gains `--sync-now` (failures only add a warning).
- Settings carries the compact sync surface (toggle, host/path/command,
  optional origin label,
  interval, Sync Now, one-line status); the dashboard gains no setup prose.
- Tests: `OpenCodeSyncTests` (config validation, safe argv, cache
  validation/atomic replacement, failure fallback incl. sanitized errors,
  refresh integration proving a synced recent row lands in 24 h) plus
  `verify_logic.py` mirror; fixtures synthetic under `Fixtures/`. No real
  server access. `swift build` + `swift test` green on Mac.

### M9 - Adaptive trend with previous-period comparison

Status: in progress on `feat/adaptive-trend-comparison`. Replaces the
hard-coded LAST 14 DAYS chart (which rendered only non-empty daily buckets
from the selected stats, so Today showed one bar) with an adaptive trend
covering the selected range plus a small previous-period comparison.

Acceptance:

- `TrendModel` in `TokenBarCore` (pure, explicit `now` + `Calendar`):
  Today buckets by hour from the local calendar-day start through the
  current hour; Last 24H uses 24 rolling hourly buckets; Last 7D / Last
  30D use daily buckets over the selected range; Best month uses daily
  buckets for the winning month; Lifetime uses monthly buckets. Every
  range returns full zero-filled coverage (empty hours/days/months read
  as gaps). Each bucket carries a stable start, a short label, an exact
  token count, and a request count; totals sum `totalTokens` only, never
  cached/reasoning on top. Documented filtering math is unchanged:
  display buckets are calendar-aligned while the selected record
  predicate stays the existing rolling predicate, so rolling-window edge
  days may be partial by design.
- `DashboardSnapshot` threads the adaptive trend plus comparison with no
  extra file scans (same in-memory scope as the hero total, two linear
  passes); chart views render stored values only. Titles name the range
  and grain: TODAY BY HOUR, LAST 24H BY HOUR, LAST 7D BY DAY,
  LAST 30D BY DAY, BEST MONTH BY DAY, ALL TIME BY MONTH. The compact
  chart fits the 400pt popover (adaptive bar sizing, bounded horizontal
  scroll only for long lifetimes); Details stays readable with a grain
  caption.
- Comparison for chronological ranges only (Today vs yesterday, 24H vs
  the preceding rolling 24H, 7D/30D vs the preceding window; Best and
  Lifetime omit it): same source filter, local/offline, total tokens
  plus requests. Empty baseline reads "No prior-period data" with no
  direction and no percent, never a fabricated 0 percent; exact current
  totals are unchanged.
- Tests: `TrendModelTests` (all grains, zero-filled coverage, local
  calendar behavior, rolling 24H bounds, up/down/flat/no-baseline
  deltas, source filtering, lifetime monthly aggregation, snapshot
  threading) plus a `verify_logic.py` mirror; no screenshot tests.
  `swift build` + `swift test` green on Mac; existing filtering, token,
  and cost semantics unchanged.

### M10 - Release hardening and visual-regression gate

Status: process-only. Defines the gates that prevent a repeat of the
PR #65 popover bare-material strip regression. Normative detail lives
in `docs/SECURITY_AND_VISUAL_QA.md`; this milestone tracks adoption.

Acceptance:

- `docs/SECURITY_AND_VISUAL_QA.md` is the merge and release gate for
  popover, Settings, sync, pricing, and release-doc changes: threat
  model and privacy boundary, worker evidence rules (synthetic
  fixtures for public artifacts, real-data screenshots local only,
  never dump process environments), section 3 visual matrix, section
  4 geometry/material contracts, section 5 merge/release gates,
  section 6 incident response, section 7 security checks.
- Popover PRs extend `scripts/test-popover.sh` in the same PR when
  they touch structure, conditional slots, heights, scroll ownership,
  materials, or glass placement, and record a Mac render pass over
  compact/expanded, light/dark, empty/zero/no-comparison, notices,
  accessibility, focus, and clipping states.
- `docs/RELEASE_PROCESS.md` and `RELEASE_CHECKLIST.md` reference and
  enforce the gate (render evidence plus release-candidate
  install/version/one-process smoke). Existing release semantics
  unchanged: docs-only changes do not bump `VERSION` or create a
  release.
- Checks: `verify_logic.py`, `bash -n`/`sh -n`, `check-privacy.sh`,
  `git diff --check`, plus the contract scripts
  (`test-popover.sh`, `test-versioning.sh`, `test-release.sh`,
  `test-site.sh`); on a Mac, `swift build` + `swift test` remain the
  source of truth.

### M11 - Future Settings-initiated auto-update (plan only)

Status: plan only; do not implement in this milestone. The Non-goals
entry on auto-updater stands until a dedicated proposal with fixtures,
tests, and docs is accepted. When that proposal is written, it must
require all of:

- User initiation from Settings only (ships disabled or explicit
  opt-in; never silent background install without consent).
- HTTPS public release metadata only (no arbitrary URLs, no shell
  commands, no unsigned channels).
- Signed/notarized or equivalent artifact verification before any
  replacement; failed verification aborts with no change.
- Safe atomic replacement with rollback to the previous versioned
  artifact; never silently overwrite a published or installed asset.
- Current/latest version display plus release notes with the estimate
  disclaimer before the user confirms.
- Cancel/retry/error states that leave the running app intact.
- Settings preservation across update (sync config, pricing cache,
  login-item state); no settings reset.
- No credentials, prompts, message bodies, paths, or usage data
  leaving the machine during the check or install.
- Evaluation of Sparkle or another maintained signed updater before
  any custom mechanism; prefer the maintained option unless the
  proposal documents why it cannot fit the sandbox and signing path.

Acceptance for this milestone is the accepted written plan only: no
source, CI, packaging, or site-behavior change lands under M11.

### M12 - Configurable chart styles implementation release

Status: implementation milestone. The written proposal is accepted
(`docs/CHART_STYLE_PROPOSAL.md`); this milestone tracks the
implementation feature PR plus its review, CI, and visual gates and
the eventual minor-version release step. M11 stays intact and
unchanged.

Scope: implement the accepted proposal only: Automatic (default),
Bars, Line with points, and Area over the existing adaptive
`TrendModel` and `DashboardSnapshot`, with the Chart style menu in
expanded Details, a persisted preference, compact kept compact,
per-range visual rules, zero-filled buckets, linear trend scale with
the existing log-scaled input/output comparison preserved
separately, source bar and model rows unchanged, comparison
annotations, tooltips, keyboard and focus behavior, VoiceOver labels
with Audio Graph support where the platform provides it, Reduce
Transparency and Increase Contrast handling, render from snapshot
only with no extra scans, and privacy and fixture-only evidence
rules. A calendar heatmap stays explicitly out of scope. Area is
total-volume shape only, never stacked multi-source content.

Acceptance:

- Feature PR delivers the style menu, the three renderers plus
  Automatic with the section 4 mapping from
  `docs/CHART_STYLE_PROPOSAL.md`, persistence with Automatic
  fallback, accessibility labels with Audio Graph support where the
  platform provides it, the privacy evidence rules, and the proposal
  section 12 tests (renderer selection, accessibility labels, empty
  and no-baseline states, persistence, bucket coverage, visual
  geometry contracts), staying inside the proposal boundaries (shared trend
  model, view-layer renderer selection, stable color and series
  semantics, no decorative animation, no extra glass or material
  surface, macOS 14 availability, no new network use, no new
  subprocess, no new usage persistence).
- Review, CI, and visual gates before merge: independent review;
  exact-head verification (reviewed SHA is the SHA CI ran and the
  SHA merged); green PR CI per `docs/RELEASE_PROCESS.md` step 5
  (macOS 14 `swift build` + `swift test`, Linux `verify_logic.py`
  mirror plus shell syntax, privacy gate with `URLSession` confined
  to `PricingService.swift`, `Process(` confined to
  `OpenCodeSync.swift`, catalog hosts allowlisted to
  `openrouter.ai`, no Cookie/Authorization headers, plus
  `scripts/check-privacy.sh`); contract scripts
  (`scripts/test-popover.sh` extended in the same PR where the
  popover contract requires it, plus `test-versioning.sh`,
  `test-release.sh`, `test-site.sh` as touched) and
  `git diff --check` clean; Mac render pass over the
  `docs/SECURITY_AND_VISUAL_QA.md` section 3 matrix (compact and
  expanded, light and dark, empty, zero, no-comparison, notices,
  Reduce Transparency, Increase Contrast, accessibility, focus,
  clipping), built from synthetic fixtures under `Fixtures/` only
  with privacy-safe handling (no real-data screenshots, no
  environment dumps, no real paths). A state that was not rendered
  is a gap, not a pass.
- Eventual minor-version release step after the feature PR merges:
  release PR bumps `VERSION` plus `CHANGELOG.md` only (no product
  or process changes), then the maintainer tags `main` HEAD as
  exactly `v<VERSION>` and the tag workflow publishes the release,
  followed by published-asset verification and a verified install
  with the release-candidate visual smoke per
  `docs/SECURITY_AND_VISUAL_QA.md` section 5. Feature PRs and
  release PRs stay separate per `docs/RELEASE_PROCESS.md`. The
  release mapping lives in `docs/RELEASE_ROADMAP.md`: v0.5.1
  baseline; next minor release for M12 charts plus Liquid Glass
  visual QA; following candidate for the Settings-initiated updater
  (`docs/AUTO_UPDATE_PROPOSAL.md`) only after its security and
  signing requirements are met.

Non-goals:

- No per-source or per-model trend series, no stacked areas, no
  heatmap, no per-range style memory, no log-scaled trend axis, no
  new network use, no new subprocess, no new usage persistence.
- No real-data screenshots in public artifacts; synthetic fixtures
  only.
- No updater work lands under M12; updater planning lives in M11
  plus `docs/AUTO_UPDATE_PROPOSAL.md` and stays a candidate until
  the signing and notarization infrastructure exists.

Release recommendation: the planning edits under this milestone are
docs-only (no VERSION bump, no CHANGELOG entry, no release
artifact). The M12 implementation ships only through the feature PR
above, then follows the normal version and release path.
