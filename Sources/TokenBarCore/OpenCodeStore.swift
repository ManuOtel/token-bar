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
/// counts (legacy `input_tokens` style plus current `tokens_input`,
/// `tokens_output`, `tokens_reasoning`, `tokens_cache_read`,
/// `tokens_cache_write` style with `time_created` / `time_updated` epoch
/// millis timestamps) and JSON-blob columns (`data`, `payload`, `info`,
/// `value`). The `model` column may be a JSON string like
/// `{"id": "...", "providerID": "..."}` and is reduced to a concise stable
/// label. Rows mirrored across `session_v2` / `session` collapse downstream
/// via `TokenBarStore.dedupe`: per-session rollup rows carry no per-message
/// ID, so `decodeRow` falls back to `sessionID#epochSeconds` as the request
/// ID. This assumes the mirror pair shares one row per session with the same
/// `time_created` (observed: 22 rows in each table); genuine rows for one
/// session at different timestamps keep distinct keys and are never merged.
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
            "timestamp", "time", "time_created", "timecreated", "created_at", "createdat",
            "created", "updated_at", "updatedat", "updated", "time_updated", "timeupdated",
            "createdAt", "date",
        ]))
        guard let timestamp else { return nil }

        let input = intField(merged, keys: ["input_tokens", "inputtokens", "prompt_tokens", "prompttokens", "tokens_input", "tokensinput", "input"])
        let output = intField(merged, keys: ["output_tokens", "outputtokens", "completion_tokens", "completiontokens", "tokens_output", "tokensoutput", "output"])
        let cachedRead = intField(merged, keys: ["cached_tokens", "cachedtokens", "cached_input_tokens", "cachedinputtokens", "tokens_cache_read", "tokenscacheread"])
        let cachedWrite = intField(merged, keys: ["cache_write_input_tokens", "cachewriteinputtokens", "tokens_cache_write", "tokenscachewrite"])
        let cached: Int? = {
            if cachedRead == nil && cachedWrite == nil { return nil }
            return (cachedRead ?? 0) + (cachedWrite ?? 0)
        }()
        let reasoning = intField(merged, keys: ["reasoning_tokens", "reasoningtokens", "reasoning_output_tokens", "reasoningoutputtokens", "tokens_reasoning", "tokensreasoning"])
        let total = intField(merged, keys: ["total_tokens", "totaltokens", "tokens_total", "tokenstotal", "total", "tokens"])
        guard input != nil || output != nil || cached != nil || reasoning != nil || total != nil else {
            return nil
        }

        let modelRaw = firstString(merged, keys: ["model", "model_name", "modelname", "provider_model"])
        let model = decodeModelLabel(modelRaw) ?? "unknown"
        let sessionId = firstString(merged, keys: ["session_id", "sessionid", "session", "id", "key"]) ?? ""
        var requestId = firstString(merged, keys: ["request_id", "requestid", "message_id", "messageid", "rowid"]) ?? ""
        // Per-session rollup rows carry no per-message ID and are mirrored
        // across session_v2/session (one row per session per table). Falling
        // back to sessionID#epochSeconds lets the existing source+requestId
        // dedupe collapse each mirror pair while keeping genuine rows for one
        // session at different timestamps distinct.
        if requestId.isEmpty, !sessionId.isEmpty {
            requestId = "\(sessionId)#\(Int(timestamp.timeIntervalSince1970))"
        }
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

    /// Reduces a model column value to a concise stable label. Accepts plain
    /// model names plus JSON strings like `{"id": "...", "providerID": "...",
    /// "variant": "..."}`. Prefers `providerID/id`, then `id`, then
    /// `providerID`, then `variant`. Returns nil for empty input.
    static func decodeModelLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return trimmed }
        if let name = json as? String, !name.isEmpty { return name }
        guard let dict = json as? [String: Any] else { return trimmed }
        func text(_ keys: String...) -> String? {
            for key in keys {
                if let value = dict[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        let id = text("id", "model", "modelID", "name")
        let provider = text("providerID", "providerId", "provider", "providerName")
        let variant = text("variant")
        if let provider, let id { return "\(provider)/\(id)" }
        return id ?? provider ?? variant
    }

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
