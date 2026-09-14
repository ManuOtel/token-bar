import Foundation
import XCTest
@testable import TokenBarCore

/// Hermetic tests for the bounded-parallel JSONL slice.
///
/// No timing assertions: concurrency is exercised through deterministic
/// ordering and aggregate-count contracts, plus the pure ordered-merge
/// helper. All fixtures are synthetic temp files, never real logs.
final class ParallelFileParseTests: XCTestCase {
    // MARK: - Pure helper

    func testMergeOrderedConcatenatesInOrderAndSumsSkipped() {
        let merged: ([String], Int) = ParallelFileParse.mergeOrdered(
            chunks: [["a1", "a2"], [], ["b1"]],
            skipped: [1, 0, 2]
        )
        XCTAssertEqual(merged.0, ["a1", "a2", "b1"])
        XCTAssertEqual(merged.1, 3)
    }

    func testMergeOrderedEmpty() {
        let merged: ([Int], Int) = ParallelFileParse.mergeOrdered(chunks: [], skipped: [])
        XCTAssertEqual(merged.0, [])
        XCTAssertEqual(merged.1, 0)
    }

    func testDefaultMaxWorkersIsBounded() {
        // Documented bound: at least 1, at most 8, never above CPU count.
        // No timing here; this pins the "bounded" part of the contract.
        let workers = ParallelFileParse.defaultMaxWorkers
        XCTAssertGreaterThanOrEqual(workers, 1)
        XCTAssertLessThanOrEqual(workers, 8)
        XCTAssertLessThanOrEqual(workers, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    func testMapOrderedPreservesInputOrder() {
        let files = (0..<20).map { URL(fileURLWithPath: "/tmp/synth-\($0).jsonl") }
        let out = ParallelFileParse.mapOrdered(files: files, maxWorkers: 4) { url in
            url.lastPathComponent
        }
        XCTAssertEqual(out, files.map(\.lastPathComponent))
        // Single-worker path stays sequential and identical.
        let seq = ParallelFileParse.mapOrdered(files: files, maxWorkers: 1) { url in
            url.lastPathComponent
        }
        XCTAssertEqual(seq, out)
    }

    func testSortedJSONLFilesSortsAndIgnoresNonJSONL() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("ignore.txt"), atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("c.JSONL"), atomically: true, encoding: .utf8)
        let files = ParallelFileParse.sortedJSONLFiles(root: root)
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.jsonl", "b.jsonl", "c.JSONL"])
    }

    // MARK: - Codex directory

    func testCodexDirectoryOrderingAndCounts() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Created out of order on purpose; sorted merge must still win.
        try codexLine(requestId: "r-b1", input: 10).write(
            to: root.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        try [codexLine(requestId: "r-a1", input: 1), codexLine(requestId: "r-a2", input: 2), "not json"]
            .joined(separator: "\n").appending("\n").write(
                to: root.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try [codexLine(requestId: "r-c1", input: 3), #"{"type":"heartbeat"}"#]
            .joined(separator: "\n").appending("\n").write(
                to: sub.appendingPathComponent("c.jsonl"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("skip.txt"), atomically: true, encoding: .utf8)

        let result = CodexParser.parseDirectory(root: root)
        XCTAssertEqual(result.records.map(\.requestId), ["r-a1", "r-a2", "r-b1", "r-c1"])
        XCTAssertEqual(result.skippedLines, 2) // "not json" + heartbeat

        // Parity with a sequential per-file merge over the same sorted list.
        let files = ParallelFileParse.sortedJSONLFiles(root: root)
        let perFile = files.map { CodexParser.parseFile(at: $0) }
        let expected = ParallelFileParse.mergeOrdered(
            chunks: perFile.map(\.records), skipped: perFile.map(\.skippedLines))
        XCTAssertEqual(result.records.map(\.id), expected.records.map(\.id))
        XCTAssertEqual(result.skippedLines, expected.skippedLines)
    }

    func testCodexTurnContextStaysScopedToItsFile() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // File A sorts first and carries turn-1 -> model-a. File B reuses
        // the same turn id with no context: it must stay unknown, proving
        // attribution state never leaks across files under parallelism.
        try [
            #"{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z","payload":{"turn_id":"turn-1","thread_id":"thread-1","model":"synth-model-a"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-a","turn_id":"turn-1","thread_id":"thread-1","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        ].joined(separator: "\n").appending("\n").write(
            to: root.appendingPathComponent("a-context.jsonl"), atomically: true, encoding: .utf8)
        try [
            #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"r-b","turn_id":"turn-1","thread_id":"thread-1","usage":{"input_tokens":7,"output_tokens":3}}}"#,
        ].joined(separator: "\n").appending("\n").write(
            to: root.appendingPathComponent("b-noctx.jsonl"), atomically: true, encoding: .utf8)

        let result = CodexParser.parseDirectory(root: root)
        XCTAssertEqual(result.records.count, 2)
        let byRequest = Dictionary(uniqueKeysWithValues: result.records.map { ($0.requestId, $0.model) })
        XCTAssertEqual(byRequest["r-a"], "synth-model-a")
        XCTAssertEqual(byRequest["r-b"], "unknown")
        XCTAssertEqual(result.skippedLines, 1) // the turn_context line
        // Deterministic file order: context file first.
        XCTAssertEqual(result.records.map(\.requestId), ["r-a", "r-b"])
    }

    // MARK: - Claude directory

    func testClaudeDirectoryOrderingAndCounts() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try [claudeLine(id: "msg-b1"), #"{"type":"user"}"#].joined(separator: "\n").appending("\n").write(
            to: root.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        try [claudeLine(id: "msg-a1"), claudeLine(id: "msg-a2"), "not json"].joined(separator: "\n").appending("\n").write(
            to: root.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let result = ClaudeParser.parseDirectory(root: root)
        XCTAssertEqual(result.records.map(\.requestId), ["msg-a1", "msg-a2", "msg-b1"])
        XCTAssertEqual(result.skippedLines, 2) // user line + non-json
        XCTAssertTrue(result.records.allSatisfy { $0.source == .claude })

        let files = ParallelFileParse.sortedJSONLFiles(root: root)
        let rootPath = root.standardizedFileURL.path
        let perFile = files.map {
            ClaudeParser.parseFile(at: $0, fileId: ClaudeParser.relativePath(of: $0, to: rootPath))
        }
        let expected = ParallelFileParse.mergeOrdered(
            chunks: perFile.map(\.records), skipped: perFile.map(\.skippedLines))
        XCTAssertEqual(result.records.map(\.id), expected.records.map(\.id))
        XCTAssertEqual(result.skippedLines, expected.skippedLines)
    }

    // MARK: - Helpers (synthetic only)

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-parallel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func codexLine(requestId: String, input: Int) -> String {
        #"{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z","payload":{"response_id":"\#(requestId)","usage":{"input_tokens":\#(input),"output_tokens":1}}}"#
    }

    private func claudeLine(id: String) -> String {
        #"{"type":"assistant","timestamp":"2026-09-10T08:15:00Z","sessionId":"s","message":{"model":"m","id":"\#(id)","usage":{"input_tokens":10,"output_tokens":5}}}"#
    }
}
