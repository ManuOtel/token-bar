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
}
