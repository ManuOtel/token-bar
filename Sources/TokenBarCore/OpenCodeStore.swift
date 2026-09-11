import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

/// Adapter for the local OpenCode SQLite history.
///
/// Default path: `~/.local/share/opencode/opencode.db`
/// (override with `TOKENBAR_OPENCODE_DB`).
///
/// Two granularities exist in the wild and both are read, read-only:
///
/// - Per-message tables `message` (current) and `session_message` (older
///   name): one row per assistant message with nested token usage
///   (`data.tokens`: `input`, `output`, `reasoning`,
///   `cache.read`/`cache.write`, optional `total`), per-message timestamps
///   (`data.time.created`), and model identity as flat `modelID` /
///   `providerID` columns-or-keys or a nested `model` object. Only
///   assistant rows become records; user/synthetic/compaction rows are
///   skipped and counted. Message rows are authoritative: per-message
///   timestamps attribute usage to the day it happened (a session created
///   weeks ago can still carry yesterday's tokens), and per-message models
///   attribute cost to the model that spent them.
/// - Per-session rollup tables `session_v2` (preferred) plus legacy
///   `session`: one row per session with cumulative `tokens_*` columns
///   dated at session creation. These are a fallback only: a rollup row is
///   kept solely for sessions with zero message rows, so rollup/session
///   double counting is impossible by construction.
///
/// Because the schema drifts between OpenCode versions, every row is decoded
/// by the pure `decodeRow` (rollups) / `decodeMessageRow` (messages)
/// functions. The schema stores `tokens_input` separately from
/// `tokens_cache_read`/`tokens_cache_write`, so the normalized input folds
/// cache back in (`tokens_input + cache_read + cache_write`) and the total
/// fallback includes cached usage. Rows mirrored across `session_v2` /
/// `session` collapse downstream via `TokenBarStore.dedupe`: per-session
/// rollup rows carry no per-message ID, so `decodeRow` falls back to
/// `sessionID#epochSeconds` as the request ID. This assumes the mirror pair
/// shares one row per session with the same `time_created` (observed: 22
/// rows in each table); genuine rows for one session at different
/// timestamps keep distinct keys and are never merged. Message rows carry
/// stable message IDs shared across the `message` / `session_message`
/// mirror pair, so the same dedupe collapses them too.
///
/// Privacy: only token counts, timestamps, model labels, and session /
/// message IDs are extracted. Prompt text, tool input/output, reasoning
/// text, file paths (`data.path`, `data.content[*]`), and credentials are
/// never read into records and never reach reports or the UI.
public enum OpenCodeStore {
    /// Per-session rollup tables (fallback granularity).
    public static let tableNames = ["session_v2", "session"]
    /// Per-message tables (authoritative granularity).
    public static let messageTableNames = ["message", "session_message"]

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

