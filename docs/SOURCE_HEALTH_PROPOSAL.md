# Source Health and Coverage Proposal

Scope: docs/planning-only. This document is a candidate proposal for a
Source Health and Coverage readout in Token Bar. It changes no source,
tests, CI, VERSION, CHANGELOG, packaging, website behavior, or release
artifacts. Any implementation lands only under a later worker milestone
(PLAN.md M13) with synthetic fixtures, tests, and docs. This proposal is
explicitly a candidate with no release version assigned. Docs-only
changes here do not bump `VERSION` and do not create a release.

Normative product sources this proposal builds on: `AGENTS.md` current
scope and UI behavior, `README.md` dashboard and data-source sections,
`docs/SECURITY_AND_VISUAL_QA.md` merge and release gates,
`Sources/TokenBarCore/Models.swift` (`UsageSource`, `SourceFilter`,
`AggregatedStats.lastUpdated`, `LoadReport`), `Report.swift`
(sanitizer plus render), `Store.swift` (file-only load plus warnings),
`DashboardSnapshot.swift` (single render input), and `OpenCodeSync.swift`
(opt-in pull plus last-good cache). It proposes only what is absent
today; it does not restate or duplicate shipped behavior as new work.

## 1. User problem

A user who sees a zero or a low total cannot tell which of these is
true: there is genuinely no usage in the selected range, one source is
missing or unreadable, or the remote OpenCode snapshot is stale or has
never synced. The current dashboard answers "how much" per source and
range, but it does not answer "is each source covered by this scan" in
one place. Troubleshooting today means widening ranges, switching
source chips, reading the notices list, and opening Settings for the
one-line sync status. That path works but it spreads the health answer
across three surfaces.

This proposal adds a compact-first, read-only health readout that names
per-source coverage for the current scan: which sources contributed
records, which inputs were missing or unreadable, and for OpenCode
whether local rows, remote rows, or both are present, with remote
freshness separated from remote usage recency.

## 2. Existing behavior and gap

Existing behavior (kept unchanged):

- Compact popover (400pt, no scroll): hero total, estimated cost,
  Source chips (All/Codex/OpenCode/Claude), Range chips
  (Today/24H/7D/30D/Best/All), paired input/output bars with exact
  counts, stacked source bar, adaptive mini trend with comparison,
  Details action, and an updated/notices footer.
- Expanded Details (scrollable): metric cards, composition card with
  input-vs-output ring, always-visible source rows with OpenCode
  local/remote sub-lines when both origins are present, top-5 models,
  full adaptive trend with grain caption and comparison, full
  sanitized notices, Show less to collapse.
- `AggregatedStats.lastUpdated` is the max record timestamp in scope
  (last observed usage), shown as the "last updated" line in CLI and
  the updated/notices footer in the app.
- `LoadReport.warnings` carries sanitized per-input notices (missing
  root or DB, unreadable input, skipped-line counts, extra non-token
  fields, sync-cache fallback lines). `ReportFormatter` sanitizes
  paths to generic labels before render.
- OpenCode merge shows a combined OpenCode total plus local vs remote
  sub-lines when both origins are present, and CLI prints a `By
  origin` section only when more than one distinct origin is present.
- Remote sync state lives in Settings only (enable toggle, host and
  path or command fields, optional origin label, interval, Sync Now,
  one-line status). Pricing state lives in Settings only. Startup
  shows the last normalized report with a `Showing previous data -
  updating...` banner while the background scan runs.
- Counts, date ranges, and sanitized notices are derived from current
  scans and caches only. There is no background usage collection and
  no per-input telemetry store.

Gap (the only scope of this proposal):

- There is no per-source health row that separates "last observed
  usage in this source" from "last successful scan or sync covering
  this source". A single `lastUpdated` timestamp mixes the two.
- There is no per-source zero/missing/stale/error label set with
  uniform wording. Missing inputs warn, but coverage (which sources
  were scanned, which were skipped, which contributed zero rows) is
  implicit.
- OpenCode local vs remote health is visible only as token sub-lines
  and the Settings sync status. There is no single OpenCode health
  block that separates local DB coverage, extra DB and snapshot
  coverage, and sync-cache freshness.
- There is no compact health hint that stays within the compact-first
  contract. The footer names notices but does not summarize coverage.

This proposal adds that readout and nothing else. It does not change
token math, pricing, trend buckets, chart styles, filters, sync pull
behavior, or pricing refresh behavior.

## 3. Compact versus expanded UI placement

Compact-first contract (from `AGENTS.md` and
`docs/SECURITY_AND_VISUAL_QA.md` section 4):

- Compact stays 400pt, no scroll, no new controls, no new setup
  prose, no settings surface. Compact keeps the existing hero total,
  cost line, chips, comparison bars, source bar, mini trend,
  Details action, and updated/notices footer.
