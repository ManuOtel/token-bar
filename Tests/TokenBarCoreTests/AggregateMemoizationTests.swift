import Foundation
import XCTest
@testable import TokenBarCore

/// Slice 8 (aggregate price memoization): `Aggregator.aggregate` resolves
/// each unique `Pricing.normalizedKey` once per call and reuses the exact
/// `(ModelPrice, PriceOrigin)` for cost math.
///
/// These tests pin behavior preservation with no timing assertions:
/// mixed-case/whitespace variants share one normalized lookup result, and
/// aggregate output matches a reference that resolves every record
/// independently across nil, fresh, and cached catalog snapshots.
/// Hermetic, no network.
final class AggregateMemoizationTests: XCTestCase {
    private var now: Date {
        Date(timeIntervalSince1970: 1_789_041_600) // 2026-09-10T12:00:00Z
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func snapshot(entries: [CatalogEntry], fresh: Bool) -> CatalogSnapshot {
        CatalogSnapshot(
            catalog: PricingCatalog(
                sourceURL: OpenRouterCatalog.defaultURLString,
                fetchedAt: now,
                entries: entries),
            isFresh: fresh)
    }

    private func record(
        _ id: String, model: String, source: UsageSource = .codex,
        input: Int = 1000, output: Int = 500, cached: Int = 100,
        reasoning: Int = 0, session: String? = nil
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: source, timestamp: now,
            model: model, inputTokens: input, outputTokens: output,
            cachedTokens: cached, reasoningTokens: reasoning,
            totalTokens: 0, sessionId: session ?? "s-\(id)", requestId: id)
    }

    // MARK: - Normalized variants share one lookup result

    func testMixedCaseWhitespaceVariantsShareNormalizedResult() {
        let entries = [
            CatalogEntry(model: "openai/gpt-4o", inputPerMTok: 9.0, outputPerMTok: 9.0, cachedPerMTok: 9.0),
        ]
        let variants = [
            "openai/gpt-4o",
            "OPENAI/GPT-4O",
            "  openai/gpt-4o  ",
            "\tOpenAI/Gpt-4O\n",
        ]
        // Behavior-level sharing check: many records, one normalized key.
        // This asserts the precondition the memoization relies on (resolve
        // is a pure function of the normalized key) without reaching into
        // the private cache.
        let keys = Set(variants.map { Pricing.normalizedKey(forModel: $0) })
        XCTAssertEqual(keys.count, 1)
        XCTAssertGreaterThan(variants.count, keys.count)

        for fresh in [true, false] {
            let snap: CatalogSnapshot? = fresh
                ? snapshot(entries: entries, fresh: true)
                : snapshot(entries: entries, fresh: false)
            // Nil snapshot uses the static path; supplied snapshots use the
            // catalog path with fresh-vs-cached labels.
            let context = PricingContext(snapshot: snap)
            let expected = context.resolve(forModel: variants[0])
            for variant in variants {
                let viaContext = context.resolve(forModel: variant)
                XCTAssertEqual(viaContext.price, expected.price, "\(variant) fresh=\(fresh)")
                XCTAssertEqual(viaContext.origin, expected.origin, "\(variant) fresh=\(fresh)")
            }
        }
        // Static path (nil snapshot) shares identically.
        let offline = PricingContext(snapshot: nil)
        let staticFirst = offline.resolve(forModel: variants[0])
        for variant in variants {
            XCTAssertEqual(offline.resolve(forModel: variant).price, staticFirst.price, variant)
            XCTAssertEqual(offline.resolve(forModel: variant).origin, staticFirst.origin, variant)
        }
        // Bare-suffix sharing: case variants of one bare key hit the same
        // lexically-smallest catalog entry.
        let dup = [
            CatalogEntry(model: "b-provider/dup-model", inputPerMTok: 111.0, outputPerMTok: 222.0, cachedPerMTok: 33.0),
            CatalogEntry(model: "a-provider/dup-model", inputPerMTok: 5.0, outputPerMTok: 6.0, cachedPerMTok: 0.5),
        ]
        let dupSnap = snapshot(entries: dup, fresh: true)
        let dupContext = PricingContext(snapshot: dupSnap)
        XCTAssertEqual(
            dupContext.resolve(forModel: "DUP-MODEL").price.inputPerMTok, 5.0, accuracy: 0.0001)
        XCTAssertEqual(
            dupContext.resolve(forModel: "  dup-model ").price.inputPerMTok, 5.0, accuracy: 0.0001)
    }

    // MARK: - Aggregate matches independent per-record resolution

