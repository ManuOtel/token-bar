import Foundation
import XCTest
@testable import TokenBarCore

/// Multi-origin OpenCode merge: local DB + homeserver extras/snapshots.
/// Synthetic data only. Identity rules under test:
/// - Same `source + requestId` collapses to larger `totalTokens` (max-total
///   mirror selection); exact ties break to earliest `(timestamp, id)`.
/// - Empty `requestId` rows collapse by `source + id`: cloned id-less rows
///   (identical stable IDs) count once, distinct id-less rows all survive.
/// - Message rows win over rollups for covered sessions across origins;
///   rollups fill uncovered sessions only (via `combineMessageAndRollup`).
final class OpenCodeOriginsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_789_041_600) // 2026-09-10T12:00:00Z
    }

    private func usage(
        _ id: String, request: String, total: Int, session: String = "s",
        origin: String = "local", hoursAgo: Double = 1
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: .opencode,
            timestamp: now.addingTimeInterval(-hoursAgo * 3600),
            model: "m", inputTokens: total, outputTokens: 0, cachedTokens: 0,
            reasoningTokens: 0, totalTokens: total, sessionId: session,
            requestId: request, origin: origin)
    }

    func testOldNormalizedUsageDecodesWithLocalDefault() throws {
        let old = #"{"id":"a","source":"opencode","timestamp":"2026-09-10T08:15:00Z","model":"m","inputTokens":10,"outputTokens":5,"cachedTokens":0,"reasoningTokens":0,"totalTokens":15,"sessionId":"s","requestId":"r"}"#
        let record = try JSONDecoder().decode(NormalizedUsage.self, from: Data(old.utf8))
        XCTAssertEqual(record.origin, "local")
        XCTAssertEqual(record.source, .opencode)
    }

    func testOldAggregatedStatsDecodesWithEmptyByOrigin() throws {
        let stats = AggregatedStats.empty
        var encoded = try JSONEncoder().encode(stats)
        // Strip byOrigin to simulate an old payload.
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "byOrigin")
        encoded = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(AggregatedStats.self, from: encoded)
        XCTAssertEqual(decoded.byOrigin, [])
    }

    func testSplitExtraListIgnoresEmptyEntries() {
        XCTAssertEqual(TokenBarStore.splitExtraList(nil), [])
        XCTAssertEqual(TokenBarStore.splitExtraList(""), [])
        XCTAssertEqual(TokenBarStore.splitExtraList(" , : \n "), [])
        XCTAssertEqual(
            TokenBarStore.splitExtraList("/a.db, ,/b.db::/c.db"),
            ["/a.db", "/b.db", "/c.db"])
    }

    func testMissingExtrasAreWarningsOnly() {
        setenv("TOKENBAR_OPENCODE_DB_EXTRA", "/nonexistent-a.db,/nonexistent-b.db", 1)
        setenv("TOKENBAR_OPENCODE_USAGE_JSON", "/nonexistent-snap.json", 1)
        defer {
            unsetenv("TOKENBAR_OPENCODE_DB_EXTRA")
            unsetenv("TOKENBAR_OPENCODE_USAGE_JSON")
        }
        // Point the primary inputs at empty temp dirs so the test is hermetic.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        setenv("TOKENBAR_CODEX_ROOT", temp.path, 1)
        setenv("TOKENBAR_CLAUDE_ROOT", temp.path, 1)
        setenv("TOKENBAR_OPENCODE_DB", temp.appendingPathComponent("missing.db").path, 1)
        defer {
            unsetenv("TOKENBAR_CODEX_ROOT")
            unsetenv("TOKENBAR_CLAUDE_ROOT")
            unsetenv("TOKENBAR_OPENCODE_DB")
        }
        let report = TokenBarStore.load()
        let clean = ReportFormatter.sanitizeWarnings(report.warnings).joined(separator: "\n")
        XCTAssertTrue(clean.contains("TOKENBAR_OPENCODE_DB_EXTRA"))
        XCTAssertTrue(clean.contains("TOKENBAR_OPENCODE_USAGE_JSON"))
        XCTAssertFalse(clean.contains("/nonexistent-a.db"))
        XCTAssertFalse(clean.contains("/nonexistent-snap.json"))
        // Missing extras never stop the load pass itself.
        XCTAssertNotNil(report.records)
    }

    func testSnapshotDecodePreservesOriginAndSkipsOtherSources() {
        let dict: [String: Any] = [
            "id": "opencode:msg-1", "source": "opencode",
            "timestamp": "2026-09-11T10:00:00Z", "model": "opencode-go/m",
            "inputTokens": 100, "outputTokens": 50, "totalTokens": 150,
            "sessionId": "ses-1", "requestId": "msg-1", "origin": "homeserver",
        ]
        let record = OpenCodeStore.decodeSnapshotRecord(dict)
        XCTAssertEqual(record?.origin, "homeserver")
        XCTAssertEqual(record?.source, .opencode)
        var missingOrigin = dict
        missingOrigin.removeValue(forKey: "origin")
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(missingOrigin)?.origin, "homeserver")
        var codex = dict
        codex["source"] = "codex"
        XCTAssertNil(OpenCodeStore.decodeSnapshotRecord(codex))
        var allZero = dict
        allZero["inputTokens"] = 0
        allZero["outputTokens"] = 0
        allZero["totalTokens"] = 0
        XCTAssertNil(OpenCodeStore.decodeSnapshotRecord(allZero))
    }

    func testSnapshotForbiddenKeysDetected() throws {
        let payload: [[String: Any]] = [[
            "id": "opencode:msg-1", "timestamp": "2026-09-11T10:00:00Z",
            "model": "m", "inputTokens": 10, "outputTokens": 5,
            "sessionId": "s", "requestId": "msg-1", "origin": "homeserver",
            "prompt": "SECRET-PROMPT-XYZ", "path": "/Users/someone/secret",
        ]]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try OpenCodeStore.loadSnapshot(at: url.path)
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertTrue(loaded.sawExtraFields)
        let dump = try JSONEncoder().encode(loaded.records)
        let text = String(data: dump, encoding: .utf8)!
        XCTAssertFalse(text.contains("SECRET-PROMPT-XYZ"))
        XCTAssertFalse(text.contains("/Users/someone"))
    }

    func testCrossOriginDedupeKeepsMaxTotalBothOrders() {
        let local = usage("opencode:msg-1", request: "msg-1", total: 100, origin: "local")
        let remote = NormalizedUsage(
            id: "opencode:msg-1", source: .opencode, timestamp: local.timestamp,
            model: "m", inputTokens: 200, outputTokens: 0, cachedTokens: 0,
            reasoningTokens: 0, totalTokens: 200, sessionId: "s",
            requestId: "msg-1", origin: "homeserver")
        for pair in [[local, remote], [remote, local]] {
            let deduped = TokenBarStore.dedupe(pair)
            XCTAssertEqual(deduped.count, 1)
            XCTAssertEqual(deduped.first?.totalTokens, 200)
        }
    }

    func testCrossOriginTieBreaksToEarliest() {
        let earlier = usage("opencode:a", request: "dup", total: 100, origin: "local", hoursAgo: 2)
        let later = usage("opencode:b", request: "dup", total: 100, origin: "homeserver", hoursAgo: 1)
        for pair in [[earlier, later], [later, earlier]] {
            let deduped = TokenBarStore.dedupe(pair)
            XCTAssertEqual(deduped.count, 1)
            XCTAssertEqual(deduped.first?.timestamp, earlier.timestamp)
        }
    }

    func testIDLessClonesCollapseButDistinctSurvive() {
        let cloneA = usage("opencode:same", request: "", total: 15, origin: "local")
        let cloneB = usage("opencode:same", request: "", total: 15, origin: "homeserver")
        XCTAssertEqual(TokenBarStore.dedupe([cloneA, cloneB]).count, 1)
        let distinctA = usage("opencode:id-a", request: "", total: 15, origin: "local")
        let distinctB = usage("opencode:id-b", request: "", total: 15, origin: "homeserver")
        XCTAssertEqual(TokenBarStore.dedupe([distinctA, distinctB]).count, 2)
    }

    func testCoveredRollupDroppedAcrossOrigins() {
        let message = usage("opencode:msg-fresh", request: "msg-fresh", total: 200, session: "ses-old", origin: "local")
        let coveredRollup = usage("opencode:ses-old#1", request: "ses-old#1", total: 150, session: "ses-old", origin: "homeserver")
        let legacy = usage("opencode:ses-legacy#1", request: "ses-legacy#1", total: 150, session: "ses-legacy", origin: "homeserver")
        let combined = OpenCodeStore.combineMessageAndRollup(
            messages: [message], rollups: [coveredRollup, legacy])
        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(Set(combined.map(\.sessionId)), ["ses-old", "ses-legacy"])
    }

    func testOriginBreakdownInStatsJSONAndRender() throws {
        let records = [
            usage("a", request: "a", total: 100, origin: "local"),
            usage("b", request: "b", total: 300, origin: "homeserver"),
        ]
        let scoped = Aggregator.filter(records, source: .opencode, preset: .lifetime, now: now, calendar: calendar)
        let stats = Aggregator.aggregate(scoped, calendar: calendar)
        XCTAssertEqual(stats.totalTokens, 400) // combined total retained
        XCTAssertEqual(Set(stats.byOrigin.map(\.key)), ["opencode/local", "opencode/homeserver"])
        let section = ReportFormatter.section(records: records, source: .opencode, preset: .lifetime, now: now, calendar: calendar)
        let text = ReportFormatter.render(section: section)
        XCTAssertTrue(text.contains("By origin:"))
        XCTAssertTrue(text.contains("opencode/local"))
        XCTAssertTrue(text.contains("opencode/homeserver"))
        let json = try ReportFormatter.encodeJSON(sections: [section], warnings: [])
        XCTAssertTrue(json.contains("byOrigin"))
        XCTAssertTrue(json.contains("opencode/homeserver"))
    }

    func testSanitizedExtrasProduceNoPaths() {
        let warnings = ReportFormatter.sanitizeWarnings([
            "OpenCode extra database not found (checked TOKENBAR_OPENCODE_DB_EXTRA).",
            "OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON).",
            "OpenCode snapshot contained extra non-token fields (ignored).",
        ])
        XCTAssertFalse(warnings.joined(separator: " ").contains("/"))
        XCTAssertTrue(warnings[0].contains("TOKENBAR_OPENCODE_DB_EXTRA"))
        XCTAssertTrue(warnings[1].contains("TOKENBAR_OPENCODE_USAGE_JSON"))
    }

    func testDecodeNeverRetainsPromptOrPath() {
        let columns: [String: String?] = [
            "id": "s", "time_created": "1757325600000",
            "tokens_input": "10", "tokens_output": "5", "model": "m",
            "data": #"{"prompt":"SECRET-PROMPT-XYZ","path":"/Users/someone/secret"}"#,
        ]
        let record = OpenCodeStore.decodeRow(columns)!
        let dump = "\(record.model) \(record.sessionId) \(record.requestId) \(record.id) \(record.origin)"
        XCTAssertFalse(dump.contains("SECRET-PROMPT-XYZ"))
        XCTAssertFalse(dump.contains("/Users/someone"))
    }
}
