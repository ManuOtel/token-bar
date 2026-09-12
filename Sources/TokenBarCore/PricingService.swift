import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Privacy boundary: this is the ONLY type in the codebase allowed to touch
/// the network, and it only ever issues one request: `GET` against the public
/// model/pricing metadata catalog (default OpenRouter `/api/v1/models`).
/// It never sends prompts, token counts, file paths, credentials, cookies,
/// or usage records. The request carries no body, no query items, no
/// `Authorization`/`Cookie` headers -- just `Accept: application/json`.
/// See `makeCatalogRequest(url:)` (pure, unit-tested) and `docs/PRICING.md`.
public protocol PricingFetching: Sendable {
    func fetchData(from url: URL, request: URLRequest) async throws -> (Data, URLResponse)
}

/// Live `URLSession` fetcher with bounded timeouts. Size caps are enforced
/// by `PricingService` after the body arrives.
public struct URLSessionPricingFetcher: PricingFetching {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = PricingService.requestTimeout) {
        self.timeout = timeout
    }

    public func fetchData(from url: URL, request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        return try await session.data(for: request)
    }
}

public struct PricingRefreshResult: Sendable {
    public var snapshot: CatalogSnapshot?
    /// Machine-readable status: `dynamic`, `cached`, or `offline`.
    public var status: String
    /// User-visible one-liner, already free of paths and usage data.
    public var message: String
    public var error: String?

    public init(snapshot: CatalogSnapshot?, status: String, message: String, error: String? = nil) {
        self.snapshot = snapshot
        self.status = status
        self.message = message
        self.error = error
    }
}

/// Async, cancellable dynamic-pricing refresh with on-disk cache.
///
/// - Offline-first: every read path works with no network. `refresh()` is
///   the only network call and is always user-initiated (app button, CLI
///   `--refresh-pricing`); usage loading never blocks on it.
/// - Cancellable: `refresh()` checks `Task.isCancelled` before persisting
///   and `URLSession.data(for:)` cancels with the surrounding `Task`.
/// - Bounded: 15s request timeout, 5MB response cap, 10k-model decode cap.
/// - Cache: `Library/Application Support/TokenBar/pricing-catalog.json`
///   (override `TOKENBAR_PRICING_CACHE` in tests), with `fetchedAt` age
///   metadata. Malformed caches are ignored with an offline message, never
///   fatal.
///
/// `Sendable` is unchecked but sound: all state is set at init and refresh
/// paths mutate nothing shared (each refresh uses local values plus the
/// atomic file write).
public final class PricingService: @unchecked Sendable {
    public static let requestTimeout: TimeInterval = 15
    public static let maxResponseBytes = 5 * 1024 * 1024
    public static let cacheFileName = "pricing-catalog.json"