        let rawInput = intField(merged, keys: ["input_tokens", "inputtokens", "prompt_tokens", "prompttokens", "tokens_input", "tokensinput", "input"])
        let output = intField(merged, keys: ["output_tokens", "outputtokens", "completion_tokens", "completiontokens", "tokens_output", "tokensoutput", "output"])
        let cachedRead = intField(merged, keys: ["cached_tokens", "cachedtokens", "cached_input_tokens", "cachedinputtokens", "tokens_cache_read", "tokenscacheread"])
        let cachedWrite = intField(merged, keys: ["cache_write_input_tokens", "cachewriteinputtokens", "tokens_cache_write", "tokenscachewrite"])
        let cached: Int? = {
            if cachedRead == nil && cachedWrite == nil { return nil }
            return (cachedRead ?? 0) + (cachedWrite ?? 0)
        }()
        // Official OpenCode schema stores tokens_input separately from
        // tokens_cache_read/write, so the normalized input folds cache back
        // in. This keeps cached a true subset of input and lets the total
        // fallback (normalized input + output) include cached usage.
        // (Codex needs no such fold: its payload.usage input already
        // includes cached input.)
        let input: Int? = {
            if rawInput == nil && cached == nil { return nil }
            return (rawInput ?? 0) + (cached ?? 0)
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

    /// Pure decoder for per-message rows (`message` / `session_message`).
    /// `columns` maps lowercased column names to their string values
    /// (nil = NULL). Returns nil for non-assistant rows, rows without
    /// usable timestamp or token counts, and all-zero rows (final empty
    /// assistant messages carry no usage and must not inflate request
    /// counts).
    ///
    /// Real shapes handled (observed on a live database, sanitized):
    /// `data` JSON `{"role":"assistant","tokens":{"input":N,"output":N,
    /// "reasoning":N,"cache":{"read":N,"write":N},"total":N},
    /// "time":{"created":epochMillis},"modelID":"...","providerID":"..."}`
    /// (current `message` table, flat model IDs) or the same with a nested
    /// `"model":{"id":"...","providerID":"..."}` object and a `type`
    /// column == `assistant` (older `session_message` table). Like the
    /// rollup path, nested `tokens.input` excludes cache, so normalized
    /// input folds cache back in and the total fallback includes it.
    public static func decodeMessageRow(_ columns: [String: String?], table: String = "message") -> NormalizedUsage? {
        // 1. Decode the data blob first (never retained, only projected).
        var data: [String: Any] = [:]
        if let raw = columns["data"] ?? nil,
           let blob = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any]
        {
            data = json
        }

        // 2. Role gate: only assistant rows carry usage. User, synthetic,
        // and compaction rows are skipped. A missing role falls through to
        // the token check (schema drift tolerance); a present non-assistant
        // role is rejected.
        let columnType = stringColumn(columns, keys: ["type", "role"])
        let dataRole = dataString(data, keys: ["role", "type"])
        if let role = columnType ?? dataRole, !role.isEmpty {
            guard role.lowercased().contains("assistant") else { return nil }
        }

        // 3. Token counts: nested data.tokens first, flat columns as drift
        // fallback.
        let tokens = data["tokens"] as? [String: Any]
        let cache = tokens?["cache"] as? [String: Any]
        let nestedInput = intValue(tokens, keys: ["input", "input_tokens", "tokens_input"])
        let nestedOutput = intValue(tokens, keys: ["output", "output_tokens", "tokens_output"])
        let nestedReasoning = intValue(tokens, keys: ["reasoning", "reasoning_tokens", "tokens_reasoning"])
        let nestedCacheRead = intValue(cache, keys: ["read", "input_tokens", "tokens_cache_read"])
        let nestedCacheWrite = intValue(cache, keys: ["write", "tokens_cache_write"])
        let nestedTotal = intValue(tokens, keys: ["total", "total_tokens", "tokens_total"])

        let flatInput = intColumn(columns, data: data, keys: ["input_tokens", "inputtokens", "prompt_tokens", "prompttokens", "tokens_input", "tokensinput", "input"])
        let flatOutput = intColumn(columns, data: data, keys: ["output_tokens", "outputtokens", "completion_tokens", "completiontokens", "tokens_output", "tokensoutput", "output"])
        let flatCacheRead = intColumn(columns, data: data, keys: ["cached_tokens", "cachedtokens", "cached_input_tokens", "cachedinputtokens", "tokens_cache_read", "tokenscacheread"])
        let flatCacheWrite = intColumn(columns, data: data, keys: ["cache_write_input_tokens", "cachewriteinputtokens", "tokens_cache_write", "tokenscachewrite"])
        let flatReasoning = intColumn(columns, data: data, keys: ["reasoning_tokens", "reasoningtokens", "reasoning_output_tokens", "reasoningoutputtokens", "tokens_reasoning", "tokensreasoning"])
        let flatTotal = intColumn(columns, data: data, keys: ["total_tokens", "totaltokens", "tokens_total", "tokenstotal", "total", "tokens"])

        let rawInput = nestedInput ?? flatInput
        let output = nestedOutput ?? flatOutput
        let cacheRead = nestedCacheRead ?? flatCacheRead
        let cacheWrite = nestedCacheWrite ?? flatCacheWrite
        let cached: Int? = {
            if cacheRead == nil && cacheWrite == nil { return nil }
            return (cacheRead ?? 0) + (cacheWrite ?? 0)
        }()
        let input: Int? = {
            if rawInput == nil && cached == nil { return nil }
            return (rawInput ?? 0) + (cached ?? 0)
        }()
        let reasoning = nestedReasoning ?? flatReasoning
        let total = nestedTotal ?? flatTotal
        guard input != nil || output != nil || cached != nil || reasoning != nil || total != nil else {
            return nil
        }

        // 4. Timestamp: nested data.time.created first (epoch millis), then
        // flat time_created-style columns/keys.
        let time = data["time"] as? [String: Any]
        let timestamp = CodexParser.parseTimestamp(timeRaw(time, keys: ["created", "completed", "updated"]))
            ?? CodexParser.parseTimestamp(firstRaw(data, keys: [
                "timestamp", "time", "time_created", "timecreated", "created_at", "createdat",
                "created", "updated_at", "updatedat", "updated", "time_updated", "timeupdated",
                "createdAt", "date",
            ]))
            ?? CodexParser.parseTimestamp(stringColumn(columns, keys: [
                "time_created", "timecreated", "created_at", "createdat", "created",
                "time_updated", "timeupdated", "updated_at", "updatedat", "updated",
                "timestamp", "time",
            ]))
        guard let timestamp else { return nil }

        // 5. Model: flat modelID + providerID wins ("provider/id"), then a
        // nested model object, then a model JSON string or plain name.
        let flatModelId = dataString(data, keys: ["modelID", "modelId", "model_id"])
            ?? stringColumn(columns, keys: ["modelid", "model_id"])
        let flatProvider = dataString(data, keys: ["providerID", "providerId", "provider_id", "provider"])
            ?? stringColumn(columns, keys: ["providerid", "provider_id", "provider"])
        let model: String = {
            if let id = flatModelId, !id.isEmpty {
                if let provider = flatProvider, !provider.isEmpty { return "\(provider)/\(id)" }
                return id
            }
            if let nested = data["model"] as? [String: Any] {
                let id = dataString(nested, keys: ["id", "model", "modelID", "name"])
                let provider = dataString(nested, keys: ["providerID", "providerId", "provider", "providerName"])
                if let provider, let id, !provider.isEmpty, !id.isEmpty { return "\(provider)/\(id)" }
                if let id, !id.isEmpty { return id }
                if let provider, !provider.isEmpty { return provider }
            }
            if let raw = dataString(data, keys: ["model", "model_name", "modelname"])
                ?? stringColumn(columns, keys: ["model", "model_name", "modelname", "provider_model"]),
               !raw.isEmpty
            {
                return decodeModelLabel(raw) ?? "unknown"
            }
            return "unknown"
        }()

        let sessionId = stringColumn(columns, keys: ["session_id", "sessionid", "session"])
            ?? dataString(data, keys: ["session_id", "sessionId", "sessionid", "session"]) ?? ""
        // Stable message identity shared across the message /
        // session_message mirror pair, so downstream dedupe collapses each
        // pair while distinct messages stay distinct.
        let messageId = dataString(data, keys: ["id", "message_id", "messageid", "messageId"])
            ?? stringColumn(columns, keys: ["id", "message_id", "messageid"]) ?? ""
        let requestId = messageId
        let fallback = "\(table):\(messageId.isEmpty ? (sessionId.isEmpty ? UUID().uuidString : sessionId) : messageId):\(Int(timestamp.timeIntervalSince1970))"
        let id = "opencode:\(fallback)"

        let record = NormalizedUsage(
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
        // All-zero assistant rows (final empty messages) carry no usage;
        // skipping them keeps request counts meaningful.
        guard record.totalTokens > 0 || record.inputTokens > 0 || record.outputTokens > 0
            || record.cachedTokens > 0 || record.reasoningTokens > 0
        else { return nil }
        return record
    }

    /// Merges message-level and rollup records without double counting.
    /// Message rows win everywhere they exist; rollup rows fill only
    /// sessions with zero message rows (legacy databases, or sessions whose
    /// messages were compacted away). Mirror pairs on either level collapse
    /// via the shared request-ID scheme (see `decodeRow` /
    /// `decodeMessageRow`); when rollup mirrors disagree on totals (stale
    /// `session_v2` vs fresher `session`), the larger total wins so stale
    /// data never shadows fresh data.
    public static func combineMessageAndRollup(
        messages: [NormalizedUsage],
        rollups: [NormalizedUsage]
    ) -> [NormalizedUsage] {
        let covered = Set(messages.map(\.sessionId).filter { !$0.isEmpty })
        var bestRollup: [String: NormalizedUsage] = [:]
        for rollup in rollups {
            if !covered.isEmpty, !rollup.sessionId.isEmpty, covered.contains(rollup.sessionId) { continue }
            let key = rollup.requestId.isEmpty ? rollup.id : "opencode:\(rollup.requestId)"
            if let seen = bestRollup[key] {
                if rollup.totalTokens > seen.totalTokens { bestRollup[key] = rollup }
            } else {
                bestRollup[key] = rollup
            }
        }
        return messages + bestRollup.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
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
                // Reject JSON booleans by objCType, never via `raw is Bool`:
                // on Darwin every NSNumber holding 0/1 bridges as Bool, so
                // the `is` gate wrongly rejects valid small counts (Mac CI).
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

    /// String column lookup for message rows (columns arrive lowercased from
    /// the loader). Empty strings count as missing.
    private static func stringColumn(_ columns: [String: String?], keys: [String]) -> String? {
        for key in keys {
            for variant in [key, key.lowercased()] {
                if let value = columns[variant] ?? nil, !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Case-sensitive key lookup inside a decoded JSON object (JSON keys
    /// keep their original case: `modelID`, `providerID`, `sessionId`).
    private static func dataString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func timeRaw(_ dict: [String: Any]?, keys: [String]) -> Any? {
        guard let dict else { return nil }
        for key in keys {
            if let value = dict[key] { return value }
        }
        return nil
    }

    /// Integer lookup inside a decoded JSON object. Case-sensitive keys
    /// plus string-number tolerance; JSON booleans never count.
    private static func intValue(_ dict: [String: Any]?, keys: [String]) -> Int? {
        guard let dict else { return nil }
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let number = raw as? NSNumber, String(cString: number.objCType) == "c" { continue }
            if let int = raw as? Int { return int }
            if let double = raw as? Double { return Int(double) }
            if let number = raw as? NSNumber { return number.intValue }
            if let string = raw as? String {
                if let parsed = Int(string) { return parsed }
                if let parsed = Double(string) { return Int(parsed) }
            }
        }
        return nil
    }

    /// Integer lookup across flat string columns plus decoded blob keys.
    private static func intColumn(_ columns: [String: String?], data: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            for variant in [key, key.lowercased()] {
                if let value = columns[variant] ?? nil {
                    if let parsed = Int(value) { return parsed }
                    if let parsed = Double(value) { return Int(parsed) }
                }
                if let hit = intValue(data, keys: [variant]) { return hit }
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

        var messages: [NormalizedUsage] = []
        var rollups: [NormalizedUsage] = []
        var skipped = 0
        for table in messageTableNames {
            let (records, tableSkipped) = loadTable(db: db, table: table) {
                decodeMessageRow($0, table: $1)
            }
            messages.append(contentsOf: records)
            skipped += tableSkipped
        }
        for table in tableNames {
            let (records, tableSkipped) = loadTable(db: db, table: table) {
                decodeRow($0, table: $1)
            }
            rollups.append(contentsOf: records)
            skipped += tableSkipped
        }
        // Message rows win where they exist; rollups fill uncovered
        // sessions only, so the two levels never double count.
        return (combineMessageAndRollup(messages: messages, rollups: rollups), skipped)
    }

    private static func loadTable(
        db: OpaquePointer,
        table: String,
        decode: ([String: String?], String) -> NormalizedUsage?
    ) -> (records: [NormalizedUsage], skipped: Int) {
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM \"\(table)\""
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return ([], 0) // missing table: skip gracefully
        }
        defer { sqlite3_finalize(stmt) }
        let columnCount = Int(sqlite3_column_count(stmt))
        var names: [String] = []
        for index in 0..<columnCount {
            guard let namePtr = sqlite3_column_name(stmt, Int32(index)) else { continue }
            names.append(String(cString: namePtr).lowercased())
        }
        var records: [NormalizedUsage] = []
        var skipped = 0
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
            if let record = decode(columns, table) {
                records.append(record)
            } else {
                skipped += 1
            }
        }
        return (records, skipped)
    }
#endif
}
