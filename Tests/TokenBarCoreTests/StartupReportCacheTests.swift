import Foundation
import XCTest
@testable import TokenBarCore

/// Startup usage cache: perceived-startup only, privacy-safe by construction.
///
/// Hermetic, no real histories, no timing thresholds: every test uses
/// synthetic records plus temporary directories (injectable FileManager/URL
/// parameters), never `~/.codex`, `opencode.db`, or `~/.claude`.
final class StartupReportCacheTests: XCTestCase {
    private var now: Date {
        Date(timeIntervalSince1970: 1_789_041_600) // 2026-09-10T12:00:00Z
    }

    private func record(
        _ id: String, source: UsageSource = .opencode,
        model: String = "openai/gpt-5.6-luna", origin: String = "remote",
        input: Int = 1000, output: Int = 250
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: source, timestamp: now,
            model: model, inputTokens: input, outputTokens: output,
            cachedTokens: 100, reasoningTokens: 10,
            totalTokens: 0, sessionId: "sess-\(id)", requestId: "req-\(id)",
            origin: origin)
    }

    private func tempURL(_ name: String = "startup-report.json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nested/dir/\(name)")
    }

    // MARK: - Round trip preserves totals and labels

    func testRoundTripPreservesTotalsAndLabels() throws {
        let report = LoadReport(
            records: [
                record("a", source: .codex, model: "gpt-5-mini", origin: "local"),
                record("b", source: .opencode, model: "openai/gpt-5.6-luna", origin: "remote"),
                record("c", source: .claude, model: "claude-sonnet-4-x", origin: "local"),
            ],
            skippedCodexLines: 3,
            skippedOpenCodeRows: 5,
            warnings: ["OpenCode snapshot unreadable; others still load."],
            skippedClaudeLines: 7)
        let url = tempURL()
        try StartupReportCache.save(report, to: url, now: now)
        let loaded = StartupReportCache.load(from: url)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.records.count, 3)
        XCTAssertEqual(loaded?.skippedCodexLines, 3)
        XCTAssertEqual(loaded?.skippedOpenCodeRows, 5)
        XCTAssertEqual(loaded?.skippedClaudeLines, 7)
        // Token totals and labels survive byte-for-byte.
        XCTAssertEqual(
            loaded?.records.map(\.totalTokens).sorted(),
            report.records.map(\.totalTokens).sorted())
        XCTAssertEqual(
            loaded?.records.map(\.model).sorted(),
            ["claude-sonnet-4-x", "gpt-5-mini", "openai/gpt-5.6-luna"])
        XCTAssertEqual(
            loaded?.records.map(\.origin).sorted(),
            ["local", "local", "remote"])
        XCTAssertEqual(
            loaded?.records.map(\.source).sorted(by: { $0.rawValue < $1.rawValue }),
            [.claude, .codex, .opencode])
        // Aggregation over the cached report matches the fresh report.
        let freshStats = Aggregator.aggregate(report.records)
        let cachedStats = Aggregator.aggregate(loaded!.records)
        XCTAssertEqual(cachedStats.totalTokens, freshStats.totalTokens)
        XCTAssertEqual(cachedStats.requests, freshStats.requests)
        XCTAssertEqual(cachedStats.bySource, freshStats.bySource)
        XCTAssertEqual(cachedStats.byOrigin, freshStats.byOrigin)
    }

    func testMissingFileLoadsNil() {
        XCTAssertNil(StartupReportCache.load(from: tempURL()))
    }

    // MARK: - Version and corrupt input rejected gracefully

    func testWrongVersionRejected() throws {
        let url = tempURL()
        let bad = """
        {"version":999,"savedAt":"2026-09-10T12:00:00Z","report":{"records":[],"skippedCodexLines":0,"skippedOpenCodeRows":0,"skippedClaudeLines":0,"warnings":[]}}
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bad.write(to: url, options: .atomic)
        XCTAssertNil(StartupReportCache.load(from: url))
        XCTAssertThrowsError(try StartupReportCache.decode(bad))
    }

    func testCorruptPayloadRejected() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for payload in ["not json".data(using: .utf8)!, Data([0x00, 0x01, 0x02]), Data()] {
            try payload.write(to: url, options: .atomic)
            XCTAssertNil(StartupReportCache.load(from: url), "payload \(payload.count) bytes")
        }
        XCTAssertThrowsError(try StartupReportCache.decode("not json".data(using: .utf8)!))
    }

    func testTruncatedEnvelopeRejected() throws {
        let report = LoadReport(
            records: [record("a")], skippedCodexLines: 0,
            skippedOpenCodeRows: 0, warnings: [], skippedClaudeLines: 0)
        let full = try StartupReportCache.encode(report, now: now)
        let truncated = full.prefix(max(0, full.count / 2))
        XCTAssertThrowsError(try StartupReportCache.decode(Data(truncated)))
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(truncated).write(to: url, options: .atomic)
        XCTAssertNil(StartupReportCache.load(from: url))
    }

    // MARK: - Privacy: no raw paths or prompt-shaped fields retained

    func testEncodedCacheRetainsNoRawPathsOrPromptFields() throws {
        let rawPathWarning = "Codex sessions not found at /Users/someone/.codex/sessions."
        let rawDBWarning = "OpenCode database not found at /tmp/secret-host/opencode.db."
        let report = LoadReport(
            records: [record("a")],
            skippedCodexLines: 0, skippedOpenCodeRows: 0,
            warnings: [rawPathWarning, rawDBWarning],
            skippedClaudeLines: 0)
        let url = tempURL()
        try StartupReportCache.save(report, to: url, now: now)
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Absolute input paths are sanitized before persistence.
        XCTAssertFalse(raw.contains("/Users/someone"))
        XCTAssertFalse(raw.contains("/tmp/secret-host"))
        XCTAssertFalse(raw.contains(".codex/sessions"))
        // Sanitized generic labels survive instead.
        XCTAssertTrue(raw.contains("TOKENBAR_CODEX_ROOT") || raw.contains("Codex sessions not found"))
        // Envelope carries only normalized keys: no prompt, message-body,
        // tool I/O, credential, or raw-blob field names.
        let lowered = raw.lowercased()
        for leaked in ["\"prompt\"", "\"prompt_text\"", "\"content\"", "\"tool_input\"",
                       "\"tool_output\"", "\"file_path\"", "\"credential\"",
                       "\"authorization\"", "\"cookie\"", "\"message_body\""] {
            XCTAssertFalse(lowered.contains(leaked), "cache leaks \(leaked)")
        }
        // Loaded warnings stay sanitized too.
        let loaded = StartupReportCache.load(from: url)!
        for warning in loaded.warnings {
            XCTAssertFalse(warning.contains("/Users/someone"))
            XCTAssertFalse(warning.contains("/tmp/secret-host"))
        }
    }

    // MARK: - Initial refresh and last-write-wins

    func testInitialRefreshFiresExactlyOnce() {
        var state = StartupRefreshState()
        // First appearance triggers even when cached records exist.
        XCTAssertNotNil(state.beginInitial())
        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(state.didStartInitial)
        // Menu re-opens never trigger again; manual path also blocked
        // while the first scan is in flight.
        XCTAssertNil(state.beginInitial())
        XCTAssertNil(state.beginManual())
        // Fresh completion clears loading; nothing else starts afterwards.
        XCTAssertTrue(state.finish(generation: state.generation))
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.beginInitial())
        // Manual refresh works again once idle.
        XCTAssertNotNil(state.beginManual())
    }

    func testStaleGenerationNeverApplies() {
        var state = StartupRefreshState()
        let first = state.beginInitial()!
        // A superseding scan starts (lifecycle edge): the first generation
        // is now stale and must be dropped.
        let second = state.beginForced()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.finish(generation: first))
        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(state.finish(generation: second))
        XCTAssertFalse(state.isLoading)
    }

    func testManualBlockedWhileLoading() {
        var state = StartupRefreshState()
        XCTAssertNotNil(state.beginManual())
        XCTAssertNil(state.beginManual())
        let current = state.generation
        XCTAssertTrue(state.finish(generation: current))
        XCTAssertNotNil(state.beginManual())
    }

    // MARK: - Single-seed initial state

    func testInitialStateDerivesBothValuesFromOneSeed() {
        // First run (no cache): empty report, no stale banner.
        let empty = StartupReportCache.initialState(cached: nil)
        XCTAssertTrue(empty.report.records.isEmpty)
        XCTAssertFalse(empty.isShowingStaleCache)
        // Cached but record-empty: the cached report itself (warnings kept),
        // still no stale banner so the empty + loading path is preserved.
        let cachedEmpty = LoadReport(
            records: [], skippedCodexLines: 1, skippedOpenCodeRows: 2,
            warnings: ["OpenCode snapshot unreadable; others still load."],
            skippedClaudeLines: 3)
        let fromEmpty = StartupReportCache.initialState(cached: cachedEmpty)
        XCTAssertEqual(fromEmpty.report, cachedEmpty)
        XCTAssertFalse(fromEmpty.isShowingStaleCache)
        // Cached with records: the same report with the stale banner on.
        let cached = LoadReport(
            records: [record("a")], skippedCodexLines: 0,
            skippedOpenCodeRows: 0, warnings: [], skippedClaudeLines: 0)
        let fromCached = StartupReportCache.initialState(cached: cached)
        XCTAssertEqual(fromCached.report, cached)
        XCTAssertTrue(fromCached.isShowingStaleCache)
    }
}
