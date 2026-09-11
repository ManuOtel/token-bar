import Foundation
import XCTest
@testable import TokenBarCore

/// Covers the per-message OpenCode path (`message` / `session_message`):
/// the nested token shape current OpenCode versions write, the
/// assistant-only gate, model identity variants, all-zero skips, the
/// message-beats-rollup combine rule, and the range-attribution fix
/// (recent usage inside sessions created before the window).
/// All fixtures are synthetic; never real session logs.
final class OpenCodeMessageTests: XCTestCase {
    private func messageColumns(
        _ blob: [String: Any],
        rowId: String = "msg-1",
        session: String = "ses-1",
        columnTime: String = "1757325600000",
        typeColumn: String? = nil
    ) -> [String: String?] {
        let data = String(data: try! JSONSerialization.data(withJSONObject: blob), encoding: .utf8)
        var columns: [String: String?] = [
            "id": rowId,
            "session_id": session,
            "time_created": columnTime,
            "data": data,
        ]
        if let typeColumn { columns["type"] = typeColumn }
        return columns
    }

    private func assistantBlob(
        modelID: String? = "muse-spark-1.3-contributor",
        providerID: String? = "opencode-go",
        tokens: [String: Any] = [
            "input": 3413, "output": 161, "reasoning": 60,
            "cache": ["read": 600, "write": 100], "total": 4813,
        ],
        created: Int = 1_789_087_080_181
    ) -> [String: Any] {
        var blob: [String: Any] = [
            "role": "assistant",
            "tokens": tokens,
            "time": ["created": created],
        ]
        if let modelID { blob["modelID"] = modelID }
        if let providerID { blob["providerID"] = providerID }
        return blob
    }

    func testNestedTokensFoldCacheIntoInput() {
        let record = OpenCodeStore.decodeMessageRow(messageColumns(assistantBlob()))
        XCTAssertNotNil(record)
        // Nested input excludes cache: 3413 raw + 600 read + 100 write.
        XCTAssertEqual(record?.inputTokens, 4113)
        XCTAssertEqual(record?.cachedTokens, 700)
        XCTAssertEqual(record?.outputTokens, 161)
        XCTAssertEqual(record?.reasoningTokens, 60)
        XCTAssertEqual(record?.totalTokens, 4813) // explicit total wins
        XCTAssertLessThanOrEqual(record?.cachedTokens ?? 0, record?.inputTokens ?? 0)
        XCTAssertEqual(record?.source, .opencode)
        XCTAssertEqual(record?.sessionId, "ses-1")
        XCTAssertEqual(record?.requestId, "msg-1")
    }

    func testFlatModelIDsBecomeProviderSlashID() {
        let record = OpenCodeStore.decodeMessageRow(messageColumns(assistantBlob()))
        XCTAssertEqual(record?.model, "opencode-go/muse-spark-1.3-contributor")
        // Paid Muse Spark resolves to the exact estimate entry, not fallback.
        XCTAssertTrue(Pricing.isExactMatch(forModel: record?.model ?? ""))
    }

    func testNestedModelObject() {
        var blob = assistantBlob(modelID: nil, providerID: nil)
        blob["model"] = ["id": "gpt-5.6-luna", "providerID": "openai"] as [String: String]
        XCTAssertEqual(OpenCodeStore.decodeMessageRow(messageColumns(blob))?.model, "openai/gpt-5.6-luna")
    }

    func testModelJSONStringColumn() {
        var blob = assistantBlob(modelID: nil, providerID: nil)
        blob["model"] = #"{"id":"gpt-5-mini","providerID":"openai"}"#
        XCTAssertEqual(OpenCodeStore.decodeMessageRow(messageColumns(blob))?.model, "openai/gpt-5-mini")
    }

    func testNonAssistantRowsSkipped() {
        XCTAssertNil(OpenCodeStore.decodeMessageRow(messageColumns(
            ["role": "user", "time": ["created": 1_789_087_080_181]])))
        XCTAssertNil(OpenCodeStore.decodeMessageRow(messageColumns(
            assistantBlob(), typeColumn: "compaction")))
        XCTAssertNil(OpenCodeStore.decodeMessageRow(messageColumns(
            assistantBlob(), typeColumn: "synthetic")))
        // Assistant type column passes.
        XCTAssertNotNil(OpenCodeStore.decodeMessageRow(messageColumns(
            assistantBlob(), typeColumn: "assistant")))
    }

    func testAllZeroAssistantRowSkipped() {
        let blob = assistantBlob(tokens: [
            "input": 0, "output": 0, "reasoning": 0,
            "cache": ["read": 0, "write": 0],
        ])
        XCTAssertNil(OpenCodeStore.decodeMessageRow(messageColumns(blob)))
    }

    func testMissingTimestampSkipped() {
        var columns = messageColumns(assistantBlob())
        columns["time_created"] = nil
        var blob = assistantBlob()
        blob.removeValue(forKey: "time")
        columns["data"] = String(data: try! JSONSerialization.data(withJSONObject: blob), encoding: .utf8)
        XCTAssertNil(OpenCodeStore.decodeMessageRow(columns))
    }

    func testMissingTokensSkipped() {
        var blob = assistantBlob()
        blob.removeValue(forKey: "tokens")
        XCTAssertNil(OpenCodeStore.decodeMessageRow(messageColumns(blob)))
    }

