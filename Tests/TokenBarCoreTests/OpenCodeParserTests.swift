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
        XCTAssertEqual(record?.inputTokens, 1000)
        XCTAssertEqual(record?.outputTokens, 250)
        XCTAssertEqual(record?.totalTokens, 1250)
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
}