    public static var cachePathOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_PRICING_CACHE"]
    }

    public static var defaultCatalogURL: URL {
        URL(string: OpenRouterCatalog.defaultURLString)!
    }

    /// Allowlisted refresh endpoint, checked before any network call.
    /// Exactly `https://openrouter.ai/api/v1/models` with no query,
    /// fragment, port, or user info. Anything else is rejected and falls
    /// back to cache/static, so no override path can redirect the single
    /// outbound GET at runtime.
    public static func isAllowlistedCatalogURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), host == "openrouter.ai" else { return false }
        guard url.port == nil, url.user == nil, url.password == nil else { return false }
        guard url.path == "/api/v1/models" else { return false }
        guard url.query == nil, url.fragment == nil else { return false }
        return true
    }

    private let fetcher: any PricingFetching
    private let fileManager: FileManager

    public init(fetcher: (any PricingFetching)? = nil, fileManager: FileManager = .default) {
        self.fetcher = fetcher ?? URLSessionPricingFetcher()
        self.fileManager = fileManager
    }

    // MARK: - Pure request builder (privacy-audited)

    /// The single outbound request shape. GET, no body, no query items, no
    /// auth/cookie headers. Unit tests pin this: any added header, query
    /// item, or body fails `testCatalogRequestSendsNoUsageOrCredentials`.
    public static func makeCatalogRequest(url: URL) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Cache paths

    public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        if let override = cachePathOverride, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent(cacheFileName)
    }

    public func cacheURL() -> URL {
        Self.defaultCacheURL(fileManager: fileManager)
    }

    /// Loads the on-disk cache without touching the network. Nil when the
    /// file is missing or malformed (caller falls back to static pricing).
    public func loadCachedCatalog(now: Date = Date(), from url: URL? = nil) -> CatalogSnapshot? {
        let path = url ?? cacheURL()
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let catalog = try? PricingCatalogCodec.decode(data) else { return nil }
        return CatalogSnapshot(
            catalog: catalog,
            isFresh: PricingFreshness.isFresh(fetchedAt: catalog.fetchedAt, now: now))
    }

    public func saveCatalog(_ catalog: PricingCatalog, to url: URL? = nil) throws {
        let path = url ?? cacheURL()
        let directory = path.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PricingCatalogCodec.encode(catalog)
        try data.write(to: path, options: .atomic)
    }

    // MARK: - Refresh (the only network call)

    /// Fetches the public catalog, persists it, and returns a fresh snapshot.
    /// On any failure (offline, timeout, malformed payload, cancellation)
    /// returns the on-disk cache when available, else nil -- usage loading
    /// must never break because pricing failed.
    public func refresh(
        now: Date = Date(),
        catalogURL: URL? = nil,
        cacheURL: URL? = nil
    ) async -> PricingRefreshResult {
        let endpoint = catalogURL ?? Self.defaultCatalogURL
        let destination = cacheURL ?? self.cacheURL()
        // Privacy gate: reject before any network call. Tests inject the
        // documented default URL with MockFetcher; anything off-allowlist
        // keeps offline fallback behavior (cache, then static).
        guard Self.isAllowlistedCatalogURL(endpoint) else {
            return offlineResult(
                now: now, from: destination,
                error: "Pricing endpoint not allowlisted; kept previous rates.")
        }
        let request = Self.makeCatalogRequest(url: endpoint)
        let data: Data
        do {
            let (fetched, response) = try await fetcher.fetchData(from: endpoint, request: request)
            if Task.isCancelled { return offlineResult(now: now, from: destination, error: "Pricing refresh cancelled.") }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return offlineResult(now: now, from: destination, error: "Pricing server returned status \(http.statusCode).")
            }
            guard fetched.count <= Self.maxResponseBytes else {
                return offlineResult(now: now, from: destination, error: "Pricing payload too large (\(fetched.count) bytes).")
            }
            data = fetched
        } catch is CancellationError {
            return offlineResult(now: now, from: destination, error: "Pricing refresh cancelled.")
        } catch {
            return offlineResult(now: now, from: destination, error: "Pricing refresh offline: \(Self.sanitizedError(error)).")
        }
        let entries: [CatalogEntry]
        do {
            entries = try OpenRouterCatalog.decodeEntries(from: data)
        } catch {
            return offlineResult(now: now, from: destination, error: "Pricing payload malformed; kept previous rates.")
        }
        guard !entries.isEmpty else {
            return offlineResult(now: now, from: destination, error: "Pricing payload empty; kept previous rates.")
        }
        if Task.isCancelled { return offlineResult(now: now, from: destination, error: "Pricing refresh cancelled.") }
        let catalog = PricingCatalog(
            sourceURL: endpoint.absoluteString, fetchedAt: now, entries: entries)
        do {
            try saveCatalog(catalog, to: destination)
        } catch {
            // Cache write failure is non-fatal: the fresh snapshot still counts.
            return PricingRefreshResult(
                snapshot: CatalogSnapshot(catalog: catalog, isFresh: true),
                status: "dynamic",
                message: "Pricing updated from catalog; cache write skipped.")
        }
        return PricingRefreshResult(
            snapshot: CatalogSnapshot(catalog: catalog, isFresh: true),
            status: "dynamic",
            message: "Pricing updated from \(Self.shortHost(endpoint)) (\(entries.count) models).")
    }

    // MARK: - Private

    private func offlineResult(now: Date, from url: URL, error: String) -> PricingRefreshResult {
        if let cached = loadCachedCatalog(now: now, from: url) {
            return PricingRefreshResult(
                snapshot: cached, status: "cached",
                message: "Pricing offline; using cached catalog.",
                error: error)
        }
        return PricingRefreshResult(
            snapshot: nil, status: "offline",
            message: "Pricing offline; using static estimates.",
            error: error)
    }

    /// Host-only error text: never interpolates absolute paths, counts, or
    /// payload bytes beyond the coarse size already reported above.
    static func sanitizedError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? "timed out" : "unreachable"
        }
        return "unreachable"
    }

    static func shortHost(_ url: URL) -> String {
        url.host ?? "catalog"
    }
}
