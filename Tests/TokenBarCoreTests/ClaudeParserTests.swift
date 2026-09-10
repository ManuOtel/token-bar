import Foundation
import XCTest
@testable import TokenBarCore

/// Synthetic-only Claude Code parser tests. No real logs, no private paths.
final class ClaudeParserTests: XCTestCase {
    func testValidAssistantRecord() {
        let line = #"{"type":"assistant","message":{"model":"claude-sonnet-4-20250514","id":"msg-1","usage":{"input_tokens":1200,"output_tokens":340}},"timestamp":"2026-09-10T08:15:00Z","sessionId":"sess-1","requestId":"req-1"}"#
        let record = ClaudeParser.parseLine(line, fileId: "f.jsonl", lineNumber: 1)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source, .claude)
        XCTAssertEqual(record?.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(record?.inputTokens, 1200)
        XCTAssertEqual(record?.outputTokens, 340)
        XCTAssertEqual(record?.cachedTokens, 0)
        XCTAssertEqual(record?.totalTokens, 1540) // input + output
        XCTAssertEqual(record?.sessionId, "sess-1")
        XCTAssertEqual(record?.requestId, "msg-1") // message id wins
    }

    func testCacheReadPlusCreationFoldedIntoInput() {
        // Anthropic semantics: total input sums raw input plus both cache
        // components, so normalized input folds cache back in (same rule as
        // OpenCode). Cached stays a subset of input by construction.
        let line = #"{"type":"assistant","message":{"model":"m","id":"msg-c","usage":{"input_tokens":1200,"output_tokens":340,"cache_read_input_tokens":200,"cache_creation_input_tokens":50}},"timestamp":"2026-09-10T08:15:00Z","sessionId":"s"}"#
        let record = ClaudeParser.parseLine(line)
        XCTAssertEqual(record?.cachedTokens, 250)
        XCTAssertEqual(record?.inputTokens, 1450) // 1200 raw + 200 read + 50 creation
        XCTAssertEqual(record?.totalTokens, 1790) // normalized input + output
        XCTAssertLessThanOrEqual(record!.cachedTokens, record!.inputTokens)
    }

