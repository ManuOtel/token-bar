import Foundation
import XCTest
@testable import TokenBarCore

#if canImport(SQLite3)
import SQLite3
#endif

/// SQLite projection slice: `loadTable` selects only the bounded
/// `projectedColumns` allowlist instead of `SELECT *`, so wide unrelated
/// columns are never copied off SQLite. All fixtures synthetic.
final class OpenCodeProjectionTests: XCTestCase {
    func testProjectedSelectionKeepsRecognizedDropsWide() {
        let actual = [
            "id", "time_created", "tokens_input", "tokens_output", "model",
            "data", "prompt_text", "tool_output", "future_col_v2", "content",
        ]
        let selected = OpenCodeStore.projectedSelection(actualColumns: actual)
        XCTAssertEqual(selected, ["id", "time_created", "tokens_input", "tokens_output", "model", "data", "content"])
        XCTAssertFalse(selected.contains("prompt_text"))
        XCTAssertFalse(selected.contains("tool_output"))
        XCTAssertFalse(selected.contains("future_col_v2"))
    }

    func testProjectedSelectionIsCaseInsensitiveAndOrderPreserving() {
        let selected = OpenCodeStore.projectedSelection(actualColumns: ["ID", "Wide_Col", "Time_Created", "DATA"])
        XCTAssertEqual(selected, ["ID", "Time_Created", "DATA"])
    }

    func testQuoteIdentifierEscapesDoubleQuotes() {
        XCTAssertEqual(OpenCodeStore.quoteIdentifier("session_v2"), "\"session_v2\"")
        XCTAssertEqual(OpenCodeStore.quoteIdentifier("we\"ird"), "\"we\"\"ird\"")
    }

    func testProjectedColumnsCoverAllDecoderProbes() {
        // Every alias the pure decoders probe must be in the allowlist,
        // otherwise projection would silently drop decodable data.
        let required = [
            "data", "payload", "info", "value", "content", "meta",
            "timestamp", "time", "time_created", "created_at", "created",
            "updated_at", "updated", "date",
            "input_tokens", "prompt_tokens", "tokens_input", "input",
            "output_tokens", "completion_tokens", "tokens_output", "output",
            "cached_tokens", "tokens_cache_read", "tokens_cache_write",
            "cache_write_input_tokens",
            "reasoning_tokens", "tokens_reasoning",
            "total_tokens", "tokens_total", "total", "tokens",
            "model", "model_name", "modelid", "model_id",
            "providerid", "provider_id", "provider",
            "session_id", "sessionid", "session", "id", "key",
            "request_id", "requestid", "message_id", "messageid", "rowid",
            "type", "role",
        ]
        for column in required {
            XCTAssertTrue(OpenCodeStore.projectedColumns.contains(column), "missing: \(column)")
        }
        // Privacy-relevant wide columns must NOT be selected.
        for wide in ["prompt", "prompt_text", "tool_input", "tool_output", "text", "body", "path", "secret"] {
            XCTAssertFalse(OpenCodeStore.projectedColumns.contains(wide), "must stay unselected: \(wide)")
        }
    }

