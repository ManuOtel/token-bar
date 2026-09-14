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

## Attempted optimization (slice 4, this branch, unmeasured)

`OpenCodeStore.decodeSnapshotRecord` fell back to a full case-insensitive
dictionary scan on every alias miss inside the `text`/`int`/`raw` closures,
so a mixed-case record paid one scan per missed alias per field. Exact
canonical keys already took the O(1) dictionary path.

Attempt (`perf/opencode-snapshot-decode`, lazy fallback only):

- Exact-case `dict[key]` lookups stay as-is with no extra allocation
  (`Sources/TokenBarCore/OpenCodeStore.swift`). Records where every probed
  alias hits an exact key pay no fallback index cost; any missing alias
  triggers one linear fallback build: a single O(K) pass over the record's
  keys, reused for the rest of that record, so a mixed-case record pays at
  most one linear pass plus hash hits instead of one scan per missed alias.
- Duplicate case-insensitive key precedence is explicit: exact-case wins
  per alias; otherwise the lexicographically smallest original key wins
  (min comparison during the single build pass, no sort), deterministic
  across runs. Text keeps a separate smallest-keyed valid-string map so a
  non-String under a smaller key never hides a valid string collision,
  matching the old scan's skip behavior. Coercion (String non-empty,
  Int/Double/NSNumber/string-number, Bool rejection by `objCType`) is
  unchanged.
- No token-math, dedupe, timestamp, provider+model, source-filter, origin,
  fallback-ID, forbidden-key, skipped-count, or contract changes.

Tests (`Tests/TokenBarCoreTests/OpenCodeSnapshotDecodeTests.swift`, hermetic, no
network, no timing assertions): mixed-casing parity, snake_case alias
fallback, provider+model composition, source rejection (including uppercase
keys), forbidden-key detection plus non-retention, origin sanitization,
deterministic fallback IDs (request vs content-hashed, distinct rows stay
distinct), positive-token gate, timestamp plus cached read/write aliases,
coercion parity (Bool rejected, string integer accepted, string decimal
and Double truncation), and the explicit duplicate-key precedence (exact
wins, then smallest wins; heterogeneous collision keeps the valid string).

Method, split strictly:

- Reported Mac audit (not rerun here): the sanitized OpenCode snapshot is
  about 8 MB and `loadSnapshot` alone takes about 6.48 seconds. Host- and
  data-dependent.
- No speedup is claimed. This is an attempted optimization until a Mac
  before/after exists: the common canonical-key path is unchanged by
  construction, and the fallback only removes repeated scans for
  mixed-case records.
- No worker-host benchmark: this worker host has no Swift toolchain (Linux
  runs `verify_logic.py` only) and carries no snapshot data, so no
  before/after timing was run here. To measure on Mac, compare warm
  `loadSnapshot` wall time before/after on the same snapshot file; do not
  claim numbers without rerunning there.

## Attempted improvement (slice 5, this branch, perceived startup only)

`TokenBarApp` started empty and blocked the menu on the full history scan
(about 14s on a large host after the parser slices). Every refresh repeated
the scan.

Change (`perf/startup-report-cache`):

- New `StartupReportCache` (`Sources/TokenBarCore/StartupReportCache.swift`):
  versioned `{version,savedAt,report}` envelope in
  `Application Support/TokenBar/startup-report.json` (override
  `TOKENBAR_STARTUP_REPORT_CACHE` in tests), atomic write with parent-dir
  creation. Only the normalized `LoadReport` plus sanitized warnings is
  stored; corrupt or version-mismatched files are ignored and write
  failures never break a fresh load.
- `TokenBarApp` shows the cached report immediately, marks it
  `Showing previous data - updating…` while the existing
  `TokenBarStore.load` runs off-main, then publishes the fresh report with
  a generation guard (last-write-wins) and refreshes the cache. First
  appearance triggers exactly one background refresh even with cached
  records; menu opens never refresh; the refresh button stays manual and
  disabled while loading. First run with no cache keeps empty + loading.
- No token-total, source/origin/model, pricing-precedence, or dashboard
  semantics change: costs still derive per render from the live pricing
  snapshot.