- Compact health change is limited to the existing footer line: when
  one or more sources in the current scan are uncovered (missing,
  unreadable, or stale as defined in section 4), the footer may add
  one short sanitized hint (for example `2 sources need attention -
  see Details`). When all scanned sources are covered, the footer
  keeps its current text with no added row. No per-source list, no
  timestamps, and no sync controls appear in compact.
- No conditional slot renders an empty strip: the hint row is
  omitted from the hierarchy with a plain parent `if` when there is
  nothing to report, per the section 4 empty-slot contract.

Expanded Details placement:

- A `Source health` card lives inside the expanded Details scroll
  content, after the source breakdown rows and before the top-5
  models. It scrolls with Details and never grows the compact
  popover. It toggles with Details and collapses with Show less.
- The card lists one row per source in fixed order
  (Codex, OpenCode, Claude), plus OpenCode local/remote sub-lines
  inside the OpenCode row. Each row shows the coverage state label
  from section 6, the last observed usage for that source in plain
  relative or date form, and the last successful scan or sync
  covering that source, kept as two separate fields per section 4.
- No Settings controls move into the dashboard. Launch-at-login,
  pricing refresh, and remote sync configuration stay in Settings
  behind the gear button. The health card links to Settings with at
  most one plain action label (for example `Open Settings`) and no
  inline host, path, command, or interval fields.
- CLI parity stays thin: no new flags. If the implementation adds
  anything to terminal output, it reuses the existing sanitized
  warnings block only; no per-source health table is promised for
  CLI in this candidate.

## 4. Freshness and coverage semantics

Two timestamps are tracked separately and displayed separately. Both
are derived from the current scan pass and existing caches. No new
usage persistence and no background collection are introduced.

- Last observed usage per source: the max record timestamp among
  in-scope records for that source after filter, dedupe, and merge,
  or empty when the source contributed zero records to the current
  scan. For OpenCode, local and remote maxima are tracked
  separately (`opencode/local`, `opencode/remote` or the effective
  custom origin label). Codex and Claude rows always carry origin
  `local`. This value answers "when did this source last spend
  tokens that this scan can see".
- Last successful scan or sync per source: the completion marker of
  the load pass that covered that input, or empty when the input was
  never successfully read on this machine. For file inputs (Codex
  root, OpenCode DB, Claude root, extra DB copies, hand-copied
  snapshots) this is the load-pass completion time for that input.
  For the sync cache this is the last validated pull time from the
  existing sync status record, with last-good-cache fallback text
  when the latest pull failed. This value answers "when did Token
  Bar last confirm coverage", independent of usage recency.
- Coverage state per source is a pure function of the current
  `LoadReport` plus the two values above:
  `covered` (input read, rows contributed),
  `zero in range` (input read, zero rows in the selected preset),
  `missing` (default input absent),
  `unreadable` (present but undecodable),
  `stale` (sync cache present but older than the configured sync
  interval plus timeout, or local-only when sync is enabled but has
  never succeeded).
- Counts and date ranges shown in the health card are the same
  values the current snapshot already carries (scoped request
  counts, preset bounds with `now` inclusive upper bound, sanitized
  warning counts). The health readout performs no extra history
  scans: it renders stored snapshot values only, in one linear pass
  over the in-memory scope, matching the `DashboardSnapshot` cost
  model (same in-memory scope as the hero total, stored values only
  for charts).
- No metric is promised that would need unsupported
  instrumentation: no per-file modification times in the UI, no
  parse-duration figures, no record-ingestion rates, no cross-run
  history, and no per-model freshness. If a value cannot be derived
  from the current scan plus existing caches, the row shows the
  sanitized state label with no timestamp rather than an estimate.

## 5. Per-source and OpenCode local/remote information

- Codex row: state label plus last observed Codex usage plus last
  successful Codex scan. Missing root and unreadable-root cases reuse
  the existing sanitized warning strings; the health row adds no
  path.
- Claude row: same shape as Codex (state label, last observed
  Claude usage, last successful Claude scan) with the existing
  sanitized Claude warning strings.
- OpenCode row: state label plus two sub-lines. The `local` sub-line
  names local DB coverage (read plus row contribution, or
  missing/unreadable). The `remote` sub-line names merged remote
  coverage across extra DB copies, hand-copied snapshots, and the
  sync cache, with the effective origin label shown only when it is
  an allowlisted short label (existing `[A-Za-z0-9_.-]` rule, else
  the generic `remote` label). When only one OpenCode origin is
  present, the row shows that origin explicitly instead of hiding
  it, because health (unlike the token `By origin` section) must
  name the covered side.
