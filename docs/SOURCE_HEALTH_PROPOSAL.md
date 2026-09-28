# Source Health and Coverage Proposal

Scope: docs/planning-only candidate. It changes no source, tests, CI,
VERSION, CHANGELOG, packaging, website behavior, or release artifacts.
Any implementation lands only under a later worker milestone (PLAN.md
M13) with synthetic fixtures, tests, and docs. No release version is
assigned. Docs-only changes here do not bump `VERSION`.

Normative sources: `AGENTS.md` scope and UI behavior, `README.md`
dashboard and data sources, `docs/SECURITY_AND_VISUAL_QA.md` gates,
`Models.swift` (`UsageSource`, `SourceFilter`,
`AggregatedStats.lastUpdated`, `LoadReport`), `Report.swift`,
`Store.swift`, `DashboardSnapshot.swift`, `Aggregator.swift`, and
`OpenCodeSync.swift`. It proposes only what is absent today.

## 1. User problem

A zero or low total is ambiguous: genuinely no usage in range, a
source input missing or unreadable, or the remote OpenCode snapshot
never synced or stale. The dashboard answers "how much" per source
and range, not "is each source covered" in one place. Troubleshooting
means widening ranges, switching source chips, reading notices, and
opening Settings for the sync status. This proposal adds a
compact-first, read-only readout naming per-source coverage for the
current scope, with remote sync freshness kept separate from usage
recency.

## 2. Existing behavior and gap

Kept unchanged: compact popover (400pt, no scroll) with hero total,
cost, chips, comparison bars, source bar, mini trend, Details action,
and updated/notices footer; scrollable expanded Details with metric
cards, composition card, source rows (OpenCode local/remote sub-lines
when both origins exist), top-5 models, full trend, sanitized
notices, Show less; `AggregatedStats.lastUpdated` as max in-scope
record timestamp; OpenCode combined total with `By origin` only when
more than one distinct origin exists; sync and pricing state in
Settings only; startup last-report banner; no background collection.

Warning pipeline (honest): `TokenBarStore.load` places raw per-input
warnings in `LoadReport` (including absolute paths for missing
defaults); `ReportFormatter` sanitizes them before rendering, and
`StartupReportCache` sanitizes them before persistence. CLI and JSON
carry generic labels only.

Gap: no per-source row separating "last observed usage" from
"current-range totals"; no uniform zero/missing/stale/error labels
(coverage stays implicit in warnings); OpenCode local vs remote
health split across token sub-lines and Settings; no compact coverage
hint. This proposal adds that readout only, with no change to token
math, pricing, trends, filters, sync pull, or pricing refresh.

## 3. Scope and non-goals

In scope: one read-only health card in expanded Details plus at most
a one-line compact footer hint, from the current load pass plus
existing caches, sanitized labels only.

Non-goals: no new network, subprocess, telemetry, prompt/message
storage, provider integration, or persistent usage data. No
per-model, per-bucket, per-file, duration, or rate metrics. No
repair, retry, rescan, or re-pull buttons in the dashboard; Sync Now
and pricing refresh stay in Settings. No settings in the dashboard,
no dashboard filters in Settings. No compact composition ring, no
comparison, source-bar, trend-grain, or comparison-math changes, no
per-source series, stacked areas, or heatmap. No new CLI flags, no
JSON change beyond the existing warnings block. No cloud dashboard,
provider auth, prompt storage, auto-updater, or Windows/Linux target.

## 4. Data semantics (honest)

- `LoadReport` carries records, skipped counters, and warnings only:
  no per-input scan timestamps, no coverage metadata.
  `StartupReportCache.savedAt` is one report timestamp only. No new
  persistent health data is proposed, and no per-input "last
  successful scan" timestamps or per-source scan freshness is
  promised.
- `DashboardSnapshot` today carries stats, scoped counts, chip
  totals, trend buckets, and comparison. It does not already carry
  warning counts, per-source timestamps, or preset bounds.
  Implementation derives per-source history dates from the
  already-loaded `NormalizedUsage` set, with at most one additional
  linear in-memory pass, and threads the new values through
  `DashboardSnapshot`. No file or history I/O is added.
- Range-scoped source health is derived after source and date
  filtering, in the Aggregator and `DashboardSnapshot` layer, not in
  `TokenBarStore.load`, which stays file-reads-only.