    func testAggregateMatchesIndependentPerRecordAcrossSnapshots() {
        let entries = [
            CatalogEntry(model: "openai/gpt-4o", inputPerMTok: 9.0, outputPerMTok: 9.0, cachedPerMTok: 9.0),
            CatalogEntry(model: "b-provider/dup-model", inputPerMTok: 111.0, outputPerMTok: 222.0, cachedPerMTok: 33.0),
            CatalogEntry(model: "a-provider/dup-model", inputPerMTok: 5.0, outputPerMTok: 6.0, cachedPerMTok: 0.5),
        ]
        let fresh = snapshot(entries: entries, fresh: true)
        let cachedSnap = snapshot(entries: entries, fresh: false)
        let snapshots: [CatalogSnapshot?] = [nil, fresh, cachedSnap]

        // Heavy repetition across precedence levels: catalog exact (with
        // case/whitespace variants sharing one normalized key), catalog
        // bare suffix, static exact, static family, and fallback. Varied
        // token counts exercise cached-subset clamping and oversized cached.
        let models = [
            "openai/gpt-4o",
            "OPENAI/GPT-4O",
            "  openai/gpt-4o  ",
            "dup-model",
            "DUP-MODEL",
            "openai/gpt-5.6-luna", // static exact (not in this catalog)
            "gpt-5", // static family
            "mystery-model-zzz", // fallback
        ]
        var records: [NormalizedUsage] = []
        records.reserveCapacity(240)
        for i in 0..<240 {
            let model = models[i % models.count]
            let source: UsageSource = i % 3 == 0 ? .codex : (i % 3 == 1 ? .opencode : .claude)
            records.append(record(
                "m-\(i)", model: model, source: source,
                input: 1000 + (i % 5) * 100, output: 500 + (i % 3) * 50,
                cached: i % 7 == 0 ? 5000 : 200, // oversized hits the clamp
                reasoning: 60, session: "sess-\(i % 11)"))
        }
        // Deterministic precondition for the slice: far fewer normalized
        // keys than records (the sharing the cache exploits).
        let uniqueKeys = Set(records.map { Pricing.normalizedKey(forModel: $0.model) })
        XCTAssertLessThan(uniqueKeys.count, records.count)
        XCTAssertEqual(uniqueKeys.count, Set(models.map { Pricing.normalizedKey(forModel: $0) }).count)

        for snap in snapshots {
            let label = snap == nil ? "nil" : (snap!.isFresh ? "fresh" : "cached")
            let stats = Aggregator.aggregate(records, snapshot: snap, calendar: calendar)

            // Reference: resolve every record independently (no cache).
            var expectedCost = 0.0
            for r in records {
                expectedCost += Pricing.cost(for: r, snapshot: snap)
            }
            XCTAssertEqual(stats.estimatedCostUSD, expectedCost, accuracy: 0.0001, "cost \(label)")

            // Full behavior parity: totals, counts, sessions, recency,
            // and every breakdown (keys, tokens, requests, costs, order).
            XCTAssertEqual(stats.totalTokens, records.reduce(0) { $0 + $1.totalTokens }, label)
            XCTAssertEqual(stats.inputTokens, records.reduce(0) { $0 + $1.inputTokens }, label)
            XCTAssertEqual(stats.outputTokens, records.reduce(0) { $0 + $1.outputTokens }, label)
            XCTAssertEqual(stats.cachedTokens, records.reduce(0) { $0 + $1.cachedTokens }, label)
            XCTAssertEqual(stats.reasoningTokens, records.reduce(0) { $0 + $1.reasoningTokens }, label)
            XCTAssertEqual(stats.requests, records.count, label)
            XCTAssertEqual(stats.sessions, Set(records.map(\.sessionId)).count, label)
            XCTAssertEqual(stats.lastUpdated, records.map(\.timestamp).max(), label)

            // byModel keeps raw model strings (not normalized) as keys.
            var expectedByModel: [String: (tokens: Int, requests: Int, cost: Double)] = [:]
            for r in records {
                var group = expectedByModel[r.model] ?? (0, 0, 0)
                group.tokens += r.totalTokens
                group.requests += 1
                group.cost += Pricing.cost(for: r, snapshot: snap)
                expectedByModel[r.model] = group
            }
            let expectedModelEntries = expectedByModel.map {
                BreakdownEntry(
                    key: $0.key, totalTokens: $0.value.tokens,
                    requests: $0.value.requests, estimatedCostUSD: $0.value.cost)
            }.sorted {
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                return $0.key < $1.key
            }
            XCTAssertEqual(stats.byModel.count, expectedModelEntries.count, "byModel count \(label)")
            for (got, want) in zip(stats.byModel, expectedModelEntries) {
                XCTAssertEqual(got.key, want.key, label)
                XCTAssertEqual(got.totalTokens, want.totalTokens, label)
                XCTAssertEqual(got.requests, want.requests, label)
                XCTAssertEqual(got.estimatedCostUSD, want.estimatedCostUSD, accuracy: 0.0001, "\(label) \(got.key)")
            }

            // bySource / byOrigin grouping and sort order preserved.
            var expectedBySource: [String: (tokens: Int, requests: Int, cost: Double)] = [:]
            var expectedByOrigin: [String: (tokens: Int, requests: Int, cost: Double)] = [:]
            for r in records {
                let sourceKey = r.source.rawValue
                var s = expectedBySource[sourceKey] ?? (0, 0, 0)
                s.tokens += r.totalTokens
                s.requests += 1
                s.cost += Pricing.cost(for: r, snapshot: snap)
                expectedBySource[sourceKey] = s
                let originKey = "\(r.source.rawValue)/\(r.origin)"
                var o = expectedByOrigin[originKey] ?? (0, 0, 0)
                o.tokens += r.totalTokens
                o.requests += 1
                o.cost += Pricing.cost(for: r, snapshot: snap)
                expectedByOrigin[originKey] = o
            }
            func sortedEntries(_ groups: [String: (tokens: Int, requests: Int, cost: Double)]) -> [BreakdownEntry] {
                groups.map {
                    BreakdownEntry(
                        key: $0.key, totalTokens: $0.value.tokens,
                        requests: $0.value.requests, estimatedCostUSD: $0.value.cost)
                }.sorted {
                    if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                    return $0.key < $1.key
                }
            }
            let wantSource = sortedEntries(expectedBySource)
            XCTAssertEqual(stats.bySource.map(\.key), wantSource.map(\.key), "bySource keys \(label)")
            for (got, want) in zip(stats.bySource, wantSource) {
                XCTAssertEqual(got.totalTokens, want.totalTokens, label)
                XCTAssertEqual(got.estimatedCostUSD, want.estimatedCostUSD, accuracy: 0.0001, label)
            }
            let wantOrigin = sortedEntries(expectedByOrigin)
            XCTAssertEqual(stats.byOrigin.map(\.key), wantOrigin.map(\.key), "byOrigin keys \(label)")
            for (got, want) in zip(stats.byOrigin, wantOrigin) {
                XCTAssertEqual(got.totalTokens, want.totalTokens, label)
                XCTAssertEqual(got.estimatedCostUSD, want.estimatedCostUSD, accuracy: 0.0001, label)
            }

            // Fresh vs cached share cost math; labels differ only in resolve.
            if snap != nil {
                XCTAssertEqual(
                    Pricing.resolve(forModel: "openai/gpt-4o", snapshot: fresh).origin, .dynamicCatalog)
                XCTAssertEqual(
                    Pricing.resolve(forModel: "openai/gpt-4o", snapshot: cachedSnap).origin, .cachedCatalog)
            }
        }

        // Fresh and cached snapshots agree on cost across the repeated set.
        let freshStats = Aggregator.aggregate(records, snapshot: fresh, calendar: calendar)
        let cachedStats = Aggregator.aggregate(records, snapshot: cachedSnap, calendar: calendar)
        XCTAssertEqual(
            freshStats.estimatedCostUSD, cachedStats.estimatedCostUSD, accuracy: 0.0000001)
    }