    func testDecodeRowIgnoresWideColumns() {
        let base: [String: String?] = [
            "id": "sess-1", "time_created": "1757325600000",
            "tokens_input": "1000", "tokens_output": "250",
            "model": "m",
        ]
        var wide = base
        wide["prompt_text"] = String(repeating: "x", count: 100_000)
        wide["tool_output"] = String(repeating: "y", count: 100_000)
        wide["future_col_v2"] = "12345"
        wide["path"] = "/Users/someone/secret"
        let a = OpenCodeStore.decodeRow(base, table: "session_v2")
        let b = OpenCodeStore.decodeRow(wide, table: "session_v2")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a?.totalTokens, b?.totalTokens)
        XCTAssertEqual(a?.inputTokens, b?.inputTokens)
        XCTAssertEqual(a?.model, b?.model)
        XCTAssertEqual(a?.sessionId, b?.sessionId)
        XCTAssertEqual(a?.requestId, b?.requestId)
        let dump = "\(b!.model) \(b!.sessionId) \(b!.requestId) \(b!.id)"
        XCTAssertFalse(dump.contains("/Users/someone"))
    }

    func testDecodeRowBlobVariantsStillDecodeWithWideColumns() {
        for blobKey in ["data", "payload", "info", "value", "content", "meta"] {
            let blob = #"{"model":"m","input_tokens":700,"output_tokens":300,"timestamp":"2026-09-09T10:00:00Z"}"#
            let columns: [String: String?] = [
                "id": "row1", blobKey: blob,
                "prompt_text": String(repeating: "z", count: 10_000),
            ]
            let record = OpenCodeStore.decodeRow(columns)
            XCTAssertNotNil(record, "blob key \(blobKey)")
            XCTAssertEqual(record?.totalTokens, 1000, "blob key \(blobKey)")
        }
    }

    func testDecodeMessageRowIgnoresWideColumns() {
        let blob: [String: Any] = [
            "role": "assistant", "modelID": "m", "providerID": "p",
            "tokens": ["input": 100, "output": 50],
            "time": ["created": 1_789_087_080_181],
        ]
        let data = String(data: try! JSONSerialization.data(withJSONObject: blob), encoding: .utf8)
        let base: [String: String?] = [
            "id": "msg-1", "session_id": "ses-1",
            "time_created": "1757325600000", "data": data,
        ]
        var wide = base
        wide["prompt_text"] = String(repeating: "q", count: 50_000)
        wide["tool_input"] = String(repeating: "w", count: 50_000)
        wide["future_col_v2"] = "999"
        let a = OpenCodeStore.decodeMessageRow(base)
        let b = OpenCodeStore.decodeMessageRow(wide)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a?.totalTokens, b?.totalTokens)
        XCTAssertEqual(a?.inputTokens, b?.inputTokens)
        XCTAssertEqual(a?.model, b?.model)
        XCTAssertEqual(a?.requestId, b?.requestId)
    }

    func testSkippedCountsPreservedWithWideColumns() {
        // No timestamp: skipped whether or not wide columns exist.
        let noTS: [String: String?] = ["id": "x", "input_tokens": "10", "prompt_text": "wide"]
        XCTAssertNil(OpenCodeStore.decodeRow(noTS))
        XCTAssertNil(OpenCodeStore.decodeMessageRow(["id": "x", "data": "{}", "prompt_text": "wide"]))
    }

#if canImport(SQLite3)
    func testSQLiteWideColumnsIgnoredAndParity() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-projection-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeWideFixture(at: path)
        let loaded = try OpenCodeStore.loadDatabase(at: path)
        // session_v2 rollup for ses-legacy (no messages) + message for
        // ses-1 (beats its covered rollup). One bad row skipped.
        XCTAssertEqual(loaded.records.count, 2)
        XCTAssertEqual(loaded.skipped, 1)
        let sessions = Set(loaded.records.map(\.sessionId))
        XCTAssertEqual(sessions, ["ses-1", "ses-legacy"])
        let dump = loaded.records.map { "\($0.model) \($0.sessionId) \($0.requestId) \($0.id)" }.joined(separator: "|")
        XCTAssertFalse(dump.contains("SECRET-PROMPT"))
        XCTAssertFalse(dump.contains("/Users/someone"))
        // Deterministic output: reload agrees byte-for-byte on ids/order.
        let again = try OpenCodeStore.loadDatabase(at: path)
        XCTAssertEqual(loaded.records.map(\.id), again.records.map(\.id))
        XCTAssertEqual(loaded.skipped, again.skipped)
    }

    func testSQLiteMissingTablesSkipGracefully() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-projection-empty-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        sqlite3_close(db)
        let loaded = try OpenCodeStore.loadDatabase(at: path)
        XCTAssertEqual(loaded.records.count, 0)
        XCTAssertEqual(loaded.skipped, 0)
    }

    private func makeWideFixture(at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        guard let db else { XCTFail("open failed"); return }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        exec("CREATE TABLE session_v2 (id TEXT, time_created TEXT, tokens_input TEXT, tokens_output TEXT, model TEXT, prompt_text TEXT, tool_output TEXT, future_col_v2 TEXT)")
        exec("INSERT INTO session_v2 VALUES ('ses-1','1757325600000','100','50','m','SECRET-PROMPT','wide','123')")
        exec("INSERT INTO session_v2 VALUES ('ses-legacy','1757325600000','200','50','m','SECRET-PROMPT','wide','123')")
        exec("INSERT INTO session_v2 VALUES ('bad',NULL,'10','5','m','SECRET-PROMPT','wide','123')")
        let blob = #"{"role":"assistant","modelID":"m","providerID":"p","tokens":{"input":100,"output":50},"time":{"created":1789087080181}}"#.replacingOccurrences(of: "'", with: "''")
        exec("CREATE TABLE message (id TEXT, session_id TEXT, time_created TEXT, data TEXT, prompt_text TEXT, tool_input TEXT, future_col_v2 TEXT)")
        exec("INSERT INTO message VALUES ('msg-1','ses-1','1757325600000','\(blob)','SECRET-PROMPT','wide','999')")
    }
#endif
}
