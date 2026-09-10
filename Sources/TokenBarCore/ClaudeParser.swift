import Foundation

/// Tolerant parser for Claude Code session JSONL files.
///
/// Expected root: `~/.claude/projects` (override with `TOKENBAR_CLAUDE_ROOT`).
/// Every `*.jsonl` file is read recursively, one record per line, read-only.
/// Only assistant records carrying `message.usage` become records. User,
/// system, tool, and summary lines carry no `message.usage` and are skipped
/// and counted, never fatal.
///
/// Real shape (generic default only): top-level `type` (assistant), `message`
/// with `model` / `id` plus nested `usage` (`input_tokens`,
/// `output_tokens`, `cache_read_input_tokens`,
/// `cache_creation_input_tokens`), plus top-level `model`, `timestamp`,
/// `sessionId`. Anthropic usage semantics sum all three input components,
/// so normalized `input = input_tokens + cache_read + cache_creation`
/// (same fold-in rule as OpenCode, unlike Codex whose `payload.usage`
/// input already includes cache). `total = normalized input + output`
/// unless an explicit positive total exists.
public enum ClaudeParser {
    public struct Result {
        public var records: [NormalizedUsage]
        public var skippedLines: Int
    }

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
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let file = parseFile(at: url, fileId: relativePath(of: url, to: rootPath))
            records.append(contentsOf: file.records)
            skipped += file.skippedLines
        }
        return Result(records: records, skippedLines: skipped)
    }

    public static func parseFile(at url: URL, fileId: String? = nil) -> Result {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Result(records: [], skippedLines: 0)
        }
        let label = fileId ?? url.lastPathComponent
        var records: [NormalizedUsage] = []
        var skipped = 0
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if let record = parseLine(line, fileId: label, lineNumber: index + 1) {
                records.append(record)
            } else {
                skipped += 1
            }
        }
        return Result(records: records, skippedLines: skipped)
    }

    /// Returns nil for blank / non-JSON / non-assistant / missing-usage /
    /// malformed lines.
    public static func parseLine(_ line: String, fileId: String = "", lineNumber: Int = 0) -> NormalizedUsage? {
        guard let data = line.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Type gate: when a type discriminator exists it must reference an
        // assistant record. Lines without a type still pass when they carry
        // message.usage (schema drift tolerance).
        if let typeValue = firstString(top, keys: ["type"])?.lowercased() {
            if !typeValue.contains("assistant") { return nil }
        }

        guard let message = top["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let rawInput = intField(usage, keys: ["input_tokens", "inputtokens", "input"])
        let output = intField(usage, keys: ["output_tokens", "outputtokens", "output"])
        let cacheRead = intField(usage, keys: [
            "cache_read_input_tokens", "cachereadinputtokens",
            "cached_tokens", "cachedtokens", "cached_input_tokens",
            "tokens_cache_read", "tokenscacheread",
        ])
        let cacheCreation = intField(usage, keys: [
            "cache_creation_input_tokens", "cachecreationinputtokens",
            "cache_write_input_tokens", "cachewriteinputtokens",
            "tokens_cache_write", "tokenscachewrite",
        ])
        let cached: Int? = {
            if cacheRead == nil && cacheCreation == nil { return nil }
            return (cacheRead ?? 0) + (cacheCreation ?? 0)
        }()
        // Anthropic usage semantics: total input sums raw input plus both
        // cache components, so the normalized input folds cache back in.
        // This keeps cached a true subset of input and lets the total
        // fallback include cached usage. (Codex needs no such fold: its
        // payload.usage input already includes cached input.)
        let input: Int? = {
            if rawInput == nil && cached == nil { return nil }
            return (rawInput ?? 0) + (cached ?? 0)
        }()
        let total = intField(usage, keys: ["total_tokens", "totaltokens", "tokens_total", "tokenstotal", "total"])
            ?? intField(message, keys: ["total_tokens", "totaltokens", "total"])
            ?? intField(top, keys: ["total_tokens", "totaltokens", "total"])

        // A usage line must carry at least one token count.
        guard input != nil || output != nil || cached != nil || total != nil else {
            return nil
        }

        let merged = message.merging(top) { messageValue, _ in messageValue }
        guard let timestamp = CodexParser.parseTimestamp(
            firstRaw(merged, keys: ["timestamp", "time", "created_at", "createdAt", "date"])
                ?? firstRaw(top, keys: ["timestamp", "time", "created_at", "createdAt", "date"])
        ) else { return nil }

        let model = firstString(merged, keys: ["model", "model_name", "modelname"]) ?? "unknown"
        let sessionId = firstString(merged, keys: ["sessionId", "session_id", "sessionid"]) ?? ""
        // The per-message API id is the finest-grained stable key for the
        // usage block, so it wins over the outer request id when both exist.
        let requestId = firstString(message, keys: ["id", "message_id", "messageid", "messageId"])
            ?? firstString(merged, keys: ["requestId", "request_id", "requestid"])
            ?? ""
        // Empty requestId stays unique by id downstream (TokenBarStore.dedupe
        // keeps records without a requestId); the root-relative path:line
        // fallback keeps the id itself stable and deterministic across files
        // that share a basename. Ids are process-internal (sort/dedupe
        // keys only, never rendered in terminal, JSON, or UI output), so no
        // filesystem layout leaks through them.
        let fallbackId = "\(fileId):\(lineNumber)"
        let id = requestId.isEmpty ? "claude:\(fallbackId)" : "claude:\(requestId)"
        return NormalizedUsage(
            id: id,
            source: .claude,
            timestamp: timestamp,
            model: model,
            inputTokens: input ?? 0,
            outputTokens: output ?? 0,
            cachedTokens: cached ?? 0,
            reasoningTokens: 0,
            totalTokens: total ?? 0,
            sessionId: sessionId,
            requestId: requestId
        )
    }

    // MARK: - Private helpers

    /// Root-relative label for fallback ids (`sub/dir.jsonl`), so files
    /// sharing a basename in different subdirectories stay distinct. Never
    /// an absolute path: falls back to the basename when the file escapes
    /// the root.
    static func relativePath(of url: URL, to rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        var base = rootPath
        if !base.hasSuffix("/") { base += "/" }
        if path.hasPrefix(base) {
            return String(path.dropFirst(base.count))
        }
        return url.lastPathComponent
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
}
