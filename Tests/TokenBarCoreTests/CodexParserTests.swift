import Foundation
import XCTest
@testable import TokenBarCore

final class CodexParserTests: XCTestCase {
    func testValidTokenUsageRecord() {
        let line = #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","model":"gpt-5-mini","input_tokens":1200,"output_tokens":340,"cached_tokens":200,"reasoning_tokens":120,"session_id":"s1","request_id":"r1"}"#
        let record = CodexParser.parseLine(line, fileId: "f.jsonl", lineNumber: 1)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source, .codex)
        XCTAssertEqual(record?.model, "gpt-5-mini")
        XCTAssertEqual(record?.inputTokens, 1200)
        XCTAssertEqual(record?.outputTokens, 340)
        XCTAssertEqual(record?.cachedTokens, 200)
        XCTAssertEqual(record?.reasoningTokens, 120)
        XCTAssertEqual(record?.totalTokens, 1540) // input + output; subsets not added
    }

    func testAliasFieldsAndNestedPayload() {
        let line = #"{"payload":{"type":"token_usage_record","timestamp":1757325600,"model":"x","prompt_tokens":500,"completion_tokens":150,"session_id":"s","request_id":"r"}}"#
        let record = CodexParser.parseLine(line)
        XCTAssertEqual(record?.inputTokens, 500)
        XCTAssertEqual(record?.outputTokens, 150)
        XCTAssertEqual(record?.totalTokens, 650)
    }

    func testBareTokenFieldsWithoutTypePass() {
        let line = #"{"timestamp":"2026-09-10T08:15:00Z","input_tokens":10,"output_tokens":5}"#
        XCTAssertNotNil(CodexParser.parseLine(line))
    }

    func testNonUsageTypeRejected() {
        let line = #"{"type":"heartbeat","timestamp":"2026-09-10T09:00:00Z","model":"gpt-5-mini"}"#
        XCTAssertNil(CodexParser.parseLine(line))
    }

    func testMalformedLinesRejected() {
        XCTAssertNil(CodexParser.parseLine("not json"))
        XCTAssertNil(CodexParser.parseLine(#"{"type":"token_usage_record","timestamp":"nope","input_tokens":1}"#))
        XCTAssertNil(CodexParser.parseLine(#"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z"}"#)) // no counts
    }

    func testEpochMillisTimestamp() {
        let line = #"{"timestamp":1757325600000,"input_tokens":1,"output_tokens":1}"#
        let record = CodexParser.parseLine(line)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.timestamp.timeIntervalSince1970 ?? 0, 1757325600, accuracy: 1)
    }

    func testUnknownModelKept() {
        let line = #"{"timestamp":"2026-09-10T08:15:00Z","input_tokens":5,"output_tokens":5}"#
        XCTAssertEqual(CodexParser.parseLine(line)?.model, "unknown")
    }

    func testFloatStringCountsTolerated() {
        let line = #"{"timestamp":"2026-09-10T08:15:00Z","input_tokens":"10.0","output_tokens":"5"}"#
        XCTAssertEqual(CodexParser.parseLine(line)?.totalTokens, 15)
    }

    func testBoolCountsRejected() {
        XCTAssertNil(CodexParser.parseLine(#"{"timestamp":"2026-09-10T08:15:00Z","input_tokens":true}"#))
    }

    func testNumericOneAcceptedAndTrueRejected() {
        // Darwin bridges any NSNumber holding 0/1 as Bool, so the count
        // gate must use objCType, never `is Bool` (Mac CI regression).
        let ones = CodexParser.parseLine(#"{"timestamp":"2026-09-10T08:15:00Z","input_tokens":1,"output_tokens":1}"#)
        XCTAssertEqual(ones?.inputTokens, 1)
        XCTAssertEqual(ones?.totalTokens, 2)
        XCTAssertNil(CodexParser.parseLine(#"{"timestamp":"2026-09-10T08:15:00Z","input_tokens":true,"output_tokens":true}"#))
    }

    func testResponseShapeUsesPerRecordUsageNotCumulative() {
        // Real-world Codex shape: top-level response marker + timestamp, payload
        // IDs plus nested usage (per-record) beside cumulative turn/thread rollups.
        let line = """
        {"type":"response","timestamp":"2026-09-10T08:15:00Z","payload":{\
        "response_id":"resp-1","session_id":"sess-1","thread_id":"thread-1",\
        "turn_id":"turn-1","root_turn_id":"turn-1",\
        "usage":{"input_tokens":1200,"output_tokens":340,"cached_input_tokens":200,\
        "cache_write_input_tokens":50,"reasoning_output_tokens":120,"total_tokens":1540},\
        "turn_token_usage":{"input_tokens":9999,"output_tokens":9999,"total_tokens":19998},\
        "thread_token_usage":{"input_tokens":8888,"output_tokens":8888,"total_tokens":17776}}}
        """
        let record = CodexParser.parseLine(line, fileId: "f.jsonl", lineNumber: 1)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.inputTokens, 1200)
        XCTAssertEqual(record?.outputTokens, 340)
        XCTAssertEqual(record?.cachedTokens, 250) // read + write, not cumulative
        XCTAssertEqual(record?.reasoningTokens, 120)
        XCTAssertEqual(record?.totalTokens, 1540) // per-record, not turn/thread
        XCTAssertEqual(record?.sessionId, "sess-1")
        XCTAssertEqual(record?.requestId, "resp-1")
    }

    func testResponseWithoutNestedUsageRejected() {
        XCTAssertNil(CodexParser.parseLine(
            #"{"type":"response","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r1"}}"#))
    }

    func testParseFileCountsSkipped() throws {
        // No SPM resources declared in Package.swift (so no Bundle.module):
        // resolve the repo-root synthetic fixture by relative path,
        // with an inline fallback when the working directory differs.
        let candidates = [
            URL(fileURLWithPath: "Fixtures/synthetic-codex-sample.jsonl"),
            URL(fileURLWithPath: "token-bar/Fixtures/synthetic-codex-sample.jsonl"),
        ]
        var result: CodexParser.Result?
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                result = CodexParser.parseFile(at: candidate)
                break
            }
        }
        // If no fixture file is visible from this working directory, exercise
        // the same content inline so the case still pins the semantics.
        if result == nil {
            let inline = [
                #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","model":"gpt-5-mini","input_tokens":1200,"output_tokens":340,"session_id":"s1","request_id":"r1"}"#,
                #"{"type":"heartbeat","timestamp":"2026-09-10T09:00:00Z"}"#,
                "not json",
                #"{"type":"token_usage_record","timestamp":"bad","input_tokens":1}"#,
            ]
            var kept = 0, skipped = 0
            for line in inline {
                if CodexParser.parseLine(line) != nil { kept += 1 } else { skipped += 1 }
            }
            XCTAssertEqual(kept, 1)
            XCTAssertEqual(skipped, 3)
            return
        }
        XCTAssertEqual(result?.records.count, 3)
        XCTAssertEqual(result?.skippedLines, 3) // heartbeat + non-json + bad date
    }

    // MARK: - M2 turn_context attribution (synthetic only, never real logs)

    private func writeTempCodexFile(lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("s.jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTurnContextAttributionResolvesModel() throws {
        // Real local shape: usage payload has IDs + nested usage but no
        // model; the model lives on a nearby turn_context record.
        let url = try writeTempCodexFile(lines: [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-1","thread_id":"thread-1","model":"gpt-5.6-sol"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"resp-1","session_id":"sess-1","thread_id":"thread-1","turn_id":"turn-1","usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(result.skippedLines, 1) // turn_context counted, not a record
        // Standalone parseLine stays hermetic: same usage line alone is unknown.
        let usageLine = #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"resp-1","thread_id":"thread-1","turn_id":"turn-1","usage":{"input_tokens":100,"output_tokens":50}}}"#
        XCTAssertEqual(CodexParser.parseLine(usageLine)?.model, "unknown")
    }

    func testTurnContextAliasAndNestedUsage() throws {
        // Alias `model_name` on turn_context + nested payload.usage on the
        // usage record (prompt/completion aliases included).
        let url = try writeTempCodexFile(lines: [
            #"{"payload":{"turn_id":"turn-alias","thread_id":"thread-alias","model_name":"gpt-5.5"},"type":"turn_context","timestamp":"2026-09-10T08:14:00Z"}"#,
            #"{"payload":{"type":"token_usage_record","timestamp":1757325600,"turn_id":"turn-alias","thread_id":"thread-alias","usage":{"prompt_tokens":500,"completion_tokens":150}},"type":"token_usage_record"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.model, "gpt-5.5")
        XCTAssertEqual(result.records.first?.inputTokens, 500)
        XCTAssertEqual(result.records.first?.outputTokens, 150)
        XCTAssertEqual(result.records.first?.totalTokens, 650)
    }

    func testOwnModelWinsOverTurnContext() throws {
        let url = try writeTempCodexFile(lines: [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-own","thread_id":"thread-own","model":"codex-auto-review"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","model":"gpt-5-mini","payload":{"turn_id":"turn-own","thread_id":"thread-own","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.first?.model, "gpt-5-mini")
    }

    func testUnknownFallbackWhenNoAttribution() throws {
        let url = try writeTempCodexFile(lines: [
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-noctx","turn_id":"turn-missing","thread_id":"thread-missing","usage":{"input_tokens":5,"output_tokens":5}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.model, "unknown")
        // Empty model string also coerces to unknown, never empty downstream.
        XCTAssertEqual(CodexParser.parseLine(
            #"{"timestamp":"2026-09-10T08:15:00Z","model":"","input_tokens":5,"output_tokens":5}"#
        )?.model, "unknown")
    }

    func testThreadFallbackSingleModelOnly() throws {
        // No turn match, but the thread has shown exactly one model: fallback applies.
        let fallbackURL = try writeTempCodexFile(lines: [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-a","thread_id":"thread-single","model":"synth-model-a"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-fb","thread_id":"thread-single","usage":{"input_tokens":7,"output_tokens":3}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: fallbackURL.deletingLastPathComponent()) }
        XCTAssertEqual(CodexParser.parseFile(at: fallbackURL).records.first?.model, "synth-model-a")

        // Ambiguous thread (two models): never guess, stay unknown.
        let ambiguousURL = try writeTempCodexFile(lines: [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:13:00Z","payload":{"turn_id":"turn-1","thread_id":"thread-mixed","model":"synth-model-a"}}"#,
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-2","thread_id":"thread-mixed","model":"synth-model-b"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-amb","thread_id":"thread-mixed","usage":{"input_tokens":7,"output_tokens":3}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: ambiguousURL.deletingLastPathComponent()) }
        XCTAssertEqual(CodexParser.parseFile(at: ambiguousURL).records.first?.model, "unknown")
    }

    func testLatestTurnMappingWins() throws {
        let url = try writeTempCodexFile(lines: [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:13:00Z","payload":{"turn_id":"turn-latest","thread_id":"thread-1","model":"synth-model-old"}}"#,
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-latest","thread_id":"thread-1","model":"synth-model-new"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-latest","turn_id":"turn-latest","thread_id":"thread-1","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(CodexParser.parseFile(at: url).records.first?.model, "synth-model-new")
    }

    func testExactModelGroupingAndSorting() throws {
        // Raw strings (prefixes/suffixes) group exactly; no truncation.
        let url = try writeTempCodexFile(lines: [
            #"{"type":"turn_context","timestamp":"2026-09-10T07:00:00Z","payload":{"turn_id":"t1","thread_id":"th1","model":"synth-provider/synth-model-v1"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r1","turn_id":"t1","thread_id":"th1","usage":{"input_tokens":100,"output_tokens":0,"total_tokens":100}}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:16:00Z","model":"synth-provider/synth-model-v1-suffix","payload":{"response_id":"r2","usage":{"input_tokens":50,"output_tokens":0,"total_tokens":50}}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:17:00Z","payload":{"response_id":"r3","usage":{"input_tokens":200,"output_tokens":0,"total_tokens":200}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let stats = Aggregator.aggregate(result.records, calendar: calendar)
        // Exact keys preserved, sorted tokens desc then key asc.
        XCTAssertEqual(stats.byModel.map(\.key),
                       ["unknown", "synth-provider/synth-model-v1", "synth-provider/synth-model-v1-suffix"])
        XCTAssertEqual(stats.byModel.map(\.totalTokens), [200, 100, 50])
        XCTAssertNotNil(stats.byModel.first(where: { $0.key == "unknown" }))
    }

    func testAttributionEmitsNoPromptsOrPaths() throws {
        let secretPrompt = "SECRET-PROMPT-\(UUID().uuidString)"
        let url = try writeTempCodexFile(lines: [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-priv","thread_id":"thread-priv","model":"synth-model-priv","prompt":"\#(secretPrompt)","path":"/Users/someone/.codex/secret"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"resp-priv","turn_id":"turn-priv","thread_id":"thread-priv","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.model, "synth-model-priv")
        let record = result.records.first!
        XCTAssertFalse(record.model.contains(secretPrompt))
        XCTAssertFalse(record.sessionId.contains("/Users/"))
        XCTAssertFalse(record.requestId.contains("/Users/"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let section = ReportFormatter.section(
            records: result.records, source: .all, preset: .lifetime,
            now: Date(timeIntervalSince1970: 1_789_041_600), calendar: calendar)
        let text = ReportFormatter.render(section: section)
        XCTAssertFalse(text.contains(secretPrompt))
        XCTAssertFalse(text.contains("/Users/someone"))
        let json = try ReportFormatter.encodeJSON(sections: [section], warnings: [])
        XCTAssertFalse(json.contains(secretPrompt))
        XCTAssertFalse(json.contains("/Users/someone"))
    }
}
