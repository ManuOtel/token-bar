# Performance

Scope: local-only CLI/app aggregation cost. All dollar figures stay estimates;
this note covers wall-clock only. No behavior change: totals, grouping,
pricing precedence, and `PriceOrigin` labels are pinned by tests.

## Measured baseline (Mac, warm, direct CLI)

All-source `7d` preset, warm direct CLI run:

- All-source 7d: **34.35s**
- Isolated Codex: **27.21s**
- OpenCode snapshot: **6.34s**
- Claude: **0.20s**

Read as: Codex dominates the 7d window on this host; OpenCode snapshot and
Claude are small fractions. Baseline is host- and data-dependent; rerun
`time scripts/show-usage.sh --preset 7d --source all` (and per-source) on the
Mac to compare. Linux has no Swift toolchain and runs `verify_logic.py` only.

## Verified issue (slice 1, shipped)

`Pricing.resolve(forModel:snapshot:)` rebuilt the full catalog exact-match
dictionary (`PricingCatalog.index()`, O(entries)) on **every record**, and
bare-model lookups additionally scanned **every catalog entry** via
`PricingCatalog.suffixMatch(forKey:)`. `Aggregator.aggregate` calls pricing
once per record, so catalog-priced aggregation was O(records x entries) with
one dictionary build per record.

Fix (`perf/catalog-lookup`):

- New immutable `CatalogLookup` (`Sources/TokenBarCore/PricingCatalog.swift`):
  exact map + precomputed bare-suffix map (lexically smallest id wins, same
  rule as `suffixMatch`) built in one O(entries) pass.
- New immutable `PricingContext` (`Sources/TokenBarCore/Pricing.swift`):
  wraps an optional lookup; `resolve`/`price`/`cost` overloads with identical
  precedence and `PriceOrigin` labels (`dynamicCatalog | cachedCatalog |
  staticEstimate | fallback`). Single-record `snapshot:` APIs delegate to it,
  so they stay source-compatible.
- `Aggregator.aggregate(_:snapshot:calendar:)` builds one `PricingContext`
  per call and reuses it for every record. Nil snapshot keeps the
  deterministic offline static path.
- Small, hot-path-only extras: reuse the already-normalized
  `record.origin` (no per-record trim) and reserve group/set capacities.
  No parser, merge/dedupe, UI, or usage-total changes.

Tests (`Tests/TokenBarCoreTests/PricingLookupTests.swift`, hermetic, no
network): context-vs-snapshot parity across exact / suffix / static-exact /
family / fallback plus fresh-vs-cached labels, suffix tie-break, a large
synthetic catalog (1,502 entries) with 3,000 heavily repeated records
asserting aggregate cost equals per-record math and `byModel` costs match,
and nil-snapshot offline parity. No timing assertions.

## Verified issue (slice 2, shipped)

`TokenBarApp.body` recomputed the full report on every SwiftUI render: one
`Aggregator.filter` (full scan + sort) each for the scoped rows, the
selected stats, the best-month key, and four source chips, plus a second
`Date()` + filter + reduce for the menu title. A render cost ~7-9 filter
sorts and two clock values that could disagree on boundary records.

Fix (`perf/single-pass-dashboard`):

- New pure `DashboardSnapshot` (`Sources/TokenBarCore/DashboardSnapshot.swift`):
  one explicit `now` drives one sorted selected-scope filter, one
  `Aggregator.aggregate` (which keeps the slice-1 single `PricingContext`
  reuse), and one unsorted single pass for the four chip totals (counts +
  tokens only, no sorted arrays). No cache, no shared state: pricing changes
  are an input snapshot, so costs recompute without stale values.
- `TokenBarApp.body` builds one snapshot per render and derives the menu
  title, stats, scoped count, chips, and best-month key from it. Menu title
  formatting and the `.bestMonth` lifetime-title semantics are preserved
  byte-for-byte; only the duplicate second `Date()` is gone.
- No token-total, dedupe, cost-math, parser, or pricing-precedence changes.

Tests (`Tests/TokenBarCoreTests/DashboardSnapshotTests.swift`, hermetic, no
network, no timing assertions): selected stats vs legacy filter + aggregate
parity across window presets/sources, menu total agreement, per-chip vs
filter totals with all-source reconciliation, best-month key/stats agreement
with the preserved lifetime menu total, pricing-snapshot cost recompute, and
menu-title formatting pins.