    func testEmptyAggregatePreserved() {
        XCTAssertEqual(
            Aggregator.aggregate([], snapshot: nil, calendar: calendar).requests, 0)
        XCTAssertNil(
            Aggregator.aggregate([], snapshot: nil, calendar: calendar).lastUpdated)
        let snap = snapshot(entries: [], fresh: true)
        XCTAssertEqual(
            Aggregator.aggregate([], snapshot: snap, calendar: calendar).requests, 0)
    }

    func testSharedPriceHelperMatchesResolvingPaths() {
        // The non-resolving helper is the single cost-math implementation:
        // feeding it an already-resolved price must equal every resolving
        // path, including cached-subset clamping edges. Hermetic, no timing.
        let offline = PricingContext(snapshot: nil)
        let cases: [(model: String, input: Int, output: Int, cached: Int)] = [
            ("openai/gpt-5.6-luna", 1000, 500, 100), // static exact
            ("gpt-5", 1000, 500, 1000), // all input cached
            ("gpt-4o", 100, 0, 5000), // oversized cached clamps to input
            ("mystery-model-zzz", 1000, 500, 200), // fallback
            ("OPENAI/GPT-5.6-LUNA", 1000, 500, 100), // case variant, same key
        ]
        for c in cases {
            let resolved = offline.resolve(forModel: c.model)
            let viaHelper = Pricing.cost(
                price: resolved.price,
                inputTokens: c.input, outputTokens: c.output, cachedTokens: c.cached)
            XCTAssertEqual(
                viaHelper,
                Pricing.cost(
                    model: c.model, inputTokens: c.input,
                    outputTokens: c.output, cachedTokens: c.cached,
                    context: offline),
                accuracy: 0.0000001, c.model)
            XCTAssertEqual(
                viaHelper,
                Pricing.cost(
                    model: c.model, inputTokens: c.input,
                    outputTokens: c.output, cachedTokens: c.cached,
                    snapshot: nil),
                accuracy: 0.0000001, c.model)
        }
    }
}