- Cross-source diagnostics: the health card always shows Codex,
  OpenCode, and Claude rows regardless of the selected source chip.
  The selected date range still scopes each row's current-range
  contribution. Last-observed timestamps are lifetime maxima over
  all already-loaded records, independent of source and range
  selection (per source; OpenCode further split per origin row in
  section 7). Current-range counts and tokens follow the
  dashboard's temporal preset over the loaded records (Today is the
  calendar day, 24H/7D/30D are rolling windows, lifetime is
  unfiltered). For Best, the contribution window is
  `DashboardSnapshot.bestMonthKey`: the winning month selected
  under the current source filter, with per-source rows showing
  each source's contribution in that month (a nil key means zero
  contributions). "Last seen 6 days ago, 0 tokens in this range"
  is valid.
- The history span is the observed parsed records only, never proof
  that source logs are complete. Underivable states show the label
  with no timestamp, never a fabricated value.
- Coverage state is a pure function of the current `LoadReport`
  sanitized warnings plus in-scope and lifetime record sets, per
  the section 5 decision table. No per-file times or cross-run
  history are used.

## 5. Coverage states, decision table, and sync freshness

Sync freshness comes only from the existing `OpenCodeSyncStatus`
(`lastSuccessAt`, `lastAttemptAt`, sanitized `lastError`) with the
configured interval and timeout. No new sync metadata is proposed.
It attaches to the generic remote-input group only (section 7),
never to a custom origin label.

- "Never synced": sync enabled and `lastSuccessAt` is nil. Distinct
  state, never classified as stale.
- "Stale": a prior success exists and `lastSuccessAt` is older than
  interval plus timeout.
- A later failed pull with retained last-good cache is a distinct
  sanitized error ("last good pull kept") reusing the existing
  `sanitizedError` strings. Raw errors never reach the dashboard.
- Sync disabled with no cache: the remote diagnostic stays silent
  as today and never blocks local rows. No host, path, command,
  interval, or path-bearing error detail appears in the dashboard.

Decision table (testable): implementation matches only the
allow-listed sanitized warning categories below, after
`ReportFormatter.sanitizeWarnings`. Raw `Store.load` strings with
absolute paths are never matched, and arbitrary warning prose
never alters health state. Each row names the affected group:
`Codex`, `OpenCode local`, `Remote inputs` (generic diagnostic,
section 7), or `Claude`. Skipped-row counters are provider-level
(section 5 precedence).

| Sanitized warning category | Affected group | Issue class |
|---|---|---|
| `Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT).` | Codex | missing |
| `Claude sessions not found (checked default location or TOKENBAR_CLAUDE_ROOT).` | Claude | missing |
| `OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB).` | OpenCode local | missing |
| `OpenCode database unreadable; others still load.` | OpenCode local | unreadable |
| `OpenCode database present but SQLite module unavailable in this build.` | OpenCode local | unreadable |
| `OpenCode extra database not found (checked TOKENBAR_OPENCODE_DB_EXTRA).` | Remote inputs | missing |
| `OpenCode extra database skipped: SQLite module unavailable in this build.` | Remote inputs | unreadable |
| `OpenCode extra database unreadable; others still load.` | Remote inputs | unreadable |
| `OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON).` | Remote inputs | missing |
| `OpenCode snapshot unreadable; others still load.` | Remote inputs | unreadable |
| `OpenCode remote sync cache unreadable; others still load.` | Remote inputs | unreadable |
| `OpenCode snapshot contained extra non-token fields (ignored).` | none (notice only) | none |
| `<N> Codex line(s) skipped as malformed or non-usage.` (`N` > 0) | Codex | skipped-partial |
| `<N> OpenCode row(s) skipped as undecodable.` (`N` > 0) | OpenCode provider | skipped-partial |
| `<N> Claude line(s) skipped as malformed or non-usage.` (`N` > 0) | Claude | skipped-partial |
| Any other (unknown) sanitized string | none (notice only) | none |

States per group (`Remote inputs` included):

- `covered`: at least one current-range record and no mapped
  missing/unreadable issue for the group, and the provider
  skipped counter is zero.
- `zero in range`: zero current-range records but at least one
  lifetime record for the group, with no mapped issue and a zero
  provider skipped counter.
- `missing`: a mapped missing-class warning for the group and
  zero usable lifetime records for the group.
