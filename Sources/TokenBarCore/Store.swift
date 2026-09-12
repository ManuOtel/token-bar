import Foundation

/// Orchestrates the three file-only adapters into one deterministic record set.
///
/// - Codex root: `TOKENBAR_CODEX_ROOT` or `~/.codex/sessions` (recursive `*.jsonl`)
/// - OpenCode DB: `TOKENBAR_OPENCODE_DB` or `~/.local/share/opencode/opencode.db`
///   (per-message `message` / `session_message` tables win where present;
///   per-session `session_v2` / `session` rollups fill uncovered sessions only)
/// - OpenCode extras (offline multi-machine merge, no network):
///   `TOKENBAR_OPENCODE_DB_EXTRA` (comma- or colon-separated read-only DB
///   paths, origin `"homeserver"`) plus `TOKENBAR_OPENCODE_USAGE_JSON`
///   (comma- or colon-separated sanitized snapshot paths as written by
///   `scripts/export-opencode-usage.py`). Empty entries are ignored. Missing
///   extras are warnings only and never stop Codex/Claude/local usage.
///   With only `TOKENBAR_OPENCODE_DB` set, behavior is exactly as before.
/// - Claude root: `TOKENBAR_CLAUDE_ROOT` or `~/.claude/projects` (recursive `*.jsonl`)
/// - No auth, no cookies, no network. Missing roots yield zero records plus a
///   warning, never an error.
///
/// Identity rules (no double counting):
/// - Records merge first, then one global `dedupe` runs: same
///   `source + requestId` collapses to the larger `totalTokens` (stale mirror
///   never shadows fresh data); exact ties break to the earliest
///   `(timestamp, id)` so repeated loads agree byte-for-byte. Records with an
///   empty `requestId` are unique by `id`: identical id-less clones collapse,
///   distinct id-less rows stay distinct.
/// - Within OpenCode, message rows win everywhere they exist: all message and
///   rollup parts from the local DB plus every extra DB are combined in one
///   global `combineMessageAndRollup`, and snapshot records rejoin that
///   combine via the `sessionID#epochSeconds` rollup heuristic (rollup IDs
///   contain `#`, message IDs never do). Rollups for sessions covered by any
///   message row are dropped, so covered sessions are never summed twice.
public enum TokenBarStore {
    public static var codexRootOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_CODEX_ROOT"]
    }

    public static var opencodeDBOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_OPENCODE_DB"]
    }

    public static var claudeRootOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_CLAUDE_ROOT"]
    }

    public static var opencodeDBExtraRaw: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_OPENCODE_DB_EXTRA"]
    }

    public static var opencodeUsageJSONRaw: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_OPENCODE_USAGE_JSON"]
    }

    /// Splits a multi-path env var on commas, colons, and newlines, trims
    /// whitespace, and drops empty entries. Public for tests.
    public static func splitExtraList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let separators = CharacterSet(charactersIn: ",:\n;")
        return raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static var opencodeDBExtraPaths: [String] {
        splitExtraList(opencodeDBExtraRaw)
    }

    public static var opencodeUsageJSONPaths: [String] {
        splitExtraList(opencodeUsageJSONRaw)
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

    public static func defaultClaudeRoot(fileManager: FileManager = .default) -> URL {
        if let override = claudeRootOverride, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static func load(
        now _: Date = Date(),
        fileManager: FileManager = .default
    ) -> LoadReport {
        var codexRecords: [NormalizedUsage] = []
        var claudeRecords: [NormalizedUsage] = []
        var warnings: [String] = []
        var skippedCodex = 0
        var skippedOpenCode = 0
        var skippedClaude = 0

        let codexRoot = defaultCodexRoot(fileManager: fileManager)
        if fileManager.fileExists(atPath: codexRoot.path) {
            let parsed = CodexParser.parseDirectory(root: codexRoot, fileManager: fileManager)
            codexRecords.append(contentsOf: parsed.records)
            skippedCodex = parsed.skippedLines
            if parsed.skippedLines > 0 {
                warnings.append("\(parsed.skippedLines) Codex line(s) skipped as malformed or non-usage.")
            }
        } else {
            warnings.append("Codex sessions not found at \(codexRoot.path).")
        }

        // OpenCode: collect message/rollup parts from every DB input plus
        // every sanitized snapshot, then one global combine so covered
        // sessions never double count across origins.
        var allMessages: [NormalizedUsage] = []
        var allRollups: [NormalizedUsage] = []
        let dbPath = defaultOpenCodeDBPath(fileManager: fileManager)
        if fileManager.fileExists(atPath: dbPath) {
            do {
                let parts = try OpenCodeStore.loadDatabaseParts(at: dbPath, origin: "local")
                allMessages.append(contentsOf: parts.messages)
                allRollups.append(contentsOf: parts.rollups)
                skippedOpenCode += parts.skipped
            } catch StoreError.sqliteUnavailable {
                warnings.append("OpenCode database present but SQLite module unavailable in this build.")
            } catch {
                warnings.append("OpenCode database unreadable: \(error).")
            }
        } else {
            warnings.append("OpenCode database not found at \(dbPath).")
        }

        for extra in opencodeDBExtraPaths {
            if fileManager.fileExists(atPath: extra) {
                do {
                    let parts = try OpenCodeStore.loadDatabaseParts(at: extra, origin: "homeserver")
                    allMessages.append(contentsOf: parts.messages)
                    allRollups.append(contentsOf: parts.rollups)
                    skippedOpenCode += parts.skipped
                } catch StoreError.sqliteUnavailable {
                    warnings.append("OpenCode extra database skipped: SQLite module unavailable in this build.")
                } catch {
                    warnings.append("OpenCode extra database unreadable; others still load.")
                }
            } else {
                warnings.append("OpenCode extra database not found (checked TOKENBAR_OPENCODE_DB_EXTRA).")
            }
        }

        for snapshot in opencodeUsageJSONPaths {
            if fileManager.fileExists(atPath: snapshot) {
                do {
                    let loaded = try OpenCodeStore.loadSnapshot(at: snapshot, originFallback: "homeserver")
                    skippedOpenCode += loaded.skipped
                    for record in loaded.records {
                        if record.requestId.isEmpty || OpenCodeStore.isRollupRecord(record) {
                            if record.requestId.isEmpty {
                                allMessages.append(record)
                            } else {
                                allRollups.append(record)
                            }
                        } else {
                            allMessages.append(record)
                        }
                    }
                    if loaded.sawExtraFields {
                        warnings.append("OpenCode snapshot contained extra non-token fields (ignored).")
                    }
                } catch {
                    warnings.append("OpenCode snapshot unreadable; others still load.")
                }
            } else {
                warnings.append("OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON).")
            }
        }

        if skippedOpenCode > 0 {
            warnings.append("\(skippedOpenCode) OpenCode row(s) skipped as undecodable.")
        }
        let openCodeRecords = OpenCodeStore.combineMessageAndRollup(messages: allMessages, rollups: allRollups)

        let claudeRoot = defaultClaudeRoot(fileManager: fileManager)
        if fileManager.fileExists(atPath: claudeRoot.path) {
            let parsed = ClaudeParser.parseDirectory(root: claudeRoot, fileManager: fileManager)
            claudeRecords.append(contentsOf: parsed.records)
            skippedClaude = parsed.skippedLines
            if parsed.skippedLines > 0 {
                warnings.append("\(parsed.skippedLines) Claude line(s) skipped as malformed or non-usage.")
            }
        } else {
            warnings.append("Claude sessions not found at \(claudeRoot.path).")
        }

        let records = dedupe(codexRecords + openCodeRecords + claudeRecords)
        return LoadReport(
            records: records,
            skippedCodexLines: skippedCodex,
            skippedOpenCodeRows: skippedOpenCode,
            warnings: warnings,
            skippedClaudeLines: skippedClaude
        )
    }

    /// Deterministic dedupe across origins: same `source + requestId`
    /// collapses to the larger `totalTokens` (max-total mirror selection);
    /// exact ties break to the earliest `(timestamp, id)` so repeated loads
    /// agree. Records without a `requestId` collapse by `source + id`:
    /// cloned id-less snapshot rows (identical stable IDs) count once, while
    /// distinct id-less rows (distinct content hashes) all survive.
    /// OpenCode per-session rows mirrored across `session_v2` / `session`
    /// share a `sessionID#epochSeconds` fallback request ID (see
    /// `OpenCodeStore.decodeRow`), so each mirror pair collapses here while
    /// rows at different timestamps stay distinct.
    public static func dedupe(_ records: [NormalizedUsage]) -> [NormalizedUsage] {
        var bestRequest: [String: NormalizedUsage] = [:]
        var bestIdOnly: [String: NormalizedUsage] = [:]
        var idOnlyOrder: [String] = []
        for record in records {
            if record.requestId.isEmpty {
                let key = "\(record.source.rawValue):\(record.id)"
                if let seen = bestIdOnly[key] {
                    bestIdOnly[key] = mirrorWinner(seen, record)
                } else {
                    bestIdOnly[key] = record
                    idOnlyOrder.append(key)
                }
                continue
            }
            let key = "\(record.source.rawValue):\(record.requestId)"
            if let seen = bestRequest[key] {
                bestRequest[key] = mirrorWinner(seen, record)
            } else {
                bestRequest[key] = record
            }
        }
        return (Array(bestRequest.values) + idOnlyOrder.compactMap { bestIdOnly[$0] }).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    /// Shared winner rule: larger `totalTokens` wins so a stale mirror never
    /// shadows fresh data; exact ties break to the earliest
    /// `(timestamp, id)`. Order-independent.
    static func mirrorWinner(_ seen: NormalizedUsage, _ candidate: NormalizedUsage) -> NormalizedUsage {
        if candidate.totalTokens != seen.totalTokens {
            return candidate.totalTokens > seen.totalTokens ? candidate : seen
        }
        return (candidate.timestamp, candidate.id) < (seen.timestamp, seen.id) ? candidate : seen
    }
}
