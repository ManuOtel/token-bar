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

## Next safe slices (pure core, behavior-preserving)

1. Per-model price memoization inside aggregate: cache resolved
   `(price, origin)` per normalized model key so repeated models pay one
   dictionary hit + one static-table scan total, not one per record.
2. Static-table fast path: keep table order/precedence byte-identical but
   avoid repeated substring scans for the same key (follows from slice 2's
   cache; no rate or order change).
3. Aggregate allocation hygiene: reuse calendar/formatter work in
   `dailyTrend`, keep breakdown sorting identical, extend reserve-capacity
   coverage where profiling shows it. No output change.
4. Report/CLI rendering only if profiled: same strings, fewer temporaries.

Out of scope for perf slices: parser heuristics, merge/dedupe rules, UI
layout, usage totals, pricing rates/precedence, network or cache policy.
Each slice ships with parity tests and a `verify_logic.py` + privacy-gate
pass before review.