- `unreadable`: a mapped unreadable-class warning for the group
  and zero usable lifetime records for the group. With no usable
  records, unreadable takes precedence over missing.
- `partial`: at least one usable lifetime record for the group
  plus any mapped missing/unreadable issue for the group; or a
  nonzero provider skipped counter (Codex/Claude for their group;
  OpenCode at provider level). Missing/unreadable issues coexisting
  with usable records always classify as partial, never as
  missing/unreadable.
- `no-usage-observed`: zero lifetime records for the group and no
  mapped issue (and a zero provider skipped counter). The label
  must not claim source presence or completeness.

Precedence and attribution rules:

- OpenCode local default-DB issues map only to the local group.
  Extra-DB, snapshot, and sync-cache issues map only to the
  generic `Remote inputs` group; implementation never guesses
  which custom label failed.
- The OpenCode skipped-row count is provider-level partial only:
  it degrades otherwise-covered/zero OpenCode origin rows to
  partial without naming an origin as the cause, and when
  OpenCode has no origin rows it surfaces at provider level only.
  It is never assigned to a single origin.
- Unknown warnings stay as sanitized notices and never alter any
  group state.
- The compact hint triggers on `missing`, `unreadable`, or
  `partial` in any displayed group, plus enabled-sync
  never-synced/stale/failed-kept-cache states. It counts unique
  providers needing attention (Codex, OpenCode, Claude; local and
  remote-input issues count once under OpenCode) and stays one
  line.

## 6. UI placement

- The health card appears only where expanded Details is reachable.
  The empty-store screen (no records from any source) and the
  no-scope screen (zero records in scope) keep their existing UI and
  notices unchanged, with no health card.
- Compact stays 400pt with no scroll, controls, setup prose, or
  settings. Its only change is the footer line: when any displayed
  source needs attention (`missing`, `unreadable`, `partial`, or
  enabled-sync never-synced/stale/failed-kept-cache per section 5),
  it may add one short hint (for example `2 sources need attention -
  see Details`); when covered, current text stays. The hint counts
  unique providers needing attention across all displayed sources,
  independent of the selected source chip. The hint is omitted via
  a plain parent `if` when empty, so no blank strip renders.
- Details holds a `Source health` card in the scroll content after
  source rows and before top-5 models, collapsing with Show less.
  Row scope is cross-source diagnostics: fixed provider order
  (Codex, OpenCode, Claude) regardless of the selected source chip;
  the selected range still scopes each row's current-range
  contribution. Codex and Claude render one row each. OpenCode
  renders one sub-row per exact sanitized origin label observed in
  the loaded records (section 7); when OpenCode has no loaded
  records it renders a single `local` placeholder row in
  `no-usage-observed` without claiming presence. The generic
  `Remote inputs` diagnostic row appears additionally when any
  remote-input warning maps to it or sync is enabled, and carries
  sync freshness per section 5. Each row shows state label, last
  observed usage (lifetime maxima, independent of selection;
  omitted when the group has no lifetime records), and
  current-range contribution (records plus tokens; Best uses the
  `bestMonthKey` month). Only the generic remote-input row adds
  sync freshness.
- No Settings controls move. At most one plain `Open Settings`
  action label, no inline host, path, command, or interval fields.
- CLI: no new flags; any addition reuses the sanitized warnings
  block only.

## 7. OpenCode origin naming

Health aggregates OpenCode rows by exact sanitized origin label as
observed in the loaded `NormalizedUsage` records: `local`, the
default `remote`, and each distinct custom label render as separate
rows and are never merged into one remote bucket. Origin labels
use only `OpenCodeStore.sanitizeOriginLabel` values (short
`[A-Za-z0-9_.-]` form, 64-character cap, else the generic `remote`
fallback). Custom labels follow the existing rule (first explicitly
distinct embedded label wins, blank/default falls back, legacy
`homeserver` loads). Honest about today: extra DB copies load with
the shared origin `remote` by design, while hand-copied snapshots
and the sync cache keep their embedded sanitized origin or the
`remote` fallback, so health never reattributes an extra-DB row to
a host. A missing/unreadable remote input without an attributable
origin appears only as the generic `Remote inputs` diagnostic row,
never under a guessed custom label. Sync freshness attaches to
that generic group only and is never presented as belonging to a
custom origin. Health names the OpenCode origin explicitly even for
a sole origin, although the token `By origin` breakdown omits
single-origin rows. Contract criteria for the new card and hint
slots land in `scripts/test-popover.sh` in the implementation PR.