Tests (`Tests/TokenBarCoreTests/StartupReportCacheTests.swift`, hermetic,
no network, no timing): round-trip totals/labels plus aggregate parity,
missing/wrong-version/corrupt/truncated rejection, no raw-path or
prompt-shaped field retention in the encoded file, and
`StartupRefreshState` once-only initial plus stale-generation drop.
`scripts/verify_logic.py` mirrors the envelope and generation checks.

Method: perceived-startup improvement only. Cached values are previous
normalized data until the background refresh finishes. First-ever load
still depends on source size. No wall-clock is claimed here: measure on
Mac by comparing time-to-first-paint before/after on the same large tree;
do not claim numbers without rerunning there.

## Attempted improvement (slice 6, this branch, allocation only)

`OpenCodeStore.loadTable` used `SELECT *` and materialized every column
into `[String: String?]` per row, although decoding probes a bounded set
of token, timestamp, identity, role, JSON-blob, and model fields. Wide
unrelated columns (prompt text, tool I/O, future drift columns) were
copied off SQLite and allocated per row, then ignored.

Change (`perf/opencode-sqlite-projection`):

- New `projectedColumns` allowlist
  (`Sources/TokenBarCore/OpenCodeStore.swift`, 76 lowercased names):
  the six JSON-blob keys plus every timestamp / token / cache /
  reasoning / total / model / session / request / role alias the pure
  decoders probe. `projectedSelection(actualColumns:)` intersects the
  live table with the allowlist (case-insensitive, table order kept);
  `quoteIdentifier` quotes with embedded-quote doubling.
- `loadTable` now reads live columns via `PRAGMA table_info`, selects
  only the intersection (`SELECT "a","b",... FROM "t"`), and
  materializes only those cells with `reserveCapacity`. Missing tables
  still skip gracefully (`([], 0)`); a table with zero recognized
  columns counts rows via `SELECT 1` without materializing cells.
- No alias, JSON-blob, precedence, mirror, skipped-count, ordering, or
  privacy change: all six blob keys still merge underneath explicit
  columns, message-beats-rollup and mirror rules are untouched, and
  wide columns were already ignored by the closed alias lists
  (projection moves the ignore earlier, no copy, instead of later,
  copy then ignore).

Tests (hermetic, no network, no timing assertions):

- `Tests/TokenBarCoreTests/OpenCodeProjectionTests.swift`: allowlist
  coverage pins, wide-column decode parity for rollup + message rows,
  all six blob keys surviving with wide columns present, quoting pins,
  plus SQLite integration (guarded by `canImport(SQLite3)`): a temp DB
  with wide `prompt_text` / `tool_*` / `future_col_v2` columns proves
  required + blob decode with identical skipped counts, no wide-content
  leakage, deterministic reload, and graceful missing-table skip.
- `scripts/verify_logic.py`: Python mirror of the allowlist, rollup +
  message wide-column parity, per-blob survival, and a real SQLite
  fixture proving the bounded `SELECT` subset plus parity/skipped
  counts. Run with `python3 scripts/verify_logic.py`.
- `scripts/bench-opencode-projection.py`: deterministic count-only
  measurement (no wall-clock, CI-safe). Same 50 synthetic wide rows
  both paths.

Method, split strictly:

- Measured facts (this worker host, same synthetic data, repeatable):
  `python3 scripts/bench-opencode-projection.py` reports 12 columns
  per row old vs 7 new, 600 cells old vs 350 new (250 saved, 41.7%),
  about 5,008,090 bytes old vs 8,090 new (5,000,000 saved, 99.8%).
  Counts are synthetic-filler dominated (20KB x 5 wide columns per
  row); real-host savings scale with actual wide-column width.
- No wall-clock is claimed. Swift is unavailable on this worker host
  (Linux runs `verify_logic.py` + the count-only bench only), and no
  Mac before/after on the same database was run here. To measure on
  Mac, compare warm `loadDatabase` wall time before/after on the same
  database file; do not claim numbers without rerunning there.
- Limitation: `fallbackMessageID` now hashes the projected columns
  only. Two ID-less rows differing solely in ignored wide columns now
  share an ID (identical usage semantics). Real tables always carry
  `id`, so this is drift tolerance only; IDs stay deterministic and
  distinct for any recognized-column difference.

## Attempted improvement (slice 7, this branch, allocation only)

