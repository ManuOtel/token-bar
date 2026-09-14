import Foundation

/// Privacy-safe startup cache for the menu-bar app.
///
/// Problem: `TokenBarApp` started with an empty `LoadReport` and scanned all
/// source histories before showing data (about 14s on a large host after the
/// parser work). Every refresh repeated the full scan.
///
/// Fix (perceived startup only): persist the last normalized `LoadReport` to
/// a small local file, load it synchronously at startup so the menu is
/// useful immediately, then run the existing full `TokenBarStore.load` in the
/// background and atomically replace the UI/cache with the fresh report.
/// First run with no cache keeps current behavior (empty + loading).
///
/// Privacy: only normalized token counts (`NormalizedUsage`), sanitized
/// counters, and sanitized warnings are cached. Prompts, message bodies,
/// tool I/O, file paths, credentials, and raw source blobs never enter the
/// envelope: warnings pass through `ReportFormatter.sanitizeWarnings`
/// before persistence, and `NormalizedUsage` carries no such fields by
/// construction. Cache lives outside the repository in
/// `Application Support/TokenBar/` and is never committed.
///
/// Robustness: corrupt, incompatible, or unreadable caches return nil and
/// the caller falls back to empty + full scan. Write failures throw so the
/// app can ignore them without breaking a successful fresh load.
public enum StartupReportCache {
    public static let currentVersion = 1
    public static let cacheFileName = "startup-report.json"

    public static var cachePathOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_STARTUP_REPORT_CACHE"]
    }

    public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        if let override = cachePathOverride, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent(cacheFileName)
    }

    /// Versioned envelope so future shapes fail closed instead of decoding
    /// garbage into the UI.
    public struct Envelope: Codable, Hashable, Sendable {
        public var version: Int
        public var savedAt: Date
        public var report: LoadReport

        public init(version: Int = currentVersion, savedAt: Date, report: LoadReport) {
            self.version = version
            self.savedAt = savedAt
            self.report = report
        }
    }

    /// Report as persisted: warnings sanitized to generic location labels.
    /// Pure for tests. Records are already normalized (counts, model/source/
    /// origin labels only); counters pass through unchanged.
    public static func sanitizedForCache(_ report: LoadReport) -> LoadReport {
        LoadReport(
            records: report.records,
            skippedCodexLines: max(0, report.skippedCodexLines),
            skippedOpenCodeRows: max(0, report.skippedOpenCodeRows),
            warnings: ReportFormatter.sanitizeWarnings(report.warnings),
            skippedClaudeLines: max(0, report.skippedClaudeLines)
        )
    }

    public static func encode(_ report: LoadReport, now: Date = Date()) throws -> Data {
        let envelope = Envelope(savedAt: now, report: sanitizedForCache(report))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// Strict decode: version must match, payload must be a well-formed
    /// envelope. Any failure throws so callers can fall back to a full scan.
    public static func decode(_ data: Data) throws -> (report: LoadReport, savedAt: Date) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw StartupReportCacheError.malformed("startup cache is not {version,savedAt,report} (\(error))")
        }
        guard envelope.version == currentVersion else {
            throw StartupReportCacheError.unsupportedVersion(envelope.version)
        }
        return (sanitizedForCache(envelope.report), envelope.savedAt)
    }

    /// Loads the cached report without touching source histories. Nil when
    /// the file is missing, corrupt, or version-incompatible: the caller
    /// keeps current empty + full-scan behavior.
    public static func load(from url: URL? = nil, fileManager: FileManager = .default) -> LoadReport? {
        let path = url ?? defaultCacheURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? decode(data).report
    }

    /// Persists the fresh report atomically. Creates parent directories.
    /// Throws on encode/write failure; callers must ignore the error so a
    /// cache write failure never breaks a successful fresh load.
    public static func save(
        _ report: LoadReport,
        to url: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        let path = url ?? defaultCacheURL(fileManager: fileManager)
        let directory = path.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encode(report, now: now)
        try data.write(to: path, options: .atomic)
    }
}

public enum StartupReportCacheError: Error, Sendable {
    case malformed(String)
    case unsupportedVersion(Int)
}

/// Generation guard for the stale-while-refresh lifecycle.
///
/// The scan runs off the main actor; completions hop back and must not let
/// a stale/late result overwrite a newer report if the UI lifecycle ever
/// starts a second scan. Each started scan owns a generation; only the
/// latest generation may clear `isLoading` and publish.
///
/// First-appearance rule lives here too: `beginInitial()` succeeds exactly
/// once per process, even when cached records exist, and `beginManual()`
/// stays blocked while a scan is in flight (the refresh button disables).
/// `beginForced()` exists for lifecycle edges that must supersede an
/// in-flight scan; the button never uses it.
public struct StartupRefreshState: Sendable {
    public var generation: Int
    public var didStartInitial: Bool
    public var isLoading: Bool

    public init(generation: Int = 0, didStartInitial: Bool = false, isLoading: Bool = false) {
        self.generation = generation
        self.didStartInitial = didStartInitial
        self.isLoading = isLoading
    }

    public mutating func beginInitial() -> Int? {
        guard !didStartInitial else { return nil }
        didStartInitial = true
        isLoading = true
        generation += 1
        return generation
    }

    public mutating func beginManual() -> Int? {
        guard !isLoading else { return nil }
        isLoading = true
        generation += 1
        return generation
    }

    public mutating func beginForced() -> Int {
        isLoading = true
        generation += 1
        return generation
    }

    /// Returns true only for the latest generation; stale completions
    /// return false and must be dropped by the caller (last-write-wins).
    public mutating func finish(generation finished: Int) -> Bool {
        guard finished == generation else { return false }
        isLoading = false
        return true
    }
}
