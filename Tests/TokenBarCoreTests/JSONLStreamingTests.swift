import Foundation
import XCTest
@testable import TokenBarCore

/// Hermetic tests for the bounded-memory JSONL streaming slice.
///
/// Every fixture is synthetic temp data, never real logs. No timing
/// assertions: allocation reduction is demonstrated by the deterministic
/// count-only `scripts/bench-jsonl-streaming.py`, not by wall-clock.
final class JSONLStreamingTests: XCTestCase {
    // MARK: - Helpers (synthetic only)

    private func writeTempFile(named name: String, bytes: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func codexUsageLine(requestId: String?, input: Int, output: Int = 1) -> String {
        if let requestId {
            return #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"\#(requestId)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
        }
        return #"{"timestamp":"2026-09-10T08:15:00Z","input_tokens":\#(input),"output_tokens":\#(output)}"#
    }

    private func claudeLine(id: String?, input: Int = 10, output: Int = 5) -> String {
        if let id {
            return #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
        }
        return #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    // MARK: - Codex CRLF + unterminated + skipped counts

    func testCodexCRLFPreservesPhantomLineNumbers() throws {
        // Exact components(.newlines) parity: each CRLF break yields a
        // phantom empty component that consumes a line number, so the
        // second record keeps the old :3 fallback id (not a dense :2).
        let bytes = (codexUsageLine(requestId: nil, input: 10) + "\r\n"
            + codexUsageLine(requestId: nil, input: 20) + "\r\n").data(using: .utf8)!
        let url = try writeTempFile(named: "s.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.skippedLines, 0)
        XCTAssertEqual(result.records.map(\.id), ["codex:s.jsonl:1", "codex:s.jsonl:3"])
        XCTAssertEqual(result.records.map(\.inputTokens), [10, 20])
    }

    func testCodexFinalLineWithoutNewline() throws {
        let bytes = (codexUsageLine(requestId: "r-1", input: 5) + "\n"
            + codexUsageLine(requestId: "r-2", input: 7)).data(using: .utf8)! // no trailing newline
        let url = try writeTempFile(named: "s.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.map(\.requestId), ["r-1", "r-2"])
        XCTAssertEqual(result.skippedLines, 0)
    }

    func testCodexBlankMalformedSkippedCountsAndLineIDs() throws {
        // Blanks (empty + spaces-only) are free; malformed JSON and the
        // type-gated heartbeat each count one skip. The id-less record on
        // logical line 3 keeps its exact fallback id.
        let lines = [
            "",
            "   ",
            codexUsageLine(requestId: nil, input: 4),
            "not json",
            #"{"type":"heartbeat","timestamp":"2026-09-10T09:00:00Z"}"#,
            codexUsageLine(requestId: "r-kept", input: 9),
        ]
        let url = try writeTempFile(
            named: "s.jsonl", bytes: (lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.skippedLines, 2) // "not json" + heartbeat
        XCTAssertEqual(result.records.map(\.id), ["codex:s.jsonl:3", "codex:r-kept"])
    }

    func testCodexAttributionAcrossStreamedLines() throws {
        // Forward-only attribution through the stream: context before usage
        // resolves, context after usage does not leak backwards.
        let forward = try writeTempFile(named: "s.jsonl", bytes: [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-1","thread_id":"thread-1","model":"synth-model-stream"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-fwd","turn_id":"turn-1","thread_id":"thread-1","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ].joined(separator: "\n").appending("\n").data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: forward.deletingLastPathComponent()) }
        let forwardResult = CodexParser.parseFile(at: forward)
        XCTAssertEqual(forwardResult.records.first?.model, "synth-model-stream")
        XCTAssertEqual(forwardResult.skippedLines, 1)

        let backward = try writeTempFile(named: "s.jsonl", bytes: [
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-bwd","turn_id":"turn-9","thread_id":"thread-9","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"turn_context","timestamp":"2026-09-10T08:16:00Z","payload":{"turn_id":"turn-9","thread_id":"thread-9","model":"synth-model-late"}}"#,
        ].joined(separator: "\n").appending("\n").data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: backward.deletingLastPathComponent()) }
        let backwardResult = CodexParser.parseFile(at: backward)
        XCTAssertEqual(backwardResult.records.first?.model, "unknown")
        XCTAssertEqual(backwardResult.skippedLines, 1)
    }

    func testCodexLFAndCRLFRecordsParitySeparatelyFromIDs() throws {
        // Same logical lines with LF vs CRLF endings decode to identical
        // records (request ids, models, totals) with identical skipped
        // counts. Fallback ids for id-less records intentionally differ by
        // the old CRLF phantom gap (:3 LF vs :5 CRLF); that gap IS the
        // preserved behavior, pinned here rather than erased.
        let logical = [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"t","thread_id":"th","model":"synth-model-parity"}}"#,
            codexUsageLine(requestId: "r-par", input: 11),
            codexUsageLine(requestId: nil, input: 13),
        ]
        let lf = try writeTempFile(named: "s.jsonl", bytes: (logical.joined(separator: "\n") + "\n").data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: lf.deletingLastPathComponent()) }
        let crlf = try writeTempFile(named: "s.jsonl", bytes: (logical.joined(separator: "\r\n") + "\r\n").data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: crlf.deletingLastPathComponent()) }
        let lfResult = CodexParser.parseFile(at: lf)
        let crlfResult = CodexParser.parseFile(at: crlf)
        // Records parity: request ids, models, and token math agree.
        XCTAssertEqual(lfResult.records.map(\.requestId), crlfResult.records.map(\.requestId))
        XCTAssertEqual(lfResult.records.map(\.model), crlfResult.records.map(\.model))
        XCTAssertEqual(lfResult.records.map(\.totalTokens), crlfResult.records.map(\.totalTokens))
        XCTAssertEqual(lfResult.skippedLines, crlfResult.skippedLines)
        // Fallback-id gap parity: the id-less record sits on component 3
        // under LF and component 5 under CRLF (phantom empties at 2 and 4).
        XCTAssertEqual(lfResult.records.map(\.id), ["codex:r-par", "codex:s.jsonl:3"])
        XCTAssertEqual(crlfResult.records.map(\.id), ["codex:r-par", "codex:s.jsonl:5"])
    }

    func testLoneCRSeparatorsSplitLikeComponents() throws {
        // Lone CR (no LF) is a separator under .newlines, not content: if
        // it were kept inside the line, the whole blob would be one
        // malformed line and zero records would survive.
        let bytes = (codexUsageLine(requestId: "r-a", input: 1) + "\r"
            + "not json" + "\r"
            + codexUsageLine(requestId: "r-b", input: 2) + "\r").data(using: .utf8)!
        let url = try writeTempFile(named: "s.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.map(\.requestId), ["r-a", "r-b"])
        XCTAssertEqual(result.skippedLines, 1) // "not json"
    }

    func testUnicodeNewlineSeparatorsSplit() throws {
        // VT, FF, NEL, LS, and PS all split under .newlines. Five records
        // joined only by these separators must decode as five lines, and
        // the id-less record keeps its exact component fallback id.
        let nel = "\u{85}"
        let ls = "\u{2028}"
        let ps = "\u{2029}"
        let bytes = (codexUsageLine(requestId: "r-u1", input: 1) + ls
            + "not json" + nel
            + codexUsageLine(requestId: nil, input: 3) + ps
            + codexUsageLine(requestId: "r-u4", input: 4) + "\u{0B}"
            + codexUsageLine(requestId: "r-u5", input: 5) + "\u{0C}").data(using: .utf8)!
        let url = try writeTempFile(named: "s.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.map(\.id),
                       ["codex:r-u1", "codex:s.jsonl:3", "codex:r-u4", "codex:r-u5"])
        XCTAssertEqual(result.skippedLines, 1) // "not json"
    }

    // MARK: - Claude streaming parity

    func testClaudeCRLFAndUnterminatedParity() throws {
        // CRLF pair plus an unterminated final line: all three logical
        // lines decode, the user line counts one skip, and the id-less
        // fallback keeps the exact old component number (:5, with phantom
        // empties at 2 and 4), not a dense :3.
        let bytes = (claudeLine(id: "msg-a") + "\r\n"
            + #"{"type":"user","timestamp":"2026-09-10T09:00:00Z","message":{}}"# + "\r\n"
            + claudeLine(id: nil, input: 3, output: 2)).data(using: .utf8)! // no trailing newline
        let url = try writeTempFile(named: "c.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = ClaudeParser.parseFile(at: url, fileId: "c.jsonl")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.skippedLines, 1)
        XCTAssertEqual(result.records.map(\.id), ["claude:msg-a", "claude:c.jsonl:5"])
    }

    func testClaudeBlankMalformedSkippedCounts() throws {
        let lines = [
            "",
            "  \t  ",
            claudeLine(id: "msg-1"),
            "not json",
            #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","message":{"model":"m","id":"x"}}"#, // no usage
            claudeLine(id: nil),
        ]
        let url = try writeTempFile(
            named: "c.jsonl", bytes: (lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = ClaudeParser.parseFile(at: url, fileId: "c.jsonl")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.skippedLines, 2) // non-json + no-usage
        XCTAssertEqual(result.records.last?.id, "claude:c.jsonl:6")
    }

    // MARK: - Reader edge cases

    func testReaderWholeFileInvalidUTF8() throws {
        // Strict whole-file UTF-8 is preserved: any undecodable line drops
        // the entire file to ([], 0), exactly like String(contentsOf: .utf8).
        var bytes = codexUsageLine(requestId: "r-good", input: 5).data(using: .utf8)!
        bytes.append(contentsOf: "\n".data(using: .utf8)!)
        bytes.append(contentsOf: [0x7B, 0x22, 0xFF, 0xFE, 0x7D, 0x0A]) // "{".<invalid>."}\n"
        bytes.append(contentsOf: codexUsageLine(requestId: "r-late", input: 6).data(using: .utf8)!)
        bytes.append(contentsOf: "\n".data(using: .utf8)!)
        let codexURL = try writeTempFile(named: "s.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: codexURL.deletingLastPathComponent()) }
        let codexResult = CodexParser.parseFile(at: codexURL)
        XCTAssertEqual(codexResult.records.count, 0)
        XCTAssertEqual(codexResult.skippedLines, 0)

        let claudeURL = try writeTempFile(named: "c.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: claudeURL.deletingLastPathComponent()) }
        let claudeResult = ClaudeParser.parseFile(at: claudeURL, fileId: "c.jsonl")
        XCTAssertEqual(claudeResult.records.count, 0)
        XCTAssertEqual(claudeResult.skippedLines, 0)

        var emitted = 0
        XCTAssertFalse(JSONLLineReader.forEachLine(at: codexURL) { _, _ in emitted += 1 })
    }

    func testReaderEmptyAndNewlineOnlyFiles() throws {
        let empty = try writeTempFile(named: "s.jsonl", bytes: Data())
        defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }
        let emptyResult = CodexParser.parseFile(at: empty)
        XCTAssertEqual(emptyResult.records.count, 0)
        XCTAssertEqual(emptyResult.skippedLines, 0)

        let newlines = try writeTempFile(named: "s.jsonl", bytes: "\n\n".data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: newlines.deletingLastPathComponent()) }
        let newlinesResult = CodexParser.parseFile(at: newlines)
        XCTAssertEqual(newlinesResult.records.count, 0)
        XCTAssertEqual(newlinesResult.skippedLines, 0)

        var count = 0
        XCTAssertTrue(JSONLLineReader.forEachLine(at: empty) { _, _ in count += 1 })
        XCTAssertEqual(count, 0)
    }

    func testReaderLongLineAcrossChunkBoundary() throws {
        // A single line far larger than the 64 KiB chunk proves the reader
        // reassembles split lines; multi-byte UTF-8 at the boundary stays
        // intact (emoji payload inside a JSON string value).
        let padding = String(repeating: "é", count: 40_000) // 80 KB as UTF-8
        let line = #"{"timestamp":"2026-09-10T08:15:00Z","input_tokens":5,"output_tokens":5,"note":"\#(padding)😀"}"#
        XCTAssertGreaterThan(line.data(using: .utf8)!.count, JSONLLineReader.chunkSize)
        let bytes = (line + "\n" + codexUsageLine(requestId: "r-tail", input: 2) + "\n").data(using: .utf8)!
        let url = try writeTempFile(named: "s.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.skippedLines, 0)
        XCTAssertEqual(result.records.map(\.id), ["codex:s.jsonl:1", "codex:r-tail"])
    }

    func testSeparatorSplitAcrossChunkBoundary() throws {
        // The 3-byte U+2028 separator starts on the last byte of the first
        // 64 KiB chunk: the reader must hold it via the carry and still
        // split there. A broken carry would glue the bytes onto the first
        // line, fail strict UTF-8, and drop the whole file to ([], 0).
        let filler = String(repeating: "x", count: JSONLLineReader.chunkSize - 1)
        XCTAssertEqual(filler.data(using: .utf8)!.count, JSONLLineReader.chunkSize - 1)
        let bytes = (filler + "\u{2028}"
            + codexUsageLine(requestId: "r-tail", input: 2) + "\n").data(using: .utf8)!
        let url = try writeTempFile(named: "s.jsonl", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.map(\.requestId), ["r-tail"])
        XCTAssertEqual(result.skippedLines, 1) // the filler line is non-JSON
    }

    func testReaderMissingFileKeepsEmptyResult() {        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-missing-\(UUID().uuidString).jsonl")
        XCTAssertEqual(CodexParser.parseFile(at: missing).records.count, 0)
        XCTAssertEqual(CodexParser.parseFile(at: missing).skippedLines, 0)
        XCTAssertEqual(ClaudeParser.parseFile(at: missing).records.count, 0)
        var called = false
        XCTAssertFalse(JSONLLineReader.forEachLine(at: missing) { _, _ in called = true })
        XCTAssertFalse(called)
    }

    func testStreamingAttributionEmitsNoPromptsOrPaths() throws {
        // Privacy pin through the streaming path: model attribution still
        // retains only the model string, never prompt text or filesystem
        // paths, in records or rendered output.
        let secret = "SECRET-STREAM-\(UUID().uuidString)"
        let url = try writeTempFile(named: "s.jsonl", bytes: [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-s","thread_id":"thread-s","model":"synth-model-s","prompt":"\#(secret)","path":"/Users/someone/.codex/secret"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-s","turn_id":"turn-s","thread_id":"thread-s","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ].joined(separator: "\n").appending("\n").data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = CodexParser.parseFile(at: url)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.model, "synth-model-s")
        XCTAssertFalse(result.records.first!.model.contains(secret))
        XCTAssertFalse(result.records.first!.sessionId.contains("/Users/"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let section = ReportFormatter.section(
            records: result.records, source: .all, preset: .lifetime,
            now: Date(timeIntervalSince1970: 1_789_041_600), calendar: calendar)
        XCTAssertFalse(ReportFormatter.render(section: section).contains(secret))
    }
}