`CodexParser.parseFile` and `ClaudeParser.parseFile` each read the whole
file with `String(contentsOf:)` then split it with
`components(separatedBy: .newlines)`, materializing one whole-file String
plus an array holding every line before parsing starts. Large histories
pay that input peak per file on top of the records themselves.

Change (`perf/jsonl-stream-reader`):

- New `JSONLLineReader`
  (`Sources/TokenBarCore/JSONLLineReader.swift`): streams the file through
  `InputStream` in fixed 64 KiB chunks and splits on every
  `CharacterSet.newlines` member (U+000A-U+000D, U+0085, U+2028, U+2029),
  each occurrence separately, exactly like
  `components(separatedBy: .newlines)`. CRLF keeps its phantom empty
  component and line numbers are identical to the old path, so
  `path:line` fallback ids never change. Multi-byte separators split
  across chunk boundaries are recognized via an at-most-2-byte carry;
  the final line is emitted even without a trailing newline, and strict
  whole-file UTF-8 is preserved (any undecodable line reports the old
  `([], 0)`). No shared state, no cache; per-file parsing stays strictly
  serial and the `ParallelFileParse` bounded scheduler is untouched.
- Both `parseFile` variants keep their line-by-line bodies verbatim
  (blank-line free skip, type gates, token math, per-file turn/thread
  attribution with latest-wins, skipped counts, fallback ids, privacy
  handling) and only swap the enumeration source for the reader. Record
  order stays deterministic; cross-file attribution is still impossible
  (state remains per-file locals).

Tests (hermetic, no network, no timing assertions):

- `Tests/TokenBarCoreTests/JSONLStreamingTests.swift`: Codex CRLF with
  preserved phantom `:1`/`:3` fallback ids, final line without newline,
  blank + malformed + heartbeat exact counts with the `:3` fallback pin,
  forward-only attribution across streamed lines (late context does not
  leak backwards), LF/CRLF record parity compared separately from the
  intentionally different fallback ids (`:3` LF vs `:5` CRLF), lone-CR
  splitting, VT/FF/NEL/LS/PS splitting with exact ids and skips, a
  separator starting on the last byte of a 64 KiB chunk, whole-file
  invalid-UTF-8 dropping both parsers to `([], 0)`, empty and
  newline-only files, a >64 KiB line with multibyte content crossing
  chunk boundaries, missing-file behavior, and a streaming-path privacy
  pin (no prompt or path retention in records or rendered output).
- `scripts/verify_logic.py`: Python mirror of the reader (LF split,
  CR strip, unterminated/trailing-newline handling, whole-file UTF-8
  abort, old-phantom-gap demonstration, streamed Codex counts + fallback
  id, forward-only attribution, 7-byte chunk reassembly over multibyte
  content, streamed Claude CRLF + unterminated). Run with
  `python3 scripts/verify_logic.py`.
- `scripts/bench-jsonl-streaming.py`: deterministic count-only
  measurement (no wall-clock, CI-safe). Same 5,500 synthetic lines both
  paths.

Method, split strictly:

- Measured facts (this worker host, same synthetic data, repeatable):
  `python3 scripts/bench-jsonl-streaming.py` reports 5,500 lines,
  911,279 file bytes, old input peak 1,817,058 bytes (file + all lines)
  vs new 131,241 bytes (2 x 64 KiB buffers + 169-byte longest line):
  1,685,817 saved (92.8%), and 5,501 live line objects old vs 1 new.
  Counts scale with file size on the old path and stay flat (buffers +
  longest line) on the new path; real-host savings scale with actual
  file sizes.
- No wall-clock is claimed. Swift is unavailable on this worker host
  (Linux runs `verify_logic.py` + the count-only bench only), and no Mac
  before/after on the same session tree was run here. To measure on Mac,
  compare warm `parseDirectory` / per-source CLI wall time before/after
  on the same large local tree; do not claim numbers without rerunning
  there.
- Limitations: splitting and line numbering are identical to the old
  path by construction (including CRLF phantom components and lone-CR /
  Unicode separators), so there is no fallback-id drift to qualify. The
  parsed records array is unchanged output work and still fully
  materialized; single huge files gain allocation-only benefit (no
  additional parallelism within a file). Whole-file invalid-UTF-8 still
  yields `([], 0)`, by design.

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