Method: pass counting by code inspection only. No wall-clock measured here:
this worker host has no Swift toolchain (Linux runs `verify_logic.py` only).
To measure on Mac, compare menu-open render work before/after on a large
local report; do not claim numbers without rerunning there.

## Verified issue (slice 3, shipped)

`CodexParser.parseDirectory` and `ClaudeParser.parseDirectory` enumerated
and parsed files sequentially: one file read plus one line-by-line JSON
decode at a time, appended in enumerator order.

Fix (`perf/parallel-jsonl-parse`):

- New `ParallelFileParse` (`Sources/TokenBarCore/ParallelFileParse.swift`):
  `sortedJSONLFiles` enumerates once then sorts by standardized path,
  `mapOrdered` runs one `Operation` per file on an `OperationQueue` capped
  at `defaultMaxWorkers` (`min(8, activeProcessorCount)`, floored at 1),
  and pure `mergeOrdered` concatenates per-file chunks in sorted-file order
  and sums skipped counts. Slot writes go through an `NSLock`-guarded box;
  no shared mutable parse state, no global state, no unbounded tasks.
- Both JSONL adapters use the same helper. Each file is still parsed
  strictly sequentially by the existing `parseFile` (per-file turn/thread
  attribution, skipped-line counts, type gates, token math, fallback ids,
  and error handling unchanged; lines within a file are never
  parallelized). No `NormalizedUsage` / dedupe / token-math change.
  OpenCode storage is untouched in this slice.
- Output order is now the sorted-file order (deterministic across runs and
  hosts) instead of raw enumerator order; within a file, line order is
  unchanged.

Tests (`Tests/TokenBarCoreTests/ParallelFileParseTests.swift`, hermetic, no
network, no timing assertions): pure `mergeOrdered` order plus skipped-sum
pins, `defaultMaxWorkers` bounded to 1...8 and never above CPU count,
`mapOrdered` order preservation across 20 synthetic files with 4 workers
vs the sequential path, Codex multi-file ordering plus aggregate
record/skipped counts with sequential-merge parity, Codex turn-context
attribution staying scoped to its file (same turn id in a second file
stays `unknown`), Claude multi-file ordering plus aggregate counts with
sequential-merge parity, and sorted enumeration ignoring non-JSONL files.

Method, split strictly:

- Measured claims (Mac audit, not rerun here): Codex sessions are about
  749 MB across 455 JSONL files and take about 27.21 seconds to parse;
  Claude is about 0.20 seconds; all-source 7d is 34.35s with Codex
  dominant. Host- and data-dependent; rerun
  `time scripts/show-usage.sh --preset 7d --source all` (and per-source)
  on the Mac to compare.
- Code-inspection claims only (no new wall-clock): total parse work is
  unchanged (same files, same per-line decode); wall time should drop on
  multi-core hosts because independent file parses overlap, bounded by IO
  plus JSON decode and the 8-worker cap. No speedup number is claimed.
- No worker-host real-data benchmark: this worker host has no Swift
  toolchain (Linux runs `verify_logic.py` only) and carries no real
  session data, so no before/after timing was run here. To measure on Mac,
  compare warm `parseDirectory` / per-source CLI wall time before/after on
  the same large local tree; do not claim numbers without rerunning there.

## Next safe slices (pure core, behavior-preserving)

1. Per-model price memoization inside aggregate: cache resolved
   `(price, origin)` per normalized model key so repeated models pay one
   dictionary hit + one static-table scan total, not one per record.
2. Static-table fast path: keep table order/precedence byte-identical but
   avoid repeated substring scans for the same key (follows from item 1's
   cache; no rate or order change).
3. Aggregate allocation hygiene: reuse calendar/formatter work in
   `dailyTrend`, keep breakdown sorting identical, extend reserve-capacity
   coverage where profiling shows it. No output change.
4. Report/CLI rendering only if profiled: same strings, fewer temporaries.

Out of scope for perf slices: parser heuristics, merge/dedupe rules, UI
layout, usage totals, pricing rates/precedence, network or cache policy.
Each slice ships with parity tests and a `verify_logic.py` + privacy-gate
pass before review.