    func testNonAssistantLinesSkipped() {
        XCTAssertNil(ClaudeParser.parseLine(
            #"{"type":"user","message":{"role":"user"},"timestamp":"2026-09-10T09:00:00Z","sessionId":"s"}"#))
        XCTAssertNil(ClaudeParser.parseLine(
            #"{"type":"summary","summary":"x","timestamp":"2026-09-10T09:00:00Z"}"#))
        XCTAssertNil(ClaudeParser.parseLine(
            #"{"type":"system","message":{"usage":{"input_tokens":1}},"timestamp":"2026-09-10T09:00:00Z"}"#))
    }

    func testMalformedAndMissingUsageSkipped() {
        XCTAssertNil(ClaudeParser.parseLine("not json"))
        XCTAssertNil(ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":"not-a-date","message":{"model":"m","id":"x","usage":{"input_tokens":1}}}"#))
        XCTAssertNil(ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","message":{"model":"m","id":"x"}}"#))
        XCTAssertNil(ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","message":{"model":"m","id":"x","usage":{}}}"#))
    }

    func testNumericOneAcceptedAndTrueRejected() {
        // Darwin bridges any NSNumber holding 0/1 as Bool, so the count
        // gate must use objCType, never `is Bool` (Mac CI regression).
        let ones = ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"one","usage":{"input_tokens":1,"output_tokens":1}}}"#)
        XCTAssertEqual(ones?.inputTokens, 1)
        XCTAssertEqual(ones?.outputTokens, 1)
        XCTAssertEqual(ones?.totalTokens, 2)
        XCTAssertNil(ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"bool","usage":{"input_tokens":true,"output_tokens":true}}}"#))
    }

    func testEpochAndISOTimestamps() {
        let epoch = ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":1757325600,"sessionId":"s","message":{"model":"m","id":"a","usage":{"input_tokens":1,"output_tokens":1}}}"#)
        XCTAssertNotNil(epoch)
        let millis = ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":1757325600000,"sessionId":"s","message":{"model":"m","id":"b","usage":{"input_tokens":1,"output_tokens":1}}}"#)
        XCTAssertNotNil(millis)
        XCTAssertEqual(millis?.timestamp.timeIntervalSince1970 ?? 0, 1757325600, accuracy: 1)
        let iso = ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"c","usage":{"input_tokens":1,"output_tokens":1}}}"#)
        XCTAssertNotNil(iso)
    }

    func testExplicitTotalWins() {
        let line = #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"t","usage":{"input_tokens":800,"output_tokens":200,"cache_read_input_tokens":100,"total_tokens":5000}}}"#
        let record = ClaudeParser.parseLine(line)
        XCTAssertEqual(record?.inputTokens, 900) // 800 raw + 100 cache
        XCTAssertEqual(record?.cachedTokens, 100)
        XCTAssertEqual(record?.totalTokens, 5000)
    }

    func testCacheOnlyRowNormalizesInput() {
        // Cache-only line: normalized input equals cached, total follows.
        let line = #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"co","usage":{"cache_read_input_tokens":300}}}"#
        let record = ClaudeParser.parseLine(line)
        XCTAssertEqual(record?.inputTokens, 300)
        XCTAssertEqual(record?.cachedTokens, 300)
        XCTAssertEqual(record?.totalTokens, 300)
    }

    func testCacheLargerThanRawInputStillFolds() {
        // Live-Mac regression: raw input far smaller than cache must fold,
        // never violate the cached-subset-of-input invariant.
        let line = #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"big","usage":{"input_tokens":200,"output_tokens":50,"cache_read_input_tokens":600,"cache_creation_input_tokens":100}}}"#
        let record = ClaudeParser.parseLine(line)
        XCTAssertEqual(record?.inputTokens, 900) // 200 raw + 600 read + 100 creation
        XCTAssertEqual(record?.cachedTokens, 700)
        XCTAssertEqual(record?.totalTokens, 950) // normalized input + output
        XCTAssertLessThanOrEqual(record!.cachedTokens, record!.inputTokens)
    }

    func testRequestIdFallbackStaysUniqueById() {
        // No message/request id: requestId empty, id falls back to path:line.
        let first = ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            fileId: "f.jsonl", lineNumber: 1)
        let second = ClaudeParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            fileId: "f.jsonl", lineNumber: 2)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.requestId, "")
        XCTAssertNotEqual(first?.id, second?.id)
        // Dedupe keeps both (empty requestId => unique by id).
        XCTAssertEqual(TokenBarStore.dedupe([first!, second!]).count, 2)
    }

    func testDedupeCollapsesSameMessageId() {
        func line(_ id: String) -> String {
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"\#(id)","usage":{"input_tokens":10,"output_tokens":5}}}"#
        }
        let first = ClaudeParser.parseLine(line("msg-dup"), fileId: "a.jsonl", lineNumber: 1)!
        let second = ClaudeParser.parseLine(line("msg-dup"), fileId: "b.jsonl", lineNumber: 7)!
        XCTAssertEqual(TokenBarStore.dedupe([first, second]).count, 1)
        // Same request id on another source stays distinct.
        let codex = NormalizedUsage(
            id: "codex:msg-dup", source: .codex, timestamp: first.timestamp,
            model: "m", inputTokens: 10, outputTokens: 5, cachedTokens: 0,
            reasoningTokens: 0, totalTokens: 0, sessionId: "s", requestId: "msg-dup")
        XCTAssertEqual(TokenBarStore.dedupe([first, codex]).count, 2)
    }

    func testSourceFilterIsolation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        func rec(_ id: String, _ source: UsageSource) -> NormalizedUsage {
            NormalizedUsage(
                id: id, source: source, timestamp: now, model: "m",
                inputTokens: 10, outputTokens: 5, cachedTokens: 0,
                reasoningTokens: 0, totalTokens: 0, sessionId: "s", requestId: id)
        }
        let records = [rec("a", .codex), rec("b", .opencode), rec("c", .claude)]
        XCTAssertEqual(Aggregator.filter(records, source: .claude, preset: .lifetime, now: now, calendar: calendar).map(\.id), ["c"])
        XCTAssertEqual(Aggregator.filter(records, source: .all, preset: .lifetime, now: now, calendar: calendar).count, 3)
        XCTAssertEqual(ReportFormatter.sourceLabel(for: .claude), "claude")
    }

    func testMissingRootWarningSanitized() {
        let raw = "Claude sessions not found at /Users/someone/.claude/projects."
        let clean = ReportFormatter.sanitizeWarning(raw)
        XCTAssertFalse(clean.contains("/Users/someone"))
        XCTAssertFalse(clean.contains("/.claude/"))
        XCTAssertTrue(clean.contains("TOKENBAR_CLAUDE_ROOT"))
    }

    func testFallbackIdsAreRootRelative() throws {
        // Two subdirectories sharing a basename must yield distinct stable
        // ids; labels stay root-relative, never absolute.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-claude-\(UUID().uuidString)", isDirectory: true)
        let subA = root.appendingPathComponent("proj-a", isDirectory: true)
        let subB = root.appendingPathComponent("proj-b", isDirectory: true)
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"# + "\n"
        try line.write(to: subA.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: subB.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ClaudeParser.parseDirectory(root: root)
        XCTAssertEqual(result.records.count, 2)
        let ids = result.records.map(\.id).sorted()
        XCTAssertEqual(ids, ["claude:proj-a/s.jsonl:1", "claude:proj-b/s.jsonl:1"])
        XCTAssertFalse(ids.joined(separator: "\n").contains(root.path))
        // Dedupe keeps both (empty requestId => unique by id).
        XCTAssertEqual(TokenBarStore.dedupe(result.records).count, 2)
        // Outside-root files fall back to the basename, still relative.
        XCTAssertEqual(
            ClaudeParser.relativePath(of: URL(fileURLWithPath: "/elsewhere/x.jsonl"), to: root.path),
            "x.jsonl")
    }

    func testParseFileCountsSkipped() {
        let url = URL(fileURLWithPath: "Fixtures/synthetic-claude-sample.jsonl")
        let candidates = [
            url,
            URL(fileURLWithPath: "token-bar/Fixtures/synthetic-claude-sample.jsonl"),
        ]
        var result: ClaudeParser.Result?
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                result = ClaudeParser.parseFile(at: candidate)
                break
            }
        }
        guard let result else {
            // Working directory without fixture visibility: pin semantics
            // inline so the case still guards the contract.
            let inline = [
                #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","message":{"model":"m","id":"a","usage":{"input_tokens":1,"output_tokens":1}}}"#,
                #"{"type":"user","timestamp":"2026-09-10T09:00:00Z","message":{}}"#,
                "not json",
            ]
            var kept = 0, skipped = 0
            for line in inline {
                if ClaudeParser.parseLine(line) != nil { kept += 1 } else { skipped += 1 }
            }
            XCTAssertEqual(kept, 1)
            XCTAssertEqual(skipped, 2)
            return
        }
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.skippedLines, 5) // user + summary + non-json + bad date + no usage
        XCTAssertTrue(result.records.allSatisfy { $0.source == .claude })
    }
}
