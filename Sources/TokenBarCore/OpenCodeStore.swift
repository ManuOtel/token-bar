import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

/// Adapter for the local OpenCode SQLite history.
///
/// Default path: `~/.local/share/opencode/opencode.db`
/// (override with `TOKENBAR_OPENCODE_DB`).
/// Reads `session_v2` (preferred) plus legacy `session` tables, read-only.
/// Because the schema drifts between OpenCode versions, every row is decoded
/// by the pure `decodeRow` function which accepts both column-form token
/// counts and JSON-blob columns (`data`, `payload`, `info`, `value`).
public enum OpenCodeStore {
    public static let tableNames = ["session_v2", "session"]

    /// Pure row decoder. Testable without a live SQLite file.
    /// `columns` maps lowercased column names to their string values (nil = NULL).
    /// Returns nil for rows without usable timestamp or token counts.
    public static func decodeRow(_ columns: [String: String?], table: String = "session_v2") -> NormalizedUsage? {
        var merged: [String: Any] = [:]

        // 1. Column-form token counts and metadata.
        for (key, value) in columns {
            guard let value, !value.isEmpty else { continue }
            merged[key] = value
            if let int = Int(value) { merged[key] = int }
            else if let double = Double(value) { merged[key] = double }
        }

        // 2. JSON-blob columns merged underneath explicit columns.
        for blobKey in ["data", "payload", "info", "value", "content", "meta"] {
            guard let raw = columns[blobKey] ?? nil,
                  let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (key, value) in json where merged[key.lowercased()] == nil {
                merged[key.lowercased()] = value
                merged[key] = value
            }
        }

        let timestamp = CodexParser.parseTimestamp(firstRaw(merged, keys: [
            "timestamp", "time", "created_at", "createdat", "created", "updated_at",
            "updatedat", "updated", "createdAt", "date",
        ]))
        guard let timestamp else { return nil }

        let input = intField(merged, keys: ["input_tokens", "inputtokens", "prompt_tokens", "prompttokens", "input"])
        let output = intField(merged, keys: ["output_tokens", "outputtokens", "completion_tokens", "completiontokens", "output"])
        let cached = intField(merged, keys: ["cached_tokens", "cachedtokens", "cached_input_tokens"])
        let reasoning = intField(merged, keys: ["reasoning_tokens", "reasoningtokens"])
        let total = intField(merged, keys: ["total_tokens", "totaltokens", "total", "tokens"])
        guard input != nil || output != nil || cached != nil || reasoning != nil || total != nil else {
            return nil
        }

        let model = firstString(merged, keys: ["model", "model_name", "modelname", "provider_model"]) ?? "unknown"
        let sessionId = firstString(merged, keys: ["session_id", "sessionid", "session", "id", "key"]) ?? ""
        let requestId = firstString(merged, keys: ["request_id", "requestid", "message_id", "messageid", "rowid"]) ?? ""
        let fallback = "\(table):\(sessionId.isEmpty ? UUID().uuidString : sessionId):\(Int(timestamp.timeIntervalSince1970))"
        let id = requestId.isEmpty ? "opencode:\(fallback)" : "opencode:\(requestId)"
        return NormalizedUsage(
            id: id,
            source: .opencode,
            timestamp: timestamp,
            model: model,
            inputTokens: input ?? 0,
            outputTokens: output ?? 0,
            cachedTokens: cached ?? 0,
            reasoningTokens: reasoning ?? 0,
            totalTokens: total ?? 0,
            sessionId: sessionId,
            requestId: requestId
        )
    }

    /// Loads all decodable rows from the SQLite file. Throws
    /// `StoreError.sqliteUnavailable` on platforms without the SQLite3 module.
    public static func loadDatabase(at path: String) throws -> (records: [NormalizedUsage], skipped: Int) {
#if canImport(SQLite3)
        return try sqliteLoad(path: path)
#else
        throw StoreError.sqliteUnavailable
#endif
    }

    // MARK: - Private helpers

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key.lowercased()] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func firstRaw(_ dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] { return value }
            if let value = dict[key.lowercased()] { return value }
        }
        return nil
    }

    private static func intField(_ dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            for variant in [key, key.lowercased()] {
                guard let raw = dict[variant] else { continue }
                if raw is Bool { continue }
                if let number = raw as? NSNumber, String(cString: number.objCType) == "c" { continue }
                if let int = raw as? Int { return int }
                if let double = raw as? Double { return Int(double) }
                if let number = raw as? NSNumber { return number.intValue }
                if let string = raw as? String {
                    if let parsed = Int(string) { return parsed }
                    if let parsed = Double(string) { return Int(parsed) }
                }
            }
        }
        return nil
    }

#if canImport(SQLite3)
    private static func sqliteLoad(path: String) throws -> (records: [NormalizedUsage], skipped: Int) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw StoreError.sqliteOpenFailed(path)
        }
        defer { sqlite3_close(db) }

        var records: [NormalizedUsage] = []
        var skipped = 0
        for table in tableNames {
            var stmt: OpaquePointer?
            let sql = "SELECT * FROM \"\(table)\""
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                continue // missing table: skip gracefully
            }
            let columnCount = Int(sqlite3_column_count(stmt))
            var names: [String] = []
            for index in 0..<columnCount {
                guard let namePtr = sqlite3_column_name(stmt, Int32(index)) else { continue }
                names.append(String(cString: namePtr).lowercased())
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                var columns: [String: String?] = [:]
                for (index, name) in names.enumerated() {
                    if sqlite3_column_type(stmt, Int32(index)) == SQLITE_NULL {
                        columns[name] = nil
                    } else if let text = sqlite3_column_text(stmt, Int32(index)) {
                        columns[name] = String(cString: text)
                    } else {
                        columns[name] = nil
                    }
                }
                if let record = decodeRow(columns, table: table) {
                    records.append(record)
                } else {
                    skipped += 1
                }
            }
            sqlite3_finalize(stmt)
        }
        return (records, skipped)
    }
#endif
}
