import Foundation

/// Tolerant parser for Codex session JSONL files.
///
/// Expected root: `~/.codex/sessions` (override with `TOKENBAR_CODEX_ROOT`).
/// Every `*.jsonl` file is read recursively, one record per line.
/// Only lines carrying a `token_usage_record`-style payload, a `response`
/// record with a nested per-record `usage` object, or bare token fields (to
/// survive schema drift) become records. Anything else is skipped and
/// counted, never fatal.
///
/// Real-world shape (438-JSONL finding): top-level `type` may be a response
/// marker, `timestamp` lives at the top level, and `payload` carries
/// `response_id` / `session_id` / `thread_id` / `turn_id` plus nested
/// `usage`, `turn_token_usage`, and `thread_token_usage` objects. Only
/// `payload.usage` holds per-record values (turn/thread objects are
/// cumulative), so token counts always come from `usage` when present.
public enum CodexParser {
    public struct Result {
        public var records: [NormalizedUsage]
        public var skippedLines: Int
    }

    private static let tokenKeys = [
        "input_tokens", "inputtokens", "prompt_tokens", "prompttokens",
        "tokens_input", "tokensinput",
        "output_tokens", "outputtokens", "completion_tokens", "completiontokens",
        "tokens_output", "tokensoutput",
        "cached_tokens", "cachedtokens", "cached_input_tokens",
        "cache_write_input_tokens", "cachewriteinputtokens",
        "tokens_cache_read", "tokens_cache_write",
        "reasoning_tokens", "reasoningtokens", "reasoning_output_tokens",
        "tokens_reasoning",
        "total_tokens", "totaltokens", "total", "tokens_total",
    ]

    /// Nested per-record usage containers. `usage` is authoritative when
    /// present; `turn_token_usage` / `thread_token_usage` are cumulative and
    /// must never be summed on top.
    private static let nestedUsageKeys = [
        "usage", "token_usage", "tokenusage",
    ]