    func testTotalFallbackIncludesCache() {
        var blob = assistantBlob()
        var tokens = blob["tokens"] as! [String: Any]
        tokens.removeValue(forKey: "total")
        blob["tokens"] = tokens
        let record = OpenCodeStore.decodeMessageRow(messageColumns(blob))
        // Normalized input (4113) + output (161).
        XCTAssertEqual(record?.totalTokens, 4274)
    }

    func testNestedTimeCreatedMillis() {
        var blob = assistantBlob()
        blob["time"] = ["created": 1_789_087_080_181]
        var columns = messageColumns(blob)
        columns["time_created"] = nil // nested time must carry the decode
        let record = OpenCodeStore.decodeMessageRow(columns, table: "session_message")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.timestamp.timeIntervalSince1970 ?? 0, 1_789_087_080.181, accuracy: 0.001)
    }

    func testPromptAndPathContentNeverLeaks() {
        var blob = assistantBlob()
        blob["text"] = "SECRET-PROMPT-XYZ"
        blob["content"] = [["type": "text", "text": "SECRET-PROMPT-XYZ"]]
        blob["path"] = ["cwd": "/Users/someone/secret"]
        let record = OpenCodeStore.decodeMessageRow(messageColumns(blob))
        XCTAssertNotNil(record)
        let dump = "\(record!.model) \(record!.sessionId) \(record!.requestId) \(record!.id)"
        XCTAssertFalse(dump.contains("SECRET-PROMPT-XYZ"))
        XCTAssertFalse(dump.contains("/Users/someone"))
    }

    func testMirrorMessageIDsDedupeAcrossTables() {
        let first = OpenCodeStore.decodeMessageRow(messageColumns(assistantBlob(), rowId: "msg-dup"), table: "message")
        let second = OpenCodeStore.decodeMessageRow(messageColumns(assistantBlob(), rowId: "msg-dup"), table: "session_message")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.requestId, second?.requestId)
        XCTAssertEqual(TokenBarStore.dedupe([first!, second!]).count, 1)
    }

    func testRecentMessageInsideOldSessionHitsRange() {
        // The 7d bug: a session created 60 days ago carries a message from
        // yesterday. The rollup timestamp misses the window; the message
        // timestamp hits it.
        let now = Date(timeIntervalSince1970: 1_789_121_600) // 2026-09-11 12:00 UTC
        let windowStart = now.addingTimeInterval(-7 * 24 * 3600)
        let oldMillis = Int((now.addingTimeInterval(-60 * 24 * 3600)).timeIntervalSince1970 * 1000)
        let freshMillis = Int((now.addingTimeInterval(-24 * 3600)).timeIntervalSince1970 * 1000)
        let rollup = OpenCodeStore.decodeRow(
            ["id": "ses-old", "time_created": "\(oldMillis)",
             "tokens_input": "100", "tokens_output": "50"] as [String: String?],
            table: "session")
        var blob = assistantBlob(created: freshMillis)
        blob["role"] = "assistant"
        let message = OpenCodeStore.decodeMessageRow(
            messageColumns(blob, rowId: "msg-fresh", session: "ses-old"))
        XCTAssertNotNil(rollup)
        XCTAssertNotNil(message)
        XCTAssertLessThan(rollup!.timestamp, windowStart)
        XCTAssertGreaterThanOrEqual(message!.timestamp, windowStart)
        XCTAssertEqual(
            Aggregator.filter([message!], source: .opencode, preset: .last7Days, now: now).count, 1)
        XCTAssertEqual(
            Aggregator.filter([rollup!], source: .opencode, preset: .last7Days, now: now).count, 0)
    }

    func testCombineKeepsMessagesAndFillsUncoveredRollups() {
        let message = OpenCodeStore.decodeMessageRow(
            messageColumns(assistantBlob(), rowId: "msg-fresh", session: "ses-old"))!
        let coveredRollup = OpenCodeStore.decodeRow(
            ["id": "ses-old", "time_created": "1757325600000",
             "tokens_input": "100", "tokens_output": "50"] as [String: String?],
            table: "session")!
        let legacyRollup = OpenCodeStore.decodeRow(
            ["id": "ses-legacy", "time_created": "1757325600000",
             "tokens_input": "200", "tokens_output": "50"] as [String: String?],
            table: "session")!
        let combined = OpenCodeStore.combineMessageAndRollup(
            messages: [message], rollups: [coveredRollup, legacyRollup])
        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(Set(combined.map(\.sessionId)), ["ses-old", "ses-legacy"])
    }

    func testCombineFresherRollupMirrorWins() {
        func rollup(total: Int) -> NormalizedUsage {
            OpenCodeStore.decodeRow(
                ["id": "ses-m", "time_created": "1757325600000",
                 "tokens_input": "\(total)", "tokens_output": "0"] as [String: String?],
                table: "session")!
        }
        let combined = OpenCodeStore.combineMessageAndRollup(messages: [], rollups: [rollup(total: 100), rollup(total: 150)])
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.totalTokens, 150)
    }

    func testCombineFallsBackToRollupsWithoutMessages() {
        let rollup = OpenCodeStore.decodeRow(
            ["id": "ses-x", "time_created": "1757325600000",
             "tokens_input": "100", "tokens_output": "50"] as [String: String?],
            table: "session")!
        let combined = OpenCodeStore.combineMessageAndRollup(messages: [], rollups: [rollup])
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.sessionId, "ses-x")
    }
}
