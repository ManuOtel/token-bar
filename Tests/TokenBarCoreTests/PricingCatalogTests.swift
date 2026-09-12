import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import TokenBarCore

/// Dynamic pricing: OpenRouter decode/normalization, catalog-first
/// precedence, stale/offline cache behavior, privacy boundary, malformed
/// catalogs. Synthetic fixtures only; no test touches the network (every
/// refresh goes through `MockFetcher`, never `URLSession`).
final class PricingCatalogTests: XCTestCase {
    private var now: Date {
        Date(timeIntervalSince1970: 1_789_041_600) // 2026-09-10T12:00:00Z
    }

    // MARK: - Fixtures

    private func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
        let here = URL(fileURLWithPath: "\(file)")
        return here.deletingLastPathComponent() // Tests/TokenBarCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func freshSnapshot(entries: [CatalogEntry]) -> CatalogSnapshot {
        CatalogSnapshot(
            catalog: PricingCatalog(
                sourceURL: OpenRouterCatalog.defaultURLString,
                fetchedAt: now,
                entries: entries),
            isFresh: true)
    }

    // MARK: - Decoding / normalization

    func testOpenRouterDecodingAndNormalization() throws {
        let data = try fixtureData("pricing-openrouter-sample.json")
        let entries = try OpenRouterCatalog.decodeEntries(from: data)
        // 4 usable + 2 broken (bad rate, missing pricing) skipped, sorted.
        XCTAssertEqual(entries.map(\.model), [
            "anthropic/claude-sonnet-4",
            "google/gemini-flash-1.5",
            "openai/gpt-4o",
            "openai/gpt-5.6-luna",
        ])
        let gpt4o = entries.first(where: { $0.model == "openai/gpt-4o" })!
        XCTAssertEqual(gpt4o.inputPerMTok, 2.5, accuracy: 0.0001)
        XCTAssertEqual(gpt4o.outputPerMTok, 10.0, accuracy: 0.0001)
        XCTAssertEqual(gpt4o.cachedPerMTok, 1.25, accuracy: 0.0001)
        // No cache field published: cached bills at the input rate (no
        // invented discount), documented in docs/PRICING.md.
        let sonnet = entries.first(where: { $0.model == "anthropic/claude-sonnet-4" })!
        XCTAssertEqual(sonnet.cachedPerMTok, sonnet.inputPerMTok, accuracy: 0.000001)
        let flash = entries.first(where: { $0.model == "google/gemini-flash-1.5" })!
        XCTAssertEqual(flash.inputPerMTok, 0.35, accuracy: 0.0001)
        XCTAssertEqual(flash.cachedPerMTok, 0.35, accuracy: 0.0001)
    }

    func testCacheCodecRoundTrip() throws {
        let data = try fixtureData("pricing-cache-sample.json")
        let catalog = try PricingCatalogCodec.decode(data)
        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(catalog.sourceURL, OpenRouterCatalog.defaultURLString)
        XCTAssertEqual(catalog.entries.count, 2)
        let reencoded = try PricingCatalogCodec.encode(catalog)
        XCTAssertEqual(try PricingCatalogCodec.decode(reencoded), catalog)
    }

    // MARK: - Precedence

    func testCatalogBeatsStaticExact() throws {
        // Fixture luna catalog rate (5.0 input) differs from the static exact
        // approximation (1.25), so the winner is unambiguous.
        let data = try fixtureData("pricing-openrouter-sample.json")
        let entries = try OpenRouterCatalog.decodeEntries(from: data)
        let fresh = freshSnapshot(entries: entries)
        let resolved = Pricing.resolve(forModel: "openai/gpt-5.6-luna", snapshot: fresh)
        XCTAssertEqual(resolved.price.inputPerMTok, 5.0, accuracy: 0.0001)
        XCTAssertEqual(resolved.origin, .dynamicCatalog)
        // Same entries loaded from disk count as cached, never dynamic.
        let stale = CatalogSnapshot(catalog: fresh.catalog, isFresh: false)
        XCTAssertEqual(Pricing.resolve(forModel: "openai/gpt-5.6-luna", snapshot: stale).origin, .cachedCatalog)
    }

    func testStaticExactBeatsFamilyAndFallbackWithoutSnapshot() {
        XCTAssertEqual(Pricing.resolve(forModel: "openai/gpt-5.6-luna").origin, .staticEstimate)
        XCTAssertTrue(Pricing.isExactMatch(forModel: "openai/gpt-5.6-luna"))
        // Family hit without any snapshot.
        XCTAssertEqual(Pricing.resolve(forModel: "gpt-5").origin, .staticEstimate)
        // Unknown models stay visible at fallback, never zeroed.
        let unknown = Pricing.resolve(forModel: "some-future-model-zzz")
        XCTAssertEqual(unknown.origin, .fallback)
        XCTAssertEqual(unknown.price.inputPerMTok, 3.0, accuracy: 0.0001)
    }

    func testCatalogMissFallsThroughToStaticThenFallback() throws {
        let data = try fixtureData("pricing-openrouter-sample.json")
        let entries = try OpenRouterCatalog.decodeEntries(from: data)
        let snapshot = freshSnapshot(entries: entries)
        // Not in the catalog: static exact still wins over fallback.
        let lunaOnly = freshSnapshot(entries: entries.filter { $0.model != "openai/gpt-5.6-luna" })
        XCTAssertEqual(Pricing.resolve(forModel: "openai/gpt-5.6-luna", snapshot: lunaOnly).origin, .staticEstimate)
        // In neither: fallback, still visible.
        XCTAssertEqual(
            Pricing.resolve(forModel: "mystery-model-zzz", snapshot: snapshot).origin, .fallback)
    }

    func testSuffixMatchWidensBareModelCoverage() throws {
        let data = try fixtureData("pricing-openrouter-sample.json")
        let entries = try OpenRouterCatalog.decodeEntries(from: data)
        let snapshot = freshSnapshot(entries: entries)
        // Bare usage model matches the provider-prefixed catalog id.
        let bare = Pricing.resolve(forModel: "gpt-4o", snapshot: snapshot)
        XCTAssertEqual(bare.origin, .dynamicCatalog)
        XCTAssertEqual(bare.price.inputPerMTok, 2.5, accuracy: 0.0001)
        // Case-insensitive by construction.
        XCTAssertEqual(
            Pricing.resolve(forModel: "GPT-4O", snapshot: snapshot).price.inputPerMTok,
            2.5, accuracy: 0.0001)
        // A prefixed key that matches nothing falls through to the static
        // family table instead of guessing across providers.
        let other = Pricing.resolve(forModel: "other/gpt-4o", snapshot: snapshot)
        XCTAssertEqual(other.origin, .staticEstimate)
    }

    // MARK: - Freshness / offline cache

    func testFreshnessThreshold() {
        XCTAssertTrue(PricingFreshness.isFresh(fetchedAt: now, now: now))
        XCTAssertTrue(PricingFreshness.isFresh(
            fetchedAt: now.addingTimeInterval(-6 * 24 * 3600), now: now))
        XCTAssertFalse(PricingFreshness.isFresh(
            fetchedAt: now.addingTimeInterval(-8 * 24 * 3600), now: now))
        // Future timestamps never count as fresh.
        XCTAssertFalse(PricingFreshness.isFresh(
            fetchedAt: now.addingTimeInterval(3600), now: now))
    }

    func testLoadCachedCatalogOffline() throws {
        let service = PricingService(fetcher: MockFetcher.failing())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let path = directory.appendingPathComponent("pricing-catalog.json")
        // Missing file: nil, never throws (static estimates apply).
        XCTAssertNil(service.loadCachedCatalog(now: now, from: path))
        // Round trip: fresh entries load back with age metadata.
        let catalog = try PricingCatalogCodec.decode(try fixtureData("pricing-cache-sample.json"))
        try service.saveCatalog(catalog, to: path)
        // Fixture fetchedAt is 2026-09-11T12:00Z; eight days later it loads
        // back intact but counts as cached/stale, never dynamic.
        let loaded = service.loadCachedCatalog(
            now: Date(timeIntervalSince1970: 1_789_819_200), from: path)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.catalog.entries.count, 2)
        XCTAssertEqual(loaded?.isFresh, false)
        // Malformed file: nil, never throws (offline graceful).
        try "not json".data(using: .utf8)!.write(to: path)
        XCTAssertNil(service.loadCachedCatalog(now: now, from: path))
    }

    func testRefreshSuccessPersistsAndReturnsDynamic() async throws {
        let payload = try fixtureData("pricing-openrouter-sample.json")
        let mock = MockFetcher(result: .success((payload, MockFetcher.okResponse())))
        let service = PricingService(fetcher: mock)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pricing-catalog.json")
        let result = await service.refresh(now: now, cacheURL: path)
        XCTAssertEqual(result.status, "dynamic")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.snapshot?.isFresh, true)
        XCTAssertEqual(result.snapshot?.catalog.entries.count, 4)
        XCTAssertTrue(result.message.contains("4 models"))
        // Persisted file decodes through the strict codec.
        let persisted = try PricingCatalogCodec.decode(try Data(contentsOf: path))
        XCTAssertEqual(persisted.entries.count, 4)
        XCTAssertEqual(mock.requestedURLs.count, 1)
        XCTAssertEqual(mock.requestedURLs.first?.absoluteString, OpenRouterCatalog.defaultURLString)
    }

    func testRefreshOfflineFallsBackToCache() async throws {
        let catalog = try PricingCatalogCodec.decode(try fixtureData("pricing-cache-sample.json"))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pricing-catalog.json")
        let seed = PricingService(fetcher: MockFetcher.failing())
        try seed.saveCatalog(catalog, to: path)
        let service = PricingService(fetcher: MockFetcher.failing())
        let result = await service.refresh(now: now, cacheURL: path)
        XCTAssertEqual(result.status, "cached")
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.snapshot?.catalog.entries.count, 2)
        XCTAssertTrue(result.message.contains("cached catalog") || result.message.contains("offline"))
    }

    func testRefreshOfflineWithoutCacheFallsBackToStatic() async {
        let service = PricingService(fetcher: MockFetcher.failing())
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pricing-catalog.json")
        let result = await service.refresh(now: now, cacheURL: path)
        XCTAssertEqual(result.status, "offline")
        XCTAssertNil(result.snapshot)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.message.contains("static"))
    }

    func testRefreshMalformedPayloadKeepsCache() async throws {
        let catalog = try PricingCatalogCodec.decode(try fixtureData("pricing-cache-sample.json"))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pricing-catalog.json")
        try PricingService(fetcher: MockFetcher.failing()).saveCatalog(catalog, to: path)
        let garbage = "this is not json".data(using: .utf8)!
        let service = PricingService(
            fetcher: MockFetcher(result: .success((garbage, MockFetcher.okResponse()))))
        let result = await service.refresh(now: now, cacheURL: path)
        XCTAssertEqual(result.status, "cached")
        XCTAssertEqual(result.snapshot?.catalog.entries.count, 2)
    }

    func testRefreshRejectsNonAllowlistedEndpointWithoutNetwork() async throws {
        let catalog = try PricingCatalogCodec.decode(try fixtureData("pricing-cache-sample.json"))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pricing-catalog.json")
        try PricingService(fetcher: MockFetcher.failing()).saveCatalog(catalog, to: path)
        // The fetcher would succeed: rejection must happen before any call.
        let payload = try fixtureData("pricing-openrouter-sample.json")
        let mock = MockFetcher(result: .success((payload, MockFetcher.okResponse())))
        let service = PricingService(fetcher: mock)
        let offAllowlist = [
            "https://evil.example.com/api/v1/models",
            "http://openrouter.ai/api/v1/models",
            "https://openrouter.ai.evil.com/api/v1/models",
            "https://openrouter.ai/other/path",
            "https://openrouter.ai/api/v1/models?foo=bar",
            "https://openrouter.ai/api/v1/models#frag",
            "https://openrouter.ai:8443/api/v1/models",
            "https://user:pass@openrouter.ai/api/v1/models",
        ]
        for raw in offAllowlist {
            let result = await service.refresh(now: now, catalogURL: URL(string: raw)!, cacheURL: path)
            XCTAssertEqual(result.status, "cached", raw)
            XCTAssertEqual(result.snapshot?.catalog.entries.count, 2, raw)
            XCTAssertTrue(result.error?.contains("not allowlisted") ?? false, raw)
        }
        XCTAssertTrue(mock.requestedURLs.isEmpty)
        // The documented default URL stays injectable and fetchable in tests.
        XCTAssertTrue(PricingService.isAllowlistedCatalogURL(PricingService.defaultCatalogURL))
        // Without a cache, rejection still falls back to static (nil).
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pricing-catalog.json")
        let offline = await service.refresh(
            now: now,
            catalogURL: URL(string: "https://evil.example.com/api/v1/models")!,
            cacheURL: bare)
        XCTAssertEqual(offline.status, "offline")
        XCTAssertNil(offline.snapshot)
        XCTAssertTrue(mock.requestedURLs.isEmpty)
    }

    // MARK: - Privacy boundary

    func testCatalogRequestSendsNoUsageOrCredentials() {
        let url = PricingService.defaultCatalogURL
        XCTAssertEqual(url.absoluteString, OpenRouterCatalog.defaultURLString)
        let request = PricingService.makeCatalogRequest(url: url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        // Serialized request carries no usage-shaped keys.
        let dump = "\(request.url?.absoluteString ?? "") \(request.allHTTPHeaderFields ?? [:])"
        for leaked in ["prompt", "token", "usage", "session", "requestId", "file"] {
            XCTAssertFalse(dump.lowercased().contains(leaked), "request leaks \(leaked): \(dump)")
        }
    }

    // MARK: - Malformed catalogs

    func testMalformedCatalogsThrowStrictly() throws {
        // Wrong version is rejected, not migrated silently.
        XCTAssertThrowsError(
            try PricingCatalogCodec.decode(try fixtureData("pricing-malformed-sample.json")))
        // Unparseable JSON is rejected.
        XCTAssertThrowsError(
            try PricingCatalogCodec.decode("not json".data(using: .utf8)!))
        XCTAssertThrowsError(
            try OpenRouterCatalog.decodeEntries(from: "not json".data(using: .utf8)!))
        // Negative rates are rejected.
        let negative = """
        {"version":1,"sourceURL":"https://openrouter.ai/api/v1/models","fetchedAt":"2026-09-11T12:00:00Z","entries":[{"model":"x/y","inputPerMTok":1.0,"outputPerMTok":1.0,"cachedPerMTok":-2.0}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try PricingCatalogCodec.decode(negative))
        // Size caps hold: an oversized payload throws instead of allocating.
        let big = try fixtureData("pricing-openrouter-sample.json")
        XCTAssertThrowsError(try OpenRouterCatalog.decodeEntries(from: big, maxModels: 0))
        let cache = try fixtureData("pricing-cache-sample.json")
        XCTAssertThrowsError(try PricingCatalogCodec.decode(cache, maxEntries: 0))
        // Empty provider payload never becomes an empty catalog write.
        let empty = #"{"data":[]}"#.data(using: .utf8)!
        XCTAssertEqual(try OpenRouterCatalog.decodeEntries(from: empty).count, 0)
    }

    // MARK: - Aggregation + report honor the snapshot

    func testAggregatorPricesFromCatalogWhenSupplied() {
        let record = NormalizedUsage(
            id: "a", source: .codex, timestamp: now,
            model: "openai/gpt-4o",
            inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0,
            reasoningTokens: 0, totalTokens: 0, sessionId: "s", requestId: "a")
        let staticCost = Aggregator.aggregate([record]).estimatedCostUSD
        XCTAssertEqual(staticCost, 2.5, accuracy: 0.0001)
        let catalog = PricingCatalog(
            sourceURL: OpenRouterCatalog.defaultURLString, fetchedAt: now,
            entries: [CatalogEntry(
                model: "openai/gpt-4o",
                inputPerMTok: 100.0, outputPerMTok: 200.0, cachedPerMTok: 50.0)])
        let dynamicCost = Aggregator.aggregate(
            [record], snapshot: CatalogSnapshot(catalog: catalog, isFresh: true)).estimatedCostUSD
        XCTAssertEqual(dynamicCost, 100.0, accuracy: 0.0001)
        // Unknown models stay visible with fallback cost, never zeroed.
        let mystery = NormalizedUsage(
            id: "b", source: .codex, timestamp: now,
            model: "mystery-model-zzz",
            inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0,
            reasoningTokens: 0, totalTokens: 0, sessionId: "s", requestId: "b")
        let section = ReportFormatter.section(
            records: [mystery], source: .all, preset: .lifetime, now: now,
            snapshot: CatalogSnapshot(catalog: catalog, isFresh: true))
        XCTAssertTrue(section.stats.byModel.contains(where: { $0.key == "mystery-model-zzz" }))
        XCTAssertGreaterThan(section.stats.estimatedCostUSD, 0)
    }

    func testReportPricingNoteLabelsSourceAndEstimate() {
        let staticNote = ReportFormatter.pricingNote(snapshot: nil)
        XCTAssertTrue(staticNote.contains("static estimates"))
        XCTAssertTrue(staticNote.contains("not a bill"))
        let catalog = PricingCatalog(
            sourceURL: OpenRouterCatalog.defaultURLString, fetchedAt: now,
            entries: [CatalogEntry(
                model: "openai/gpt-4o",
                inputPerMTok: 2.5, outputPerMTok: 10.0, cachedPerMTok: 1.25)])
        let dynamic = ReportFormatter.pricingNote(
            snapshot: CatalogSnapshot(catalog: catalog, isFresh: true))
        XCTAssertTrue(dynamic.contains("dynamic catalog"))
        XCTAssertTrue(dynamic.contains("openrouter.ai"))
        XCTAssertTrue(dynamic.contains("not a bill"))
        let cached = ReportFormatter.pricingNote(
            snapshot: CatalogSnapshot(catalog: catalog, isFresh: false),
            error: "Pricing refresh offline: unreachable.")
        XCTAssertTrue(cached.contains("cached catalog"))
        XCTAssertTrue(cached.contains("unreachable"))
        // Rendering without a note is byte-identical to the historic output.
        let section = ReportFormatter.section(records: [], source: .all, preset: .lifetime, now: now)
        XCTAssertFalse(ReportFormatter.render(section: section).contains("Pricing:"))
        XCTAssertTrue(
            ReportFormatter.render(section: section, pricingNote: dynamic).contains("Pricing: dynamic catalog"))
    }
}

// MARK: - Mock fetcher (offline only)

final class MockFetcher: PricingFetching, @unchecked Sendable {
    enum Result {
        case success((Data, URLResponse))
        case failure(Error)
    }

    private let result: Result
    private(set) var requestedURLs: [URL] = []

    init(result: Result) {
        self.result = result
    }

    static func failing() -> MockFetcher {
        MockFetcher(result: .failure(URLError(.notConnectedToInternet)))
    }

    static func okResponse(
        url: URL = URL(string: OpenRouterCatalog.defaultURLString)!,
        statusCode: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    func fetchData(from url: URL, request: URLRequest) async throws -> (Data, URLResponse) {
        requestedURLs.append(url)
        switch result {
        case .success(let pair): return pair
        case .failure(let error): throw error
        }
    }
}