    public static func parseDirectory(root: URL, fileManager: FileManager = .default) -> Result {
        var records: [NormalizedUsage] = []
        var skipped = 0
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Result(records: [], skippedLines: 0)
        }
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let file = parseFile(at: url)
            records.append(contentsOf: file.records)
            skipped += file.skippedLines
        }
        return Result(records: records, skippedLines: skipped)
    }

    public static func parseFile(at url: URL) -> Result {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Result(records: [], skippedLines: 0)
        }
        var records: [NormalizedUsage] = []
        var skipped = 0
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if let record = parseLine(line, fileId: url.lastPathComponent, lineNumber: index + 1) {
                records.append(record)
            } else {
                skipped += 1
            }
        }
        return Result(records: records, skippedLines: skipped)
    }

    /// Returns nil for blank / non-JSON / non-usage / malformed lines.
    public static func parseLine(_ line: String, fileId: String = "", lineNumber: Int = 0) -> NormalizedUsage? {
        guard let data = line.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let payload = payloadDict(from: top)

        // Type gate: when a type discriminator exists it must reference token usage
        // or a response record carrying a nested per-record usage object, unless
        // the object carries bare token fields (schema drift tolerance).
        if let typeValue = firstString(top, keys: ["type", "payload_type", "kind", "event", "name"])?.lowercased()
           ?? firstString(payload, keys: ["type", "payload_type", "kind", "event", "name"])?.lowercased()
        {
            let mentionsUsage = typeValue.contains("token_usage")
            let mentionsResponse = typeValue.contains("response")
            let hasTokenField = tokenKeys.contains { payload[$0] != nil || top[$0] != nil }
            let hasNestedUsage = nestedUsageDict(from: top, payload: payload) != nil
            if !mentionsUsage && !hasTokenField && !(mentionsResponse && hasNestedUsage) { return nil }
        }

        let merged = payload.merging(top) { payloadValue, _ in payloadValue }
        guard let timestamp = parseTimestamp(
            firstRaw(merged, keys: ["timestamp", "time", "created_at", "createdAt", "date"])
        ) else { return nil }
        return buildRecord(top: top, payload: payload, merged: merged, timestamp: timestamp, fileId: fileId, lineNumber: lineNumber)
    }

    // MARK: - Private helpers

    private static func buildRecord(
        top: [String: Any],
        payload: [String: Any],
        merged: [String: Any],
        timestamp: Date,
        fileId: String,
        lineNumber: Int
    ) -> NormalizedUsage? {
        // Per-record values live in payload.usage when present. Turn/thread
        // objects are cumulative rollups and must not be summed on top.
        let usage = nestedUsageDict(from: top, payload: payload) ?? merged
        let input = intField(usage, keys: ["input_tokens", "inputtokens", "prompt_tokens", "prompttokens", "tokens_input", "tokensinput", "input"])
        let output = intField(usage, keys: ["output_tokens", "outputtokens", "completion_tokens", "completiontokens", "tokens_output", "tokensoutput", "output"])
        let cachedRead = intField(usage, keys: ["cached_tokens", "cachedtokens", "cached_input_tokens", "cachedinputtokens", "tokens_cache_read", "tokenscacheread"])
        let cachedWrite = intField(usage, keys: ["cache_write_input_tokens", "cachewriteinputtokens", "tokens_cache_write", "tokenscachewrite"])
        let cached: Int? = {
            if cachedRead == nil && cachedWrite == nil { return nil }
            return (cachedRead ?? 0) + (cachedWrite ?? 0)
        }()
        let reasoning = intField(usage, keys: ["reasoning_tokens", "reasoningtokens", "reasoning_output_tokens", "reasoningoutputtokens", "tokens_reasoning", "tokensreasoning"])
        let total = intField(usage, keys: ["total_tokens", "totaltokens", "tokens_total", "tokenstotal", "total"])

        // A usage line must carry at least one token count.
        guard input != nil || output != nil || cached != nil || reasoning != nil || total != nil else {
            return nil
        }

        let model = firstString(merged, keys: ["model", "model_name", "modelname"]) ?? "unknown"
        // thread_id is session-scoped, so it only informs sessionId, never
        // request identity (which stays response/turn/request/message IDs).
        let sessionId = firstString(merged, keys: ["session_id", "sessionid", "thread_id", "threadid", "conversation_id", "conversationid"]) ?? ""
        let requestId = firstString(merged, keys: ["response_id", "responseid", "request_id", "requestid", "message_id", "messageid", "turn_id", "turnid", "id"]) ?? ""
        let fallbackId = "\(fileId):\(lineNumber)"
        let id = requestId.isEmpty ? "codex:\(fallbackId)" : "codex:\(requestId)"
        return NormalizedUsage(
            id: id,
            source: .codex,
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

    private static func payloadDict(from top: [String: Any]) -> [String: Any] {
        for key in ["payload", "data", "record", "usage", "token_usage"] {
            if let nested = top[key] as? [String: Any] { return nested }
        }
        return top
    }

    /// Returns the per-record usage object when present (payload.usage first,
    /// then top-level usage). Nil when no nested usage dict exists.
    private static func nestedUsageDict(from top: [String: Any], payload: [String: Any]) -> [String: Any]? {
        for container in [payload, top] {
            for key in nestedUsageKeys {
                if let nested = container[key] as? [String: Any] { return nested }
            }
        }
        return nil
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

    /// ISO-8601 strings (with/without fractional seconds, Z or offset),
    /// epoch seconds (10-digit) and epoch millis (13-digit).
    public static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let date = raw as? Date { return date }
        if let int = raw as? Int { return dateFromEpochNumber(Double(int)) }
        if let double = raw as? Double { return dateFromEpochNumber(double) }
        if let number = raw as? NSNumber { return dateFromEpochNumber(number.doubleValue) }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let epoch = Double(trimmed), epoch > 1_000_000_000 {
                return dateFromEpochNumber(epoch)
            }
            let formatters: [ISO8601DateFormatter] = {
                let plain = ISO8601DateFormatter()
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return [fractional, plain]
            }()
            for formatter in formatters {
                if let date = formatter.date(from: trimmed) { return date }
            }
            // Last resort: bare yyyy-MM-dd.
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "yyyy-MM-dd"
            if let date = day.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func dateFromEpochNumber(_ value: Double) -> Date? {
        if value > 10_000_000_000_000 || value < 0 { return nil } // absurd
        if value > 10_000_000_000 { return Date(timeIntervalSince1970: value / 1000.0) } // millis
        if value > 1_000_000_000 { return Date(timeIntervalSince1970: value) } // seconds
        return nil
    }
}
