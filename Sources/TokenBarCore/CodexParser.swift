import Foundation

/// Tolerant parser for Codex session JSONL files.
///
/// Expected root: `~/.codex/sessions` (override with `TOKENBAR_CODEX_ROOT`).
/// Every `*.jsonl` file is read recursively, one record per line.
/// Only lines carrying a `token_usage_record`-style payload (or bare token
/// fields, to survive schema drift) become records. Anything else is skipped
/// and counted, never fatal.
public enum CodexParser {
    public struct Result {
        public var records: [NormalizedUsage]
        public var skippedLines: Int
    }

    private static let tokenKeys = [
        "input_tokens", "inputtokens", "prompt_tokens", "prompttokens",
        "output_tokens", "outputtokens", "completion_tokens", "completiontokens",
        "cached_tokens", "cachedtokens", "cached_input_tokens",
        "reasoning_tokens", "reasoningtokens", "reasoning_output_tokens",
        "total_tokens", "totaltokens", "total",
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

        // Type gate: when a type discriminator exists it must reference token usage,
        // unless the object carries bare token fields (schema drift tolerance).
        if let typeValue = firstString(top, keys: ["type", "payload_type", "kind", "event", "name"])?.lowercased()
           ?? firstString(payload, keys: ["type", "payload_type", "kind", "event", "name"])?.lowercased()
        {
            let mentionsUsage = typeValue.contains("token_usage")
            let hasTokenField = tokenKeys.contains { payload[$0] != nil || top[$0] != nil }
            if !mentionsUsage && !hasTokenField { return nil }
        }

        let merged = payload.merging(top) { payloadValue, _ in payloadValue }
        guard let timestamp = parseTimestamp(
            firstRaw(merged, keys: ["timestamp", "time", "created_at", "createdAt", "date"])
        ) else { return nil }
        return buildRecord(merged: merged, timestamp: timestamp, fileId: fileId, lineNumber: lineNumber)
    }

    // MARK: - Private helpers

    private static func buildRecord(
        merged: [String: Any],
        timestamp: Date,
        fileId: String,
        lineNumber: Int
    ) -> NormalizedUsage? {
        let input = intField(merged, keys: ["input_tokens", "inputtokens", "prompt_tokens", "prompttokens", "input"])
        let output = intField(merged, keys: ["output_tokens", "outputtokens", "completion_tokens", "completiontokens", "output"])
        let cached = intField(merged, keys: ["cached_tokens", "cachedtokens", "cached_input_tokens", "cachedinputtokens"])
        let reasoning = intField(merged, keys: ["reasoning_tokens", "reasoningtokens", "reasoning_output_tokens"])
        let total = intField(merged, keys: ["total_tokens", "totaltokens", "total"])

        // A usage line must carry at least one token count.
        guard input != nil || output != nil || cached != nil || reasoning != nil || total != nil else {
            return nil
        }

        let model = firstString(merged, keys: ["model", "model_name", "modelname"]) ?? "unknown"
        let sessionId = firstString(merged, keys: ["session_id", "sessionid", "conversation_id", "conversationid"]) ?? ""
        let requestId = firstString(merged, keys: ["request_id", "requestid", "message_id", "messageid", "id"]) ?? ""
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
                if let int = raw as? Int { return int }
                if let double = raw as? Double { return Int(double) }
                if let number = raw as? NSNumber { return number.intValue }
                if let string = raw as? String, let parsed = Int(string) { return parsed }
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
