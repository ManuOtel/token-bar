import Foundation
import XCTest
@testable import TokenBarCore

/// Slice 1 (catalog-lookup): the aggregate hot path builds one immutable
/// catalog index per `Aggregator.aggregate` call and reuses it per record.
///
/// These tests pin behavior preservation (no timing assertions): context and
/// snapshot single-record paths agree on price + `PriceOrigin` across every
/// precedence level, and a large synthetic catalog with heavily repeated
/// records aggregates to exactly the per-record math. Hermetic, no network.
final class PricingLookupTests: XCTestCase {
    private var now: Date {
        Date(timeIntervalSince1970: 1_789_041_600) // 2026-09-10T12:00:00Z
    }

    private func snapshot(entries: [CatalogEntry], fresh: Bool = true) -> CatalogSnapshot {
        CatalogSnapshot(
            catalog: PricingCatalog(
                sourceURL: OpenRouterCatalog.defaultURLString,
                fetchedAt: now,
                entries: entries),
            isFresh: fresh)
    }

    private func record(
        _ id: String, model: String,
        input: Int = 1000, output: Int = 500, cached: Int = 100
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: .codex, timestamp: now,
            model: model, inputTokens: input, outputTokens: output,
            cachedTokens: cached, reasoningTokens: 0,
            totalTokens: 0, sessionId: "s-\(id)", requestId: id)
    }

    // MARK: - Precedence parity (context vs snapshot)

    func testContextMatchesSnapshotAcrossPrecedence() {
        let entries = [
            // Catalog rate differs from every static rate so the winner is
            // unambiguous (catalog input 7.5 vs static exact 1.25 / family).
            CatalogEntry(model: "openai/gpt-5.6-luna", inputPerMTok: 7.5, outputPerMTok: 70.0, cachedPerMTok: 0.75),
            CatalogEntry(model: "openai/gpt-4o", inputPerMTok: 2.5, outputPerMTok: 10.0, cachedPerMTok: 1.25),
            CatalogEntry(model: "b-provider/shared-suffix", inputPerMTok: 1.0, outputPerMTok: 2.0, cachedPerMTok: 0.5),
            CatalogEntry(model: "a-provider/shared-suffix", inputPerMTok: 3.0, outputPerMTok: 4.0, cachedPerMTok: 1.0),
        ]
        let fresh = snapshot(entries: entries, fresh: true)
        let cached = snapshot(entries: entries, fresh: false)
        let freshContext = PricingContext(snapshot: fresh)
        let cachedContext = PricingContext(snapshot: cached)
        let offlineContext = PricingContext(snapshot: nil)
        XCTAssertTrue(freshContext.hasCatalog)
        XCTAssertTrue(cachedContext.hasCatalog)
        XCTAssertFalse(offlineContext.hasCatalog)

        // 1. Dynamic catalog exact beats static exact.
        for (model, expectedInput) in [
            ("openai/gpt-5.6-luna", 7.5),
            ("OPENAI/GPT-5.6-LUNA", 7.5), // case-insensitive + trimmed
            ("  openai/gpt-5.6-luna  ", 7.5),
        ] {
            let viaSnapshot = Pricing.resolve(forModel: model, snapshot: fresh)
            let viaContext = Pricing.resolve(forModel: model, context: freshContext)
            XCTAssertEqual(viaSnapshot.price.inputPerMTok, expectedInput, accuracy: 0.0001, model)
            XCTAssertEqual(viaContext.price.inputPerMTok, expectedInput, accuracy: 0.0001, model)
            XCTAssertEqual(viaSnapshot.origin, .dynamicCatalog, model)
            XCTAssertEqual(viaContext.origin, .dynamicCatalog, model)
        }

        // 2. Same entries from disk count as cached, never dynamic.
        let staleResolve = Pricing.resolve(forModel: "openai/gpt-5.6-luna", snapshot: cached)
        let staleContext = Pricing.resolve(forModel: "openai/gpt-5.6-luna", context: cachedContext)
        XCTAssertEqual(staleResolve.origin, .cachedCatalog)
        XCTAssertEqual(staleContext.origin, .cachedCatalog)
        XCTAssertEqual(
            staleResolve.price.inputPerMTok, staleContext.price.inputPerMTok, accuracy: 0.0000001)

        // 3. Bare-model suffix uses the lexically smallest catalog id.
        let bareSnapshot = Pricing.resolve(forModel: "shared-suffix", snapshot: fresh)
        let bareContext = Pricing.resolve(forModel: "shared-suffix", context: freshContext)
        XCTAssertEqual(bareSnapshot.origin, .dynamicCatalog)
        XCTAssertEqual(bareContext.origin, .dynamicCatalog)
        XCTAssertEqual(bareSnapshot.price.inputPerMTok, 3.0, accuracy: 0.0001)
        XCTAssertEqual(bareContext.price.inputPerMTok, 3.0, accuracy: 0.0001)

        // 4. Prefixed keys never guess across providers: fall to static.
        for model in ["other/gpt-4o", "other/shared-suffix"] {
            let viaSnapshot = Pricing.resolve(forModel: model, snapshot: fresh)
            let viaContext = Pricing.resolve(forModel: model, context: freshContext)
            XCTAssertEqual(viaSnapshot.origin, viaContext.origin, model)
            XCTAssertEqual(
                viaSnapshot.price.inputPerMTok, viaContext.price.inputPerMTok,
                accuracy: 0.0000001, model)
        }
        XCTAssertEqual(
            Pricing.resolve(forModel: "other/gpt-4o", snapshot: fresh).origin, .staticEstimate)

        // 5. Static exact / family / fallback without catalog.
        let staticCases: [(model: String, origin: PriceOrigin)] = [
            ("openai/gpt-5.6-luna", .staticEstimate),
            ("gpt-5", .staticEstimate),
            ("mystery-model-zzz", .fallback),
        ]
        for (model, origin) in staticCases {
            XCTAssertEqual(Pricing.resolve(forModel: model, snapshot: nil).origin, origin, model)
            XCTAssertEqual(Pricing.resolve(forModel: model, context: offlineContext).origin, origin, model)
            XCTAssertEqual(
                Pricing.resolve(forModel: model, snapshot: nil).price.inputPerMTok,
                Pricing.resolve(forModel: model, context: offlineContext).price.inputPerMTok,
                accuracy: 0.0000001, model)
        }

        // 6. Catalog miss falls through to static, identically on both paths.
        let catalogOnly = snapshot(entries: [entries[0]], fresh: true)
        let catalogOnlyContext = PricingContext(snapshot: catalogOnly)
        let missSnapshot = Pricing.resolve(forModel: "gpt-4o", snapshot: catalogOnly)
        let missContext = PricingContext(snapshot: catalogOnly).resolve(forModel: "gpt-4o")
        // Bare gpt-4o is not in the one-entry catalog, so static family wins.
        XCTAssertEqual(missSnapshot.origin, .staticEstimate)
        XCTAssertEqual(missContext.origin, .staticEstimate)
        XCTAssertEqual(
            missSnapshot.price.inputPerMTok, missContext.price.inputPerMTok, accuracy: 0.0000001)
        XCTAssertEqual(catalogOnlyContext.resolve(forModel: "gpt-4o").origin, .staticEstimate)
    }

    func testLookupDirectInitMatchesSnapshot() {
        let entries = [
            CatalogEntry(model: "openai/gpt-4o", inputPerMTok: 9.0, outputPerMTok: 9.0, cachedPerMTok: 9.0),
        ]
        let snap = snapshot(entries: entries, fresh: true)
        let lookup = CatalogLookup(snapshot: snap)
        XCTAssertEqual(lookup.entryCount, 1)
        XCTAssertTrue(lookup.isFresh)
        XCTAssertEqual(lookup.match(forModel: "openai/gpt-4o")?.inputPerMTok ?? -1, 9.0, accuracy: 0.0001)
        XCTAssertEqual(lookup.match(forModel: "GPT-4O")?.inputPerMTok ?? -1, 9.0, accuracy: 0.0001)
        XCTAssertNil(lookup.match(forModel: "other/gpt-4o"))
        // Context built from a prebuilt lookup agrees with snapshot path.
        let viaLookup = Pricing.resolve(forModel: "openai/gpt-4o", context: PricingContext(lookup: lookup))
        let viaSnapshot = Pricing.resolve(forModel: "openai/gpt-4o", snapshot: snap)
        XCTAssertEqual(viaLookup.price.inputPerMTok, viaSnapshot.price.inputPerMTok, accuracy: 0.0000001)
        XCTAssertEqual(viaLookup.origin, viaSnapshot.origin)
    }

    // MARK: - Duplicate ids and multi-slash suffixes

    func testDuplicateNormalizedIdsAndMultiSlashSuffix() {
        // Duplicate normalized ids: exact uses last-wins (same as
        // `PricingCatalog.index()`); the bare-suffix map keeps the
        // lexically smallest normalized id (same as `suffixMatch`, which
        // keeps the first entry on an exact tie).
        let duplicates = [
            CatalogEntry(model: "openai/gpt-4o", inputPerMTok: 1.0, outputPerMTok: 1.0, cachedPerMTok: 1.0),
            CatalogEntry(model: "OPENAI/GPT-4O", inputPerMTok: 2.0, outputPerMTok: 2.0, cachedPerMTok: 2.0),
            CatalogEntry(model: "  openai/gpt-4o  ", inputPerMTok: 3.0, outputPerMTok: 3.0, cachedPerMTok: 3.0),
        ]
        let snap = snapshot(entries: duplicates, fresh: true)
        let context = PricingContext(snapshot: snap)
        let lookup = CatalogLookup(snapshot: snap)
        // Exact full id: last entry wins on both paths.
        XCTAssertEqual(
            Pricing.resolve(forModel: "openai/gpt-4o", snapshot: snap).price.inputPerMTok,
            3.0, accuracy: 0.0000001)
        XCTAssertEqual(
            context.resolve(forModel: "openai/gpt-4o").price.inputPerMTok,
            3.0, accuracy: 0.0000001)
        XCTAssertEqual(lookup.match(forModel: "openai/gpt-4o")?.inputPerMTok ?? -1, 3.0, accuracy: 0.0000001)
        // Bare suffix "gpt-4o": all three normalize identically, so the
        // first entry wins on both paths (lexical tie => first kept).
        XCTAssertEqual(
            Pricing.resolve(forModel: "gpt-4o", snapshot: snap).price.inputPerMTok,
            1.0, accuracy: 0.0000001)
        XCTAssertEqual(
            context.resolve(forModel: "gpt-4o").price.inputPerMTok,
            1.0, accuracy: 0.0000001)
        XCTAssertEqual(lookup.match(forModel: "gpt-4o")?.inputPerMTok ?? -1, 1.0, accuracy: 0.0000001)

        // Multi-slash ids: the suffix is the text after the last "/".
        // Bare "tail-model" matches the lexically smallest full id;
        // slash-containing keys never take the suffix path.
        let multi = [
            CatalogEntry(model: "org/team/tail-model", inputPerMTok: 9.0, outputPerMTok: 9.0, cachedPerMTok: 9.0),
            CatalogEntry(model: "other/tail-model", inputPerMTok: 4.0, outputPerMTok: 4.0, cachedPerMTok: 4.0),
        ]
        let multiSnap = snapshot(entries: multi, fresh: true)
        let multiContext = PricingContext(snapshot: multiSnap)
        let multiLookup = CatalogLookup(snapshot: multiSnap)
        // "org/team/tail-model" < "other/tail-model" lexically, so it wins.
        for model in ["tail-model", "TAIL-MODEL"] {
            XCTAssertEqual(
                Pricing.resolve(forModel: model, snapshot: multiSnap).price.inputPerMTok,
                9.0, accuracy: 0.0000001, model)
            XCTAssertEqual(
                multiContext.resolve(forModel: model).price.inputPerMTok,
                9.0, accuracy: 0.0000001, model)
        }
        XCTAssertEqual(multiLookup.match(forModel: "tail-model")?.inputPerMTok ?? -1, 9.0, accuracy: 0.0000001)
        // Exact multi-slash id resolves directly on both paths.
        XCTAssertEqual(
            Pricing.resolve(forModel: "org/team/tail-model", snapshot: multiSnap).price.inputPerMTok,
            9.0, accuracy: 0.0000001)
        XCTAssertEqual(
            multiContext.resolve(forModel: "org/team/tail-model").price.inputPerMTok,
            9.0, accuracy: 0.0000001)
        // A slash-containing non-exact key never suffix-matches: it falls
        // through to static/fallback identically on both paths.
        let partialSnapshot = Pricing.resolve(forModel: "team/tail-model", snapshot: multiSnap)
        let partialContext = multiContext.resolve(forModel: "team/tail-model")
        XCTAssertEqual(partialSnapshot.origin, partialContext.origin)
        XCTAssertEqual(
            partialSnapshot.price.inputPerMTok, partialContext.price.inputPerMTok, accuracy: 0.0000001)
        XCTAssertNil(multiLookup.match(forModel: "team/tail-model"))
    }

    func testWhitespaceMutatedOriginAggregatesToLocal() {
        // `origin` is a public var, so post-init mutation to whitespace-only
        // must still group under "codex/local" as before this slice.
        var mutated = record("w-1", model: "gpt-4o")
        mutated.origin = "   "
        var blank = record("w-2", model: "gpt-4o")
        blank.origin = ""
        let stats = Aggregator.aggregate([mutated, blank], snapshot: nil)
        XCTAssertEqual(stats.requests, 2)
        XCTAssertEqual(stats.byOrigin.count, 1)
        XCTAssertEqual(stats.byOrigin.first?.key, "codex/local")
        XCTAssertEqual(stats.byOrigin.first?.requests, 2)
    }

    // MARK: - Large synthetic catalog with repeated records

    func testAggregateWithLargeCatalogMatchesPerRecordMath() {
        // 1,500-entry synthetic catalog: provider-XXXX/model-XXXX ids with
        // distinct rates. No fixture files, no network.
        var entries: [CatalogEntry] = []
        entries.reserveCapacity(1502)
        for i in 0..<1500 {
            let id = String(format: "provider-%04d/model-%04d", i, i)
            entries.append(CatalogEntry(
                model: id,
                inputPerMTok: 1.0 + Double(i % 7) * 0.5,
                outputPerMTok: 2.0 + Double(i % 5),
                cachedPerMTok: 0.1 + Double(i % 3) * 0.05))
        }
        // Two providers share one bare suffix: lexically smallest must win.
        entries.append(CatalogEntry(model: "b-provider/dup-model", inputPerMTok: 111.0, outputPerMTok: 222.0, cachedPerMTok: 33.0))
        entries.append(CatalogEntry(model: "a-provider/dup-model", inputPerMTok: 5.0, outputPerMTok: 6.0, cachedPerMTok: 0.5))
        let fresh = snapshot(entries: entries, fresh: true)
        let context = PricingContext(snapshot: fresh)
        XCTAssertEqual(CatalogLookup(snapshot: fresh).entryCount, 1502)

        // 3,000 records cycling through 10 catalog models + bare suffix +
        // static-exact + static-family + fallback unknown: heavy repetition,
        // the exact shape that punished per-record index rebuilds.
        let knownModels = (0..<10).map { String(format: "provider-%04d/model-%04d", $0 * 137, $0 * 137) }
        var models: [String] = []
        models.reserveCapacity(3000)
        for i in 0..<3000 {
            switch i % 14 {
            case 0: models.append("dup-model") // bare suffix -> a-provider rate
            case 1: models.append("openai/gpt-5.6-luna") // static exact (not in catalog)
            case 2: models.append("gpt-5") // static family
            case 3: models.append("mystery-model-\(i)") // fallback, distinct labels
            case 10: models.append("  \(knownModels[(i / 14) % knownModels.count])  ") // trimmed + case
            default: models.append(knownModels[i % knownModels.count])
            }
        }
        var records: [NormalizedUsage] = []
        records.reserveCapacity(models.count)
        for (index, model) in models.enumerated() {
            records.append(record(
                "r-\(index)", model: model,
                input: 1000 + (index % 5) * 100, output: 500, cached: 200))
        }

        // Hardcoded oracle (not self-referential): catalog entry
        // provider-0000/model-0000 carries input 1.0 / output 2.0 / cached
        // 0.1 per the generator above. input 1000, output 500, cached 200
        // => fresh 800: 800/1e6*1.0 + 200/1e6*0.1 + 500/1e6*2.0 = 0.00182.
        let oracleRecord = record(
            "oracle", model: "provider-0000/model-0000",
            input: 1000, output: 500, cached: 200)
        XCTAssertEqual(
            Pricing.cost(for: oracleRecord, context: context), 0.00182, accuracy: 0.0000001)
        // Bare suffix oracle: a-provider/dup-model wins (input 5.0, output
        // 6.0, cached 0.5). input 1000, output 500, cached 100 => fresh 900:
        // 900/1e6*5.0 + 100/1e6*0.5 + 500/1e6*6.0 = 0.00755.
        let suffixOracle = record(
            "oracle-suffix", model: "dup-model",
            input: 1000, output: 500, cached: 100)
        XCTAssertEqual(
            Pricing.cost(for: suffixOracle, context: context), 0.00755, accuracy: 0.0000001)
        // Fallback oracle: unknown models price at 3.0 / 12.0 / 1.5.
        // input 1000, output 500, cached 200 => fresh 800:
        // 800/1e6*3.0 + 200/1e6*1.5 + 500/1e6*12.0 = 0.0087.
        let fallbackOracle = record(
            "oracle-fallback", model: "mystery-model-oracle-zzz",
            input: 1000, output: 500, cached: 200)
        XCTAssertEqual(
            Pricing.cost(for: fallbackOracle, context: context), 0.0087, accuracy: 0.0000001)

        // Expected cost via one reused context (single lookup build), not a
        // per-record snapshot resolve. Aggregation plumbing (grouping,
        // totals, breakdowns) is still exercised through `Aggregator`.
        var expected = 0.0
        for r in records {
            expected += context.cost(for: r)
        }
        let stats = Aggregator.aggregate(records, snapshot: fresh)
        XCTAssertEqual(stats.requests, 3000)
        XCTAssertEqual(stats.estimatedCostUSD, expected, accuracy: 0.0001)

        // Precedence spot checks inside the large run (single shared
        // context; snapshot-vs-context parity is pinned separately above).
        XCTAssertEqual(
            context.resolve(forModel: "dup-model").price.inputPerMTok, 5.0, accuracy: 0.0001)
        XCTAssertEqual(context.resolve(forModel: "openai/gpt-5.6-luna").origin, .staticEstimate)
        XCTAssertEqual(context.resolve(forModel: "gpt-5").origin, .staticEstimate)
        XCTAssertEqual(context.resolve(forModel: "mystery-model-0").origin, .fallback)

        // byModel breakdown costs match the same per-record math.
        var expectedByModel: [String: Double] = [:]
        for r in records {
            expectedByModel[r.model, default: 0] += context.cost(for: r)
        }
        for entry in stats.byModel {
            XCTAssertEqual(
                entry.estimatedCostUSD, expectedByModel[entry.key] ?? -1, accuracy: 0.0001, entry.key)
        }
    }

    func testNilSnapshotOfflinePreservedWithRepeatedRecords() {
        // Same repetition shape, no catalog: deterministic static path.
        let models = ["gpt-4o-mini", "gpt-4o", "openai/gpt-5.6-luna", "mystery-model-zzz", "gpt-5"]
        var records: [NormalizedUsage] = []
        for i in 0..<500 {
            records.append(record("n-\(i)", model: models[i % models.count], input: 1000, output: 500, cached: 100))
        }
        let stats = Aggregator.aggregate(records, snapshot: nil)
        var expected = 0.0
        for r in records {
            expected += Pricing.cost(for: r, snapshot: nil)
        }
        XCTAssertEqual(stats.estimatedCostUSD, expected, accuracy: 0.0001)
        // Offline context agrees and carries no catalog.
        let offline = PricingContext(snapshot: nil)
        XCTAssertFalse(offline.hasCatalog)
        var viaOffline = 0.0
        for r in records {
            viaOffline += Pricing.cost(for: r, context: offline)
        }
        XCTAssertEqual(viaOffline, expected, accuracy: 0.0001)
    }

    func testFreshAndCachedSnapshotsSharePricesButNotLabels() {
        let entries = [
            CatalogEntry(model: "openai/gpt-4o", inputPerMTok: 42.0, outputPerMTok: 84.0, cachedPerMTok: 21.0),
        ]
        let fresh = snapshot(entries: entries, fresh: true)
        let cachedSnap = snapshot(entries: entries, fresh: false)
        let records = [
            record("a", model: "openai/gpt-4o"),
            record("b", model: "openai/gpt-4o", input: 2000, output: 1000, cached: 500),
            record("c", model: "mystery-model-zzz"),
        ]
        let freshStats = Aggregator.aggregate(records, snapshot: fresh)
        let cachedStats = Aggregator.aggregate(records, snapshot: cachedSnap)
        // Cost math is identical; only the PriceOrigin label differs.
        XCTAssertEqual(freshStats.estimatedCostUSD, cachedStats.estimatedCostUSD, accuracy: 0.0000001)
        XCTAssertEqual(
            Pricing.resolve(forModel: "openai/gpt-4o", snapshot: fresh).origin, .dynamicCatalog)
        XCTAssertEqual(
            Pricing.resolve(forModel: "openai/gpt-4o", snapshot: cachedSnap).origin, .cachedCatalog)
        XCTAssertEqual(
            Pricing.resolve(forModel: "openai/gpt-4o", context: PricingContext(snapshot: fresh)).origin,
            .dynamicCatalog)
        XCTAssertEqual(
            Pricing.resolve(forModel: "openai/gpt-4o", context: PricingContext(snapshot: cachedSnap)).origin,
            .cachedCatalog)
    }
}
