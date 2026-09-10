import Foundation
import XCTest
@testable import TokenBarCore

final class OpenCodeParserTests: XCTestCase {
    func testColumnFormDecode() {
        let columns: [String: String?] = [
            "id": "abc",
            "model": "claude-sonnet-4",
            "input_tokens": "1000",
            "output_tokens": "250",
            "cached_tokens": "100",
            "created_at": "2026-09-10T08:15:00Z",
        ]
        let record = OpenCodeStore.decodeRow(columns, table: "session_v2")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source, .opencode)
        // Cache folds into input: 1000 raw + 100 cached.
        XCTAssertEqual(record?.inputTokens, 1100)
        XCTAssertEqual(record?.cachedTokens, 100)
        XCTAssertEqual(record?.outputTokens, 250)
        XCTAssertEqual(record?.totalTokens, 1350) // normalized input + output
    }

    func testLegacySessionTableDecode() {
        let columns: [String: String?] = [
            "session_id": "legacy-1",
            "model": "gpt-4o",
            "prompt_tokens": "300",
            "completion_tokens": "100",
            "created": "2026-08-01T12:00:00Z",
        ]
        let record = OpenCodeStore.decodeRow(columns, table: "session")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.sessionId, "legacy-1")
        XCTAssertEqual(record?.totalTokens, 400)
    }

    func testJsonBlobDecode() {
        let blob = #"{"model":"gpt-5-mini","input_tokens":700,"output_tokens":300,"timestamp":"2026-09-09T10:00:00Z"}"#
        let columns: [String: String?] = ["id": "row1", "data": blob]
        let record = OpenCodeStore.decodeRow(columns)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.model, "gpt-5-mini")
        XCTAssertEqual(record?.totalTokens, 1000)
    }

    func testNumericOneAcceptedAndTrueRejected() {
        // Darwin bridges any NSNumber holding 0/1 as Bool, so the count
        // gate must use objCType, never `is Bool` (Mac CI regression).
        // Blob values reach intField as raw JSONSerialization output.
        let ones: [String: String?] = [
            "id": "one",
            "data": #"{"input_tokens":1,"output_tokens":1,"timestamp":"2026-09-10T08:15:00Z"}"#,
        ]
        XCTAssertEqual(OpenCodeStore.decodeRow(ones)?.inputTokens, 1)
        let bools: [String: String?] = [
            "id": "bool",
            "data": #"{"input_tokens":true,"output_tokens":true,"timestamp":"2026-09-10T08:15:00Z"}"#,
        ]
        XCTAssertNil(OpenCodeStore.decodeRow(bools))
    }

    func testMissingTimestampSkipped() {
        let columns: [String: String?] = ["id": "x", "model": "m", "input_tokens": "10"]
        XCTAssertNil(OpenCodeStore.decodeRow(columns))
    }

    func testNoTokenCountsSkipped() {
        let columns: [String: String?] = ["id": "x", "created_at": "2026-09-10T08:15:00Z"]
        XCTAssertNil(OpenCodeStore.decodeRow(columns))
    }

    func testUnknownModelFallsBack() {
        let columns: [String: String?] = [
            "id": "x", "created_at": "2026-09-10T08:15:00Z", "input_tokens": "10", "output_tokens": "5",
        ]
        XCTAssertEqual(OpenCodeStore.decodeRow(columns)?.model, "unknown")
        let cost = Pricing.cost(model: "some-future-model-zzz", inputTokens: 1_000_000, outputTokens: 0, cachedTokens: 0)
        XCTAssertEqual(cost, 3.0, accuracy: 0.0001)
    }

    func testSchemaDriftNullsTolerated() {
        let columns: [String: String?] = [
            "id": nil, "model": nil, "input_tokens": "50", "output_tokens": nil,
            "created_at": "2026-09-10T08:15:00Z",
        ]
        let record = OpenCodeStore.decodeRow(columns)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.inputTokens, 50)
        XCTAssertEqual(record?.outputTokens, 0)
    }

    func testNegativeTotalFallsBack() {
        let columns: [String: String?] = [
            "id": "n", "created_at": "2026-09-10T08:15:00Z",
            "input_tokens": "10", "output_tokens": "5", "total_tokens": "-3",
        ]
        XCTAssertEqual(OpenCodeStore.decodeRow(columns)?.totalTokens, 15)
    }

    func testRealColumnsWithModelJSON() {
        // Real-world OpenCode shape: epoch-millis time_created, tokens_*
        // columns, model as a JSON string.
        let columns: [String: String?] = [
            "id": "sess-1",
            "time_created": "1757325600000",
            "time_updated": "1757325660000",
            "tokens_input": "1000",
            "tokens_output": "250",
            "tokens_reasoning": "50",
            "tokens_cache_read": "100",
            "tokens_cache_write": "20",
            "model": #"{"id":"gpt-5-mini","providerID":"openai"}"#,
        ]
        let record = OpenCodeStore.decodeRow(columns, table: "session_v2")
        XCTAssertNotNil(record)
        // tokens_input excludes cache: 1000 raw + 100 read + 20 write.
        XCTAssertEqual(record?.inputTokens, 1120)
        XCTAssertEqual(record?.outputTokens, 250)
        XCTAssertEqual(record?.reasoningTokens, 50)
        XCTAssertEqual(record?.cachedTokens, 120) // read + write
        XCTAssertEqual(record?.totalTokens, 1370) // normalized input + output
        XCTAssertLessThanOrEqual(record?.cachedTokens ?? 0, record?.inputTokens ?? 0)
        XCTAssertEqual(record?.model, "openai/gpt-5-mini")
        XCTAssertEqual(record?.sessionId, "sess-1")
        // No per-message ID: sessionID#epochSeconds doubles as request ID so
        // the session_v2/session mirror pair dedupes downstream while rows at
        // different timestamps stay distinct.
        XCTAssertEqual(record?.requestId, "sess-1#1757325600")
    }

    func testModelJSONIdOnly() {
        let columns: [String: String?] = [
            "id": "s", "time_created": "1757325600000",
            "tokens_input": "10", "tokens_output": "5",
            "model": #"{"id":"claude-sonnet-4"}"#,
        ]
        XCTAssertEqual(OpenCodeStore.decodeRow(columns)?.model, "claude-sonnet-4")
    }

    func testCacheFoldedIntoInputAndTotal() {
        // Official schema: tokens_input excludes cache, so normalized input
        // is raw + cache and the total fallback includes cached usage.
        // Cost stays consistent: Pricing caps cached at input (subset).
        let columns: [String: String?] = [
            "id": "c", "time_created": "1757325600000",
            "tokens_input": "800", "tokens_output": "200",
            "tokens_cache_read": "150", "tokens_cache_write": "50",
            "model": "m",
        ]
        let record = OpenCodeStore.decodeRow(columns)
        XCTAssertEqual(record?.inputTokens, 1000)
        XCTAssertEqual(record?.cachedTokens, 200)
        XCTAssertEqual(record?.totalTokens, 1200)
        XCTAssertLessThanOrEqual(record!.cachedTokens, record!.inputTokens)
        let expected = Pricing.cost(model: "m", inputTokens: 1000, outputTokens: 200, cachedTokens: 200)
        XCTAssertEqual(Pricing.cost(for: record!), expected, accuracy: 0.000001)
    }

    func testCacheOnlyRowNormalizesInput() {
        let columns: [String: String?] = [
            "id": "co", "time_created": "1757325600000",
            "tokens_cache_read": "300",
            "model": "m",
        ]
        let record = OpenCodeStore.decodeRow(columns)
        XCTAssertEqual(record?.inputTokens, 300)
        XCTAssertEqual(record?.cachedTokens, 300)
        XCTAssertEqual(record?.totalTokens, 300)
    }

    func testExplicitTotalStillWins() {
        let columns: [String: String?] = [
            "id": "e", "time_created": "1757325600000",
            "tokens_input": "800", "tokens_output": "200",
            "tokens_cache_read": "100", "total_tokens": "5000",
            "model": "m",
        ]
        let record = OpenCodeStore.decodeRow(columns)
        XCTAssertEqual(record?.inputTokens, 900)
        XCTAssertEqual(record?.totalTokens, 5000)
    }

    func testMirrorRowsAcrossTablesDedupeToOne() {
        let base: [String: String?] = [
            "id": "sess-dup",
            "time_created": "1757325600000",
            "tokens_input": "100",
            "tokens_output": "50",
            "model": "m",
        ]
        let first = OpenCodeStore.decodeRow(base, table: "session_v2")
        let second = OpenCodeStore.decodeRow(base, table: "session")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(TokenBarStore.dedupe([first!, second!]).count, 1)
    }

    func testSameSessionDifferentTimestampsStayDistinct() {
        let older: [String: String?] = [
            "id": "sess-multi",
            "time_created": "1757325600000",
            "tokens_input": "100",
            "tokens_output": "50",
            "model": "m",
        ]
        let newer: [String: String?] = [
            "id": "sess-multi",
            "time_created": "1757325660000",
            "tokens_input": "100",
            "tokens_output": "50",
            "model": "m",
        ]
        let first = OpenCodeStore.decodeRow(older, table: "session_v2")
        let second = OpenCodeStore.decodeRow(newer, table: "session_v2")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.requestId, second?.requestId)
        XCTAssertEqual(TokenBarStore.dedupe([first!, second!]).count, 2)
    }
}
