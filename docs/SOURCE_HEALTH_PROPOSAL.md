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
- Each row separates last observed usage (max record timestamp per
  source over loaded records; OpenCode split into local and remote)
  from the current-range contribution (records and tokens in the
  preset). "Last seen 6 days ago, 0 tokens in this range" is valid.
- The history span is the observed parsed records only, never proof
  that source logs are complete. Underivable states show the label
  with no timestamp, never a fabricated value.
- Coverage state is a pure function of current `LoadReport`
  warnings plus in-scope record sets: `covered`, `zero in range`,
  `missing`, `unreadable`, plus section 5 sync states. No
  per-file times or cross-run history are used.

## 5. Remote sync freshness

Freshness comes only from the existing `OpenCodeSyncStatus`
(`lastSuccessAt`, `lastAttemptAt`, sanitized `lastError`) with the
configured interval and timeout. No new sync metadata is proposed.

- "Never synced": sync enabled and `lastSuccessAt` is nil. Distinct
  state, never classified as stale.
- "Stale": a prior success exists and `lastSuccessAt` is older than
  interval plus timeout.
- A later failed pull with retained last-good cache is a distinct
  sanitized error ("last good pull kept") reusing the existing
  `sanitizedError` strings. Raw errors never reach the dashboard.
- Sync disabled with no cache: the remote sub-line stays silent as
  today and never blocks local rows. No host, path, command,
  interval, or path-bearing error detail appears in the dashboard.

## 6. UI placement

- The health card appears only where expanded Details is reachable.
  The empty-store screen (no records from any source) and the
  no-scope screen (zero records in scope) keep their existing UI and
  notices unchanged.
- Compact stays 400pt with no scroll, controls, setup prose, or
  settings. Its only change is the footer line: when a source in
  scope needs attention (missing, unreadable, or stale), it may add
  one short hint (for example `2 sources need attention - see
  Details`); when covered, current text stays. The hint is omitted
  via a plain parent `if` when empty, so no blank strip renders.
- Details holds a `Source health` card in the scroll content after
  source rows and before top-5 models, collapsing with Show less.
  One row per source in fixed order (Codex, OpenCode, Claude) with
  OpenCode local/remote sub-lines; each row shows state label, last
  observed usage, and current-range contribution. Only the OpenCode
  remote sub-line adds sync freshness per section 5.
- No Settings controls move. At most one plain `Open Settings`
  action label, no inline host, path, command, or interval fields.
- CLI: no new flags; any addition reuses the sanitized warnings
  block only.

## 7. OpenCode origin naming

Health names the OpenCode origin explicitly even for a sole origin,
although the token `By origin` breakdown omits single-origin rows: a
single-origin row still names `local` or the effective remote label.
Labels use only sanitizer-accepted values (short `[A-Za-z0-9_.-]`
form, 64-character cap, else generic `remote` fallback). Custom
labels follow the existing rule (first explicitly distinct embedded
label wins, blank/default falls back, legacy `homeserver` loads).
No per-host split for extra DB copies, which share `remote` by
design. Contract criteria for the new card and hint slots land in
`scripts/test-popover.sh` in the implementation PR.

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
  OpenCode local/remote split, as pure functions with explicit
  `now` and `Calendar`.
- Sync states per section 5: never-synced only when
  `lastSuccessAt` is nil, stale only after a prior success older
  than interval plus timeout, failed-kept-cache as distinct
  sanitized error; never-synced is never stale.
- Compact shows at most the one-line hint, omitted when covered,
  with no scroll, controls, clipping, or empty strip. Empty-store
  and no-scope screens are unchanged.
- Details shows the card in position with three rows plus OpenCode
  sub-lines, sanitized labels, named sole origins, no settings
  fields. No token, cost, trend, filter, sync, or pricing changes;
  `URLSession`/`Process(`/host-allowlist/Cookie rules unchanged.
- Fixtures (synthetic, small, under `Fixtures/` only): Codex
  in-range/out-of-range, Claude skipped lines, OpenCode local and
  remote origins (blank, default, custom allowlisted, legacy),
  missing/unreadable inputs, never-synced/stale/failed-kept-cache
  statuses. Never real data or credentials.
- Tests: last-observed maxima vs range totals, missing vs
  unreadable vs zero-in-range vs sync states, sanitizer coverage,
  snapshot threading with no extra scans, empty/no-scope paths;
  mirror pure logic in `verify_logic.py` where mirrored; extend
  `test-popover.sh`. Mac `swift build` plus `swift test`, Linux
  mirror, shell syntax, `check-privacy.sh`, `git diff --check`,
  and touched contract scripts green. Gaps stated as gaps.

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