- Sync freshness appears only as the remote sub-line timestamp plus
  the existing sanitized sync status text (for example last good
  pull kept after a failed attempt). No host alias, remote path,
  remote command, interval value, or error detail with paths is
  shown in the dashboard. Full sync configuration stays in
  Settings.
- Custom origin labels follow the existing snapshot rule: the first
  explicitly distinct embedded label wins, blank or default values
  fall back to the effective label, and legacy `homeserver` labels
  keep loading. The health card never invents a per-host split for
  extra DB copies, which share the single `remote` origin by design.

## 6. Sanitized zero, missing, stale, and error states

All strings are generic labels. No absolute paths, no hostnames, no
usernames, no prompt or message text, no file contents, no
credentials.

- `Covered`: input read and rows present in scope. Shows both
  timestamps when available.
- `No records in this range`: input read, zero rows in the selected
  preset. Names the wider-range hint already used by empty states
  (30D from Today/24H/7D, lifetime from 30D/Best) with no new copy.
- `Source not found`: default input absent. Reuses the existing
  sanitized warning (for example `Codex sessions not found (checked
  default location or TOKENBAR_CODEX_ROOT).`).
- `Source unreadable`: present but undecodable. Reuses the existing
  sanitized warning (for example `OpenCode database unreadable;
  others still load.`).
- `Remote data stale`: sync enabled, cache older than interval plus
  timeout, or last pull failed with last good cache kept. Shows the
  last validated pull time and the kept-cache note. Never shows the
  raw sync error.
- `Remote never synced`: sync enabled but no validated pull yet.
  Points to Settings with one plain action label.
- `Sync disabled`: sync cache absent because sync was never enabled.
  Silent in compact; one neutral line in Details with no setup
  prose. Missing sync cache stays silent as today and never blocks
  local rows.
- Empty store (no records from any source): the health card shows
  three `Source not found` or `No records in this range` rows as
  applicable, plus the existing empty-range guidance. No new empty
  artwork and no new copy beyond the state labels.

## 7. Source-core data flow (if implementation proceeds)

- All semantics live in `TokenBarCore`. The app and CLI stay thin
  renderers. A later implementation adds a small pure value type
  (for example a per-source health struct derived during
  `TokenBarStore.load` plus `Aggregator` scoping) and threads it
  through `DashboardSnapshot` the same way trend buckets and the
  comparison are threaded today: same in-memory scope, stored values
  only, no extra file scans.
- `PricingService.swift` remains the only file allowed to touch the
  network. `OpenCodeSync.swift` remains the only file allowed to
  spawn a subprocess (system ssh/scp, argv arrays, never a shell,
  `BatchMode=yes`). This proposal adds no network call, no
  subprocess call, no new executable path, and no change to sync or
  pricing behavior.
- Adapters keep opening files read-only. Missing inputs degrade to
  empty plus a sanitized warning. Sync keeps validate-before-replace
  with temp-then-atomic write, size cap, and last-good-cache
  fallback. The health readout reads those outcomes; it does not
  change them.
- No new persistent usage data. Health values are derived per load
  pass from the current records, warnings, and existing cache and
  status files. No new history file, no new usage cache, and no
  cross-run usage store are introduced. A persisted carrier, if any,
  holds only the same sanitized shape already cached by
  `StartupReportCache` (counts, labels, counters, warnings), never
  prompts, message bodies, tool I/O, paths, or credentials.
- CLI stays offline by default. Sync and pricing triggers remain
  strictly opt-in (`--sync-now`, `--refresh-pricing`, Settings
  actions). Health display never triggers a pull or a catalog GET.

## 8. Privacy boundary

- Usage data, prompts, message bodies, paths, credentials, cookies,
  and subscription sessions never leave the machine. All health
  strings are built from aggregated counts, source and origin
  labels, timestamps, and the existing sanitized warning set.
- Env var names (`TOKENBAR_*`) are public config; values, process
  environments, and file contents are never printed, committed, or
  pasted. Health evidence uses synthetic paths and neutral
  placeholders only.
- Real-data screenshots stay local and uncommitted. Public artifacts
  are built from synthetic fixtures under `Fixtures/` only.
  `./scripts/check-privacy.sh` must pass, with human review for
  prose the guard cannot judge.

## 9. Accessibility

- Every health row, state label, and timestamp exposes a VoiceOver
  label. No image-only status content: state is text first, with any
  status dot marked decorative and hidden from the accessibility
  tree.
- Full keyboard focus order reaches the Details action, the health
  card content, and the collapse action with a visible focus ring.
  The optional `Open Settings` action is a real button with a label.
- Reduce Transparency skips custom glass on health surfaces (opaque
  fallback). Increase Contrast strengthens strokes and keeps state
  text legible. No status meaning is carried by color alone; the
  state label text always names the state.
