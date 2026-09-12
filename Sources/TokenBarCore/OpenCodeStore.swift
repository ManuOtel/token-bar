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
/// `session` share one row per session per table; per-session rollup rows
/// carry no per-message ID, so `decodeRow` falls back to
/// `sessionID#epochSeconds` as the request ID, and genuine rows for one
/// session at different timestamps keep distinct keys and are never merged.
/// Message rows carry stable message IDs shared across the `message` /
/// `session_message` mirror pair.
///
/// Mirror selection is deterministic and identical on both levels (see
/// `combineMessageAndRollup`) and in `TokenBarStore.dedupe`: one record per
/// `source + requestId`, the larger `totalTokens` wins, ties break to the
/// earliest `(timestamp, id)`. Dedupe is a no-op for already-combined keys;
/// records with an empty requestId collapse by `source + id` (cloned id-less
/// rows share stable content-hashed IDs, see `decodeMessageRow`).
///
/// Load-bearing assumptions (re-validate if the OpenCode schema drifts):
/// - Message rows link to rollup rows by session ID: `message.session_id`
///   values match `session.id` values (the live schema enforces this with
///   a foreign key). The covered-session filter in `combineMessageAndRollup`
///   depends on it; a mismatch would surface as double counting.
/// - Nested message input excludes cache: `data.tokens.input` does not
///   contain `data.tokens.cache.read/write`, same convention as the
///   rollup `tokens_input` column, so the same fold-in rule applies.
/// - Validated once on a live 954MB database snapshot: per-session sums of
///   decoded message tokens equaled the corresponding `session` rollup
///   columns for the sampled session, and the 7d message-level token total
///   equaled the 7d rollup total. Single-host observation, not a standing
///   guarantee: if a future schema breaks any assumption, rows degrade to
///   skipped + counted (visible as notices) rather than silent misreport.
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
    /// `origin` labels the host the row was read from (`"local"` default).
    public static func decodeRow(_ columns: [String: String?], table: String = "session_v2", origin: String = "local") -> NormalizedUsage? {
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
            requestId: requestId,
            origin: origin
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
    public static func decodeMessageRow(_ columns: [String: String?], table: String = "message", origin: String = "local") -> NormalizedUsage? {
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

        // 4. Timestamp: nested data.time.created first (epoch millis),
        // then flat time_created-style columns. Blob top-level timestamp
        // keys are not probed: observed message blobs carry time only
        // under the nested `time` object, and the flat columns always
        // exist on the real tables.
        let time = data["time"] as? [String: Any]
        let timestamp = CodexParser.parseTimestamp(timeRaw(time, keys: ["created", "completed", "updated"]))
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
        // session_message mirror pair. Rows without any message ID get a
        // deterministic content-hashed fallback (see `fallbackMessageID`):
        // distinct rows in one session stay distinct, identical rows share
        // an ID, and no randomness leaks into the record set.
        let messageId = dataString(data, keys: ["id", "message_id", "messageid", "messageId"])
            ?? stringColumn(columns, keys: ["id", "message_id", "messageid"]) ?? ""
        let requestId = messageId
        let id = "opencode:\(fallbackMessageID(table: table, columns: columns, messageId: messageId, sessionId: sessionId, timestamp: timestamp))"

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
            requestId: requestId,
            origin: origin
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
    /// messages were compacted away). Mirror selection is deterministic and
    /// identical on both levels: one record per `source + requestId`, the
    /// larger `totalTokens` wins, ties break to the earliest
    /// `(timestamp, id)`. Records with an empty requestId pass through
    /// untouched, preserving `TokenBarStore.dedupe` semantics (unique by
    /// id, always kept).
    public static func combineMessageAndRollup(
        messages: [NormalizedUsage],
        rollups: [NormalizedUsage]
    ) -> [NormalizedUsage] {
        let covered = Set(messages.map(\.sessionId).filter { !$0.isEmpty })
        var bestMessage: [String: NormalizedUsage] = [:]
        var passthrough: [NormalizedUsage] = []
        for message in messages {
            if message.requestId.isEmpty {
                passthrough.append(message)
            } else {
                selectMirror(&bestMessage, key: "opencode:\(message.requestId)", candidate: message)
            }
        }
        var bestRollup: [String: NormalizedUsage] = [:]
        for rollup in rollups {
            if !covered.isEmpty, !rollup.sessionId.isEmpty, covered.contains(rollup.sessionId) { continue }
            if rollup.requestId.isEmpty {
                passthrough.append(rollup)
            } else {
                selectMirror(&bestRollup, key: "opencode:\(rollup.requestId)", candidate: rollup)
            }
        }
        return (passthrough + bestMessage.values + bestRollup.values).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }

    /// Deterministic mirror selection shared by both granularity levels:
    /// larger `totalTokens` wins so a stale mirror never shadows fresh
    /// data; exact ties break to the earliest `(timestamp, id)` so repeated
    /// loads agree byte-for-byte.
    private static func selectMirror(
        _ best: inout [String: NormalizedUsage],
        key: String,
        candidate: NormalizedUsage
    ) {
        guard let seen = best[key] else {
            best[key] = candidate
            return
        }
        if candidate.totalTokens != seen.totalTokens {
            if candidate.totalTokens > seen.totalTokens { best[key] = candidate }
        } else if (candidate.timestamp, candidate.id) < (seen.timestamp, seen.id) {
            best[key] = candidate
        }
    }

    /// Deterministic fallback ID for message rows without a message ID.
    /// Real tables always carry an `id` column, so this is drift tolerance
    /// only. The ID folds in table, session, epoch second, and a stable
    /// FNV-1a hash over the sorted `key=value` column projection: two
    /// ID-less rows in one session at one timestamp stay distinct unless
    /// every column matches (true content dupes). No UUID, no randomness,
    /// stable across runs (Swift's `hashValue` is per-process seeded and
    /// must never be used here).
    static func fallbackMessageID(
        table: String,
        columns: [String: String?],
        messageId: String,
        sessionId: String,
        timestamp: Date
    ) -> String {
        let epoch = Int(timestamp.timeIntervalSince1970)
        if !messageId.isEmpty { return "\(table):\(messageId):\(epoch)" }
        let session = sessionId.isEmpty ? "nosession" : sessionId
        return "\(table):\(session):\(epoch):\(stableRowHash(columns))"
    }

    /// Stable FNV-1a 64-bit hash rendered as 16 lowercase hex digits.
    /// Deterministic across processes, architectures, and runs. Missing
    /// (NULL) values render as the literal `null`; present values render
    /// verbatim, including empty strings. This exact rendering is the hash
    /// contract shared with `fnv1a_hex` in `scripts/verify_logic.py`:
    /// do not touch it without updating the mirror.
    static func stableRowHash(_ columns: [String: String?]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for key in columns.keys.sorted() {
            // Flatten String?? without `?? nil`: the double optional comes
            // from dictionary subscripting over an optional value type.
            let flattened: String? = columns[key].flatMap { $0 }
            let rendered: String
            if let flattened {
                rendered = flattened
            } else {
                rendered = "null"
            }
            for byte in "\(key)=\(rendered)".utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return String(format: "%016llx", hash)
    }

    /// Loads all decodable rows from the SQLite file. Throws
    /// `StoreError.sqliteUnavailable` on platforms without the SQLite3 module.
    /// `origin` labels every returned record (default `"local"`; extra
    /// homeserver copies use `"homeserver"`).
    public static func loadDatabase(at path: String, origin: String = "local") throws -> (records: [NormalizedUsage], skipped: Int) {
#if canImport(SQLite3)
        return try sqliteLoad(path: path, origin: origin)
#else
        throw StoreError.sqliteUnavailable
#endif
    }

    /// Raw split behind `loadDatabase`: message-level rows and rollup rows
    /// separately so multi-input merges can apply one global
    /// `combineMessageAndRollup` (messages win everywhere, rollups fill only
    /// uncovered sessions). Pure-decode hosts without SQLite get empty parts.
    public static func loadDatabaseParts(at path: String, origin: String = "local") throws -> (messages: [NormalizedUsage], rollups: [NormalizedUsage], skipped: Int) {
#if canImport(SQLite3)
        return try sqliteParts(path: path, origin: origin)
#else
        throw StoreError.sqliteUnavailable
#endif
    }

    /// Heuristic used when merging already-combined snapshot records back
    /// into a global combine: rollup request IDs are `sessionID#epochSeconds`
    /// (see `decodeRow`), message request IDs are opaque UUIDs that never
    /// contain `#`. Empty request IDs pass through untouched.
    public static func isRollupRecord(_ record: NormalizedUsage) -> Bool {
        record.requestId.contains("#")
    }

    /// Forbidden snapshot keys: prompt text, tool I/O, file paths,
    /// credentials, and message bodies. The loader ignores them (never
    /// stored) and reports one sanitized warning per file when any appear.
    /// Privacy-denylist field names only, no network use (see CI exception).
    public static let snapshotForbiddenKeys: Set<String> = [
        "prompt", "prompts", "prompt_text", "prompttext",
        "tool", "tools", "tool_calls", "toolcalls", "tool_input", "tool_output",
        "content", "contents", "text", "body", "message", "messages",
        "messagetext", "message_text", "reasoning_text", "reasoningtext",
        "path", "paths", "filepath", "filepaths", "file", "files", "cwd",
        "credential", "credentials", "secret", "secrets", "api_key", "apikey",
        "token", "authorization",
        // privacy-denylist: session-field names only, never transmitted.
        "cookie", "cookies", // privacy-denylist
    ]

    /// Loads a sanitized homeserver snapshot: a JSON array of normalized
    /// token-only records as written by `scripts/export-opencode-usage.py`.
    /// Accepted per-record keys (camelCase or snake_case): `id`,
    /// `timestamp` (ISO8601 or epoch seconds/millis), `model` (or
    /// `provider` + `model` pair), token counts (`inputTokens`/`input_tokens`
    /// etc., plus `cached`/`reasoning`/`total`), `sessionId`/`session_id`,
    /// `requestId`/`request_id`/`messageId`, `origin`/`host`/`label`.
    /// `source`, when present, must be `opencode` (other values skip + count).
    /// Missing `origin` falls back to `originFallback` (`"homeserver"` from
    /// the Store). Returns records plus skipped count plus whether any
    /// forbidden non-token keys were seen and ignored.
    public static func loadSnapshot(
        at path: String,
        originFallback: String = "homeserver"
    ) throws -> (records: [NormalizedUsage], skipped: Int, sawExtraFields: Bool) {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let array = json as? [[String: Any]]
        else {
            throw StoreError.sqliteOpenFailed(path)
        }
        var records: [NormalizedUsage] = []
        var skipped = 0
        var sawExtra = false
        for element in array {
            let lowered = Dictionary(uniqueKeysWithValues: element.map { ($0.key.lowercased(), $0.value) })
            for key in element.keys where snapshotForbiddenKeys.contains(key.lowercased()) {
                sawExtra = true
                break
            }
            _ = lowered
            if let record = decodeSnapshotRecord(element, originFallback: originFallback) {
                records.append(record)
            } else {
                skipped += 1
            }
        }
        return (records, skipped, sawExtra)
    }

    /// Pure snapshot record decoder (no filesystem). Returns nil for rows
    /// without usable timestamp or token counts, for non-opencode sources,
    /// and for all-zero rows (empty messages carry no usage).
    public static func decodeSnapshotRecord(
        _ dict: [String: Any],
        originFallback: String = "homeserver"
    ) -> NormalizedUsage? {
        func text(_ keys: String...) -> String? {
            for key in keys {
                if let value = dict[key] as? String, !value.isEmpty { return value }
                let low = key.lowercased()
                for (k, v) in dict where k.lowercased() == low {
                    if let s = v as? String, !s.isEmpty { return s }
                }
            }
            return nil
        }
        func int(_ keys: String...) -> Int? {
            for key in keys {
                let candidates = [key] + [key.lowercased()]
                for candidate in candidates {
                    var raw: Any?
                    if let hit = dict[candidate] { raw = hit }
                    else {
                        for (k, v) in dict where k.lowercased() == candidate.lowercased() { raw = v; break }
                    }
                    guard let value = raw else { continue }
                    if let number = value as? NSNumber, String(cString: number.objCType) == "c" { continue }
                    if let i = value as? Int { return i }
                    if let d = value as? Double { return Int(d) }
                    if let n = value as? NSNumber { return n.intValue }
                    if let s = value as? String {
                        if let parsed = Int(s) { return parsed }
                        if let parsed = Double(s) { return Int(parsed) }
                    }
                }
            }
            return nil
        }
        func raw(_ keys: String...) -> Any? {
            for key in keys {
                if let hit = dict[key] { return hit }
                for (k, v) in dict where k.lowercased() == key.lowercased() { return v }
            }
            return nil
        }
        if let source = text("source"), !source.isEmpty, source.lowercased() != "opencode" {
            return nil
        }
        let timestamp = CodexParser.parseTimestamp(raw("timestamp", "time", "created_at", "createdAt", "created", "date"))
        guard let timestamp else { return nil }
        let input = int("inputTokens", "input_tokens", "inputtokens", "input", "prompt_tokens", "prompttokens", "tokens_input", "tokensinput")
        let output = int("outputTokens", "output_tokens", "outputtokens", "output", "completion_tokens", "completiontokens", "tokens_output", "tokensoutput")
        let cached = int("cachedTokens", "cached_tokens", "cachedtokens", "cached", "cache_read_input_tokens", "tokens_cache_read", "tokenscacheread", "tokens_cache_write", "tokenscachewrite")
        let reasoning = int("reasoningTokens", "reasoning_tokens", "reasoningtokens", "reasoning", "tokens_reasoning", "tokensreasoning")
        let total = int("totalTokens", "total_tokens", "totaltokens", "total", "tokens_total", "tokenstotal", "tokens")
        guard input != nil || output != nil || cached != nil || reasoning != nil || total != nil else { return nil }
        let provider = text("provider", "providerID", "providerId", "provider_id")
        let modelName = text("model", "model_name", "modelname", "modelID", "modelId", "model_id")
        let model: String = {
            if let name = modelName, !name.isEmpty {
                if name.hasPrefix("{") { return decodeModelLabel(name) ?? "unknown" }
                if let provider, !provider.isEmpty, !name.contains("/") { return "\(provider)/\(name)" }
                return name
            }
            return provider ?? "unknown"
        }()
        let sessionId = text("sessionId", "session_id", "sessionid", "session") ?? ""
        let requestId = text("requestId", "request_id", "requestid", "request", "messageId", "message_id", "messageid", "id_message", "message") ?? ""
        let originRaw = text("origin", "host", "hostname", "label", "machine") ?? originFallback
        let trimmedOrigin = originRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = trimmedOrigin.isEmpty ? originFallback : trimmedOrigin
        var id = text("id") ?? ""
        if id.isEmpty {
            let epoch = Int(timestamp.timeIntervalSince1970)
            let session = sessionId.isEmpty ? "nosession" : sessionId
            if !requestId.isEmpty {
                id = "opencode:\(requestId)"
            } else {
                var projection: [String: String] = [:]
                projection["model"] = model
                projection["session"] = session
                projection["input"] = "\(input ?? 0)"
                projection["output"] = "\(output ?? 0)"
                projection["cached"] = "\(cached ?? 0)"
                projection["reasoning"] = "\(reasoning ?? 0)"
                projection["total"] = "\(total ?? 0)"
                var hash: UInt64 = 14_695_981_039_346_656_037
                for key in projection.keys.sorted() {
                    for byte in "\(key)=\(projection[key]!)".utf8 {
                        hash ^= UInt64(byte)
                        hash &*= 1_099_511_628_211
                    }
                }
                id = String(format: "opencode:snapshot:%@:m%08x", session, UInt32(truncatingIfNeeded: hash) ^ UInt32(epoch))
            }
        }
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
            requestId: requestId,
            origin: origin
        )
        guard record.totalTokens > 0 || record.inputTokens > 0 || record.outputTokens > 0
            || record.cachedTokens > 0 || record.reasoningTokens > 0
        else { return nil }
        return record
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
    private static func sqliteLoad(path: String, origin: String = "local") throws -> (records: [NormalizedUsage], skipped: Int) {
        let parts = try sqliteParts(path: path, origin: origin)
        // Message rows win where they exist; rollups fill uncovered
        // sessions only, so the two levels never double count.
        return (combineMessageAndRollup(messages: parts.messages, rollups: parts.rollups), parts.skipped)
    }

    private static func sqliteParts(path: String, origin: String = "local") throws -> (messages: [NormalizedUsage], rollups: [NormalizedUsage], skipped: Int) {
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
                decodeMessageRow($0, table: $1, origin: origin)
            }
            messages.append(contentsOf: records)
            skipped += tableSkipped
        }
        for table in tableNames {
            let (records, tableSkipped) = loadTable(db: db, table: table) {
                decodeRow($0, table: $1, origin: origin)
            }
            rollups.append(contentsOf: records)
            skipped += tableSkipped
        }
        return (messages, rollups, skipped)
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
