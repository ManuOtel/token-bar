import Foundation

/// Orchestrates both file-only adapters into one deterministic record set.
///
/// - Codex root: `TOKENBAR_CODEX_ROOT` or `~/.codex/sessions` (recursive `*.jsonl`)
/// - OpenCode DB: `TOKENBAR_OPENCODE_DB` or `~/.local/share/opencode/opencode.db`
/// - No auth, no cookies, no network. Missing roots yield zero records plus a
///   warning, never an error.
public enum TokenBarStore {
    public static var codexRootOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_CODEX_ROOT"]
    }

    public static var opencodeDBOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_OPENCODE_DB"]
    }

    public static func defaultCodexRoot(fileManager: FileManager = .default) -> URL {
        if let override = codexRootOverride, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static func defaultOpenCodeDBPath(fileManager: FileManager = .default) -> String {
        if let override = opencodeDBOverride, !override.isEmpty {
            return override
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    public static func load(
        now _: Date = Date(),
        fileManager: FileManager = .default
    ) -> LoadReport {
        var records: [NormalizedUsage] = []
        var warnings: [String] = []
        var skippedCodex = 0
        var skippedOpenCode = 0

        let codexRoot = defaultCodexRoot(fileManager: fileManager)
        if fileManager.fileExists(atPath: codexRoot.path) {
            let parsed = CodexParser.parseDirectory(root: codexRoot, fileManager: fileManager)
            records.append(contentsOf: parsed.records)
            skippedCodex = parsed.skippedLines
            if parsed.skippedLines > 0 {
                warnings.append("\(parsed.skippedLines) Codex line(s) skipped as malformed or non-usage.")
            }
        } else {
            warnings.append("Codex sessions not found at \(codexRoot.path).")
        }

        let dbPath = defaultOpenCodeDBPath(fileManager: fileManager)
        if fileManager.fileExists(atPath: dbPath) {
            do {
                let loaded = try OpenCodeStore.loadDatabase(at: dbPath)
                records.append(contentsOf: loaded.records)
                skippedOpenCode = loaded.skipped
                if loaded.skipped > 0 {
                    warnings.append("\(loaded.skipped) OpenCode row(s) skipped as undecodable.")
                }
            } catch StoreError.sqliteUnavailable {
                warnings.append("OpenCode database present but SQLite module unavailable in this build.")
            } catch {
                warnings.append("OpenCode database unreadable: \(error).")
            }
        } else {
            warnings.append("OpenCode database not found at \(dbPath).")
        }

        return LoadReport(
            records: dedupe(records),
            skippedCodexLines: skippedCodex,
            skippedOpenCodeRows: skippedOpenCode,
            warnings: warnings
        )
    }

    /// Deterministic dedupe: same source + same non-empty requestId collapses
    /// to the earliest (timestamp, id) record. Records without a requestId are
    /// unique by id and always kept. OpenCode per-session rows mirrored across
    /// `session_v2` / `session` share their session ID as the request ID (see
    /// `OpenCodeStore.decodeRow`), so each mirror pair collapses here instead
    /// of double-counting.
    public static func dedupe(_ records: [NormalizedUsage]) -> [NormalizedUsage] {
        var seen = Set<String>()
        var unique: [NormalizedUsage] = []
        for record in records.sorted(by: { $0.timestamp < $1.timestamp || ($0.timestamp == $1.timestamp && $0.id < $1.id) }) {
            if record.requestId.isEmpty {
                unique.append(record)
                continue
            }
            let key = "\(record.source.rawValue):\(record.requestId)"
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(record)
        }
        return unique.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }
}