- Text scales with Dynamic Type without clipping or horizontal
  overflow in compact, and Details scrolls vertically only.

## 10. Non-goals

- No new network, subprocess, telemetry, prompt or message storage,
  provider integration, or persistent usage data.
- No per-model health, no per-bucket health, no per-file health, no
  parse-duration or ingestion-rate metrics.
- No automatic repair, retry, rescan, or re-pull buttons in the
  dashboard. Sync Now and pricing refresh stay in Settings only.
- No settings surface in the dashboard and no dashboard filters in
  Settings.
- No composition ring in compact, no change to the log-scaled
  input/output comparison, no change to the source bar, no change to
  trend grains or comparison math, no per-source trend series, no
  stacked areas, no heatmap.
- No new CLI flags and no change to JSON determinism beyond the
  existing warnings block.
- No cloud dashboard, provider auth, prompt storage, auto-updater,
  or Windows/Linux app target.

## 11. Acceptance criteria (for the later M13 implementation PR)

- `TokenBarCore` carries per-source health (state label, last
  observed usage, last successful scan or sync) derived from the
  current load pass plus existing caches, with OpenCode local and
  remote tracked separately. Pure functions with explicit `now` and
  `Calendar`, matching the `TrendModel` test style.
- Compact renders at most the one-line footer hint, omitted when
  all sources are covered, with no scroll, no new controls, no
  clipping, and no empty strip.
- Expanded Details shows the `Source health` card in the specified
  position with three source rows plus OpenCode sub-lines, two
  separate timestamps per row, sanitized state labels only, and no
  settings fields.
- Zero, missing, stale, and error states render per section 6 with
  generic labels only. A state that cannot be derived shows the
  label with no timestamp, never a fabricated value.
- No token, cost, trend, filter, sync, or pricing behavior changes.
  `URLSession` stays confined to `PricingService.swift`; `Process(`
  stays confined to `OpenCodeSync.swift`; catalog hosts stay
  allowlisted to `openrouter.ai`; no Cookie or Authorization
  headers.
- Mac `swift build` plus `swift test` green; Linux
  `verify_logic.py` mirror green where health logic is mirrored;
  shell syntax, `check-privacy.sh`, `git diff --check`, and the
  contract scripts touched by the change green.
- Visual QA per section 12 recorded with gaps stated as gaps.

## 12. Synthetic fixtures and tests (for the later M13 implementation PR)

- Fixtures under `Fixtures/` only, synthetic and small: Codex JSONL
  with in-range and out-of-range records, Claude JSONL with cache
  pairs and skipped lines, OpenCode snapshot JSON with local and
  remote origins (including blank, default, custom allowlisted, and
  legacy labels), an unreadable-input case, a missing-input case,
  and a stale-cache status case. Never real logs, DBs, snapshots,
  or credentials.
- Core tests (Mac source of truth): per-source last-observed maxima,
  scan versus usage separation, OpenCode local/remote split,
  zero-in-range versus missing versus unreadable versus stale
  versus never-synced versus disabled, sanitizer coverage for every
  new string, snapshot threading with no extra scans, and empty
  scope behavior. Mirror the pure logic in `verify_logic.py`.
- Contract tests: extend `scripts/test-popover.sh` in the same PR
  for the new Details card slot and the compact footer hint slot
  (presence guards, no empty strip, no scroll ownership change, no
  glass placement change).

## 13. Required Liquid Glass visual QA

Normative gate: `docs/SECURITY_AND_VISUAL_QA.md` sections 3 to 5.
The M13 implementation PR must record a Mac render pass built from
synthetic fixtures only (never real usage data, never committed
screenshots of real data):

- Compact and expanded popover in light and dark appearances across
  empty store, zero scoped count, no-comparison ranges (Best month,
  All time), long notice lists, stale-cache and loading banner
  states, plus each new health state in section 6 at least once.
- Checks per state: accessibility labels present, keyboard focus
  order with visible focus ring, no clipped text, no wrapped
  controls, no horizontal overflow in compact, expanded scrolls
  vertically only.
- Reduce Transparency and Increase Contrast states rendered
  explicitly. A state that was not rendered is a gap, not a pass.
- Glass boundary unchanged: glass applies only to functional
  controls (header icon actions, source and range chip rows,
  primary Details and collapse actions). Health rows, timestamps,
  state labels, cards, charts, and explanatory text never sit
  inside custom glass. No new material, no second background, no
  popover-scale fixed height, no size-changing animation.
- Merge gate: exact-head verification, independent review, green PR
  CI (macOS `swift build` plus `swift test`, Linux mirror plus
  shell syntax, privacy gate plus `check-privacy.sh`),
  `git diff --check` clean, and the extended `test-popover.sh`
  green.

(End of proposal - candidate only, no version assigned.)