## 8. Privacy and security

Health strings use aggregated counts, source/origin labels,
timestamps, and the sanitized warning set only. Usage data, prompts,
message bodies, paths, credentials, cookies, and subscription
sessions never leave the machine. Env var names are public config;
values, environments, and file contents are never printed,
committed, or pasted. `PricingService.swift` stays the only network
file; `OpenCodeSync.swift` stays the only subprocess file (system
ssh/scp, argv arrays, never a shell, `BatchMode=yes`). No new
network or subprocess calls. Evidence uses synthetic `Fixtures/`
only; `./scripts/check-privacy.sh` must pass plus human prose
review.

## 9. Acceptance and tests (implementation PR)

- Core derives per-source health (label, last observed usage,
  range contribution) after filtering from the in-memory scope,
  OpenCode split by exact sanitized origin label, as pure functions
  with explicit `now` and `Calendar`. Last-observed values are
  lifetime maxima independent of source/range selection; range
  contributions follow the preset, with Best using the
  `bestMonthKey` month under the current source filter. Rows render
  cross-source regardless of the selected source chip.
- Decision table per section 5: each allow-listed sanitized
  category maps to its group; states cover `covered`,
  `zero in range`, `missing`, `unreadable`, `partial`, and
  `no-usage-observed` with the stated precedence (partial with
  usable records; unreadable over missing with none; skipped
  counters as provider-level partial never assigned to an origin;
  unknown strings as notices only; sanitized-only matching).
- Sync states per section 5: never-synced only when
  `lastSuccessAt` is nil, stale only after a prior success older
  than interval plus timeout, failed-kept-cache as distinct
  sanitized error; never-synced is never stale. Freshness renders
  only on the generic remote-input row, never under a custom
  origin.
- Compact shows at most the one-line hint, counted at provider
  level across all displayed sources independent of the source
  chip, omitted when covered, with no scroll, controls, clipping,
  or empty strip. Empty-store and no-scope screens are unchanged
  with no health card.
- Details shows the card in position with cross-source rows plus
  OpenCode per-origin sub-rows and the conditional generic
  `Remote inputs` row, sanitized labels, named sole origins,
  unmerged distinct custom labels, no settings fields. No token,
  cost, trend, filter, sync, or pricing changes;
  `URLSession`/`Process(`/host-allowlist/Cookie rules unchanged.
- Fixtures (synthetic, small, under `Fixtures/` only): Codex
  in-range/out-of-range, Claude skipped lines, OpenCode local plus
  default remote plus two distinct custom labels plus legacy,
  missing/unreadable inputs per decision-table category, one
  unknown warning string, overlong/unsafe origin labels,
  never-synced/stale/failed-kept-cache statuses. Never real data
  or credentials.
- Tests: last-observed maxima vs range totals including Best
  `bestMonthKey` contributions, decision-table matrix with
  precedence and provider-level skipped handling, sanitizer
  coverage including the 64-character limit, snapshot threading
  with no extra scans, empty/no-scope paths; mirror pure logic in
  `verify_logic.py` where mirrored; extend `test-popover.sh`. Mac
  `swift build` plus `swift test`, Linux mirror, shell syntax,
  `check-privacy.sh`, `git diff --check`, and touched contract
  scripts green. Gaps stated as gaps.

## 10. Liquid Glass QA

Gate: `docs/SECURITY_AND_VISUAL_QA.md` sections 3 to 5, Mac render
pass from synthetic fixtures only: compact and expanded in light
and dark across empty store, zero scoped count, no-comparison
ranges (Best, All), long notices, stale-cache and loading banner,
plus each new health state once. Per state: labels present, focus
order with visible ring, no clipping, wrapping, or compact
horizontal overflow; Details scrolls vertically only. Reduce
Transparency and Increase Contrast rendered explicitly; unrendered
is a gap, not a pass. Glass boundary unchanged: glass on functional
controls only (header icon actions, source/range chips, Details and
collapse actions); health rows, labels, cards, charts, and text
never sit inside custom glass. No new material, second background,
popover-scale fixed height, or size-changing animation. Merge gate:
exact-head verification, independent review, green CI,
`git diff --check` clean, extended `test-popover.sh` green.

(End of proposal - candidate only, no version assigned.)
