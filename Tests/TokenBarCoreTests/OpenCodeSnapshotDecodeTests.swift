import Foundation
import XCTest
@testable import TokenBarCore

/// Snapshot decode parity for the lazy case-insensitive fallback.
/// Hermetic, no timing assertions, no private files. Synthetic only.
final class OpenCodeSnapshotDecodeTests: XCTestCase {
    func testMixedCasingDecodesLikeCanonical() {
        let canonical: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
            "inputTokens": 100, "outputTokens": 50,
            "sessionId": "ses-1", "requestId": "msg-1",
        ]
        let mixed: [String: Any] = [
            "TIMESTAMP": "2026-09-11T10:00:00Z", "MODEL": "m",
            "INPUTTOKENS": 100, "Output_Tokens": 50,
            "SESSIONID": "ses-1", "Request_ID": "msg-1",
        ]
        let a = OpenCodeStore.decodeSnapshotRecord(canonical)
        let b = OpenCodeStore.decodeSnapshotRecord(mixed)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a?.inputTokens, 100)
        XCTAssertEqual(b?.inputTokens, 100)
        XCTAssertEqual(a?.outputTokens, b?.outputTokens)
        XCTAssertEqual(a?.sessionId, "ses-1")
        XCTAssertEqual(b?.sessionId, "ses-1")
        XCTAssertEqual(a?.requestId, "msg-1")
        XCTAssertEqual(b?.requestId, "msg-1")
    }

    func testAliasFallbackSnakeCase() {
        let dict: [String: Any] = [
            "created_at": "2026-09-11T10:00:00Z",
            "model_name": "alias-model",
            "input_tokens": 80, "output_tokens": 20,
            "session_id": "ses-alias", "message_id": "msg-alias",
        ]
        let record = OpenCodeStore.decodeSnapshotRecord(dict)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.model, "alias-model")
        XCTAssertEqual(record?.inputTokens, 80)
        XCTAssertEqual(record?.outputTokens, 20)
        XCTAssertEqual(record?.sessionId, "ses-alias")
        XCTAssertEqual(record?.requestId, "msg-alias")
    }

    func testProviderPlusModelComposition() {
        let dict: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z",
            "provider": "openai", "model": "gpt-5-mini",
            "inputTokens": 10, "outputTokens": 5,
        ]
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(dict)?.model, "openai/gpt-5-mini")
        // A slash-bearing model name never gains a provider prefix.
        let slashed: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z",
            "provider": "openai", "model": "other/gpt-5-mini",
            "inputTokens": 10, "outputTokens": 5,
        ]
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(slashed)?.model, "other/gpt-5-mini")
    }

    func testSourceRejection() {
        var dict: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z",
            "inputTokens": 10, "outputTokens": 5,
        ]
        XCTAssertNotNil(OpenCodeStore.decodeSnapshotRecord(dict))
        dict["source"] = "opencode"
        XCTAssertNotNil(OpenCodeStore.decodeSnapshotRecord(dict))
        dict["SOURCE"] = "codex"
        dict.removeValue(forKey: "source")
        // Uppercase key still gates: non-opencode sources skip.
        XCTAssertNil(OpenCodeStore.decodeSnapshotRecord(dict))
        dict["SOURCE"] = "OPENCODE"
        XCTAssertNotNil(OpenCodeStore.decodeSnapshotRecord(dict))
    }

    func testForbiddenKeysDetectedAndIgnored() throws {
        let payload: [[String: Any]] = [[
            "timestamp": "2026-09-11T10:00:00Z",
            "model": "m", "inputTokens": 10, "outputTokens": 5,
            "sessionId": "s", "requestId": "r",
            "PROMPT": "SECRET-PROMPT-XYZ", "Path": "/Users/someone/secret",
        ]]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try OpenCodeStore.loadSnapshot(at: url.path)
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertTrue(loaded.sawExtraFields)
        let dump = String(
            data: try JSONEncoder().encode(loaded.records), encoding: .utf8)!
        XCTAssertFalse(dump.contains("SECRET-PROMPT-XYZ"))
        XCTAssertFalse(dump.contains("/Users/someone"))
    }

    func testOriginSanitization() {
        let base: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
            "inputTokens": 10, "outputTokens": 5,
        ]
        var hostile = base
        hostile["origin"] = "evil/x\ny"
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(hostile)?.origin, "remote")
        var labelled = base
        labelled["HOST"] = "my-mac_2.0"
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(labelled)?.origin, "my-mac_2.0")
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(base, originFallback: "local")?.origin,
            "local")
        // Legacy label still loads.
        var legacy = base
        legacy["origin"] = "homeserver"
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(legacy)?.origin, "homeserver")
    }

    func testFallbackIDsDeterministic() {
        let base: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
            "inputTokens": 10, "outputTokens": 5,
            "sessionId": "ses-fb", "requestId": "msg-fb",
        ]
        let first = OpenCodeStore.decodeSnapshotRecord(base)
        let second = OpenCodeStore.decodeSnapshotRecord(base)
        XCTAssertEqual(first?.id, "opencode:msg-fb")
        XCTAssertEqual(first?.id, second?.id)
        // No request id: content-hashed snapshot id, stable across decodes,
        // distinct rows stay distinct.
        var noid: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
            "inputTokens": 10, "outputTokens": 5, "sessionId": "ses-fb",
        ]
        let idA = OpenCodeStore.decodeSnapshotRecord(noid)?.id
        let idA2 = OpenCodeStore.decodeSnapshotRecord(noid)?.id
        XCTAssertNotNil(idA)
        XCTAssertEqual(idA, idA2)
        XCTAssertTrue(idA?.hasPrefix("opencode:snapshot:ses-fb") ?? false)
        noid["inputTokens"] = 11
        let idB = OpenCodeStore.decodeSnapshotRecord(noid)?.id
        XCTAssertNotEqual(idA, idB)
    }

    func testPositiveTokenGate() {
        let zero: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
            "inputTokens": 0, "outputTokens": 0, "totalTokens": 0,
        ]
        XCTAssertNil(OpenCodeStore.decodeSnapshotRecord(zero))
        let missing: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
        ]
        XCTAssertNil(OpenCodeStore.decodeSnapshotRecord(missing))
        XCTAssertNil(OpenCodeStore.decodeSnapshotRecord([
            "inputTokens": 10, "outputTokens": 5,
        ]))
    }

    func testDuplicateCaseInsensitivePrecedenceExplicit() {
        // Exact-case key wins over any case-insensitive collision.
        let exactWins: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
            "inputTokens": 111, "INPUTTOKENS": 222,
        ]
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(exactWins)?.inputTokens, 111)
        // No exact alias present: the lazy fallback resolves the collision to
        // the lexicographically smallest original key
        // ("INPUTTOKENS" < "InputTokens" in byte order).
        let smallestWins: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
            "INPUTTOKENS": 111, "InputTokens": 222,
        ]
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(smallestWins)?.inputTokens, 111)
    }

    func testHeterogeneousCollisionKeepsValidString() {
        // An Int under the smaller key must not hide a valid string collision
        // for text fields (matches the old scan, which skipped non-strings).
        let dict: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z",
            "MODEL": 123, "Model": "kept-model",
            "inputTokens": 10, "outputTokens": 5,
        ]
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(dict)?.model, "kept-model")
    }

    func testCoercionParity() {
        let base: [String: Any] = [
            "timestamp": "2026-09-11T10:00:00Z", "model": "m",
            "sessionId": "s", "requestId": "r",
        ]
        // Bool counts are rejected (that field reads as missing).
        var bools = base
        bools["inputTokens"] = true
        bools["outputTokens"] = 5
        let boolRecord = OpenCodeStore.decodeSnapshotRecord(bools)
        XCTAssertNotNil(boolRecord)
        XCTAssertEqual(boolRecord?.inputTokens, 0)
        XCTAssertEqual(boolRecord?.outputTokens, 5)
        var allBools = base
        allBools["inputTokens"] = true
        allBools["outputTokens"] = false
        XCTAssertNil(OpenCodeStore.decodeSnapshotRecord(allBools))
        // String integers are accepted.
        var strings = base
        strings["inputTokens"] = "120"
        strings["outputTokens"] = "34"
        let stringRecord = OpenCodeStore.decodeSnapshotRecord(strings)
        XCTAssertEqual(stringRecord?.inputTokens, 120)
        XCTAssertEqual(stringRecord?.outputTokens, 34)
        // String decimals truncate toward zero.
        var decimals = base
        decimals["inputTokens"] = "10.9"
        decimals["outputTokens"] = "5.1"
        let decimalRecord = OpenCodeStore.decodeSnapshotRecord(decimals)
        XCTAssertEqual(decimalRecord?.inputTokens, 10)
        XCTAssertEqual(decimalRecord?.outputTokens, 5)
        // Doubles truncate toward zero.
        var doubles = base
        doubles["inputTokens"] = 10.9
        doubles["outputTokens"] = 5.9
        let doubleRecord = OpenCodeStore.decodeSnapshotRecord(doubles)
        XCTAssertEqual(doubleRecord?.inputTokens, 10)
        XCTAssertEqual(doubleRecord?.outputTokens, 5)
    }

    func testTimestampAndCachedAliases() {
        // Epoch seconds timestamp plus snake_case cached aliases.
        let dict: [String: Any] = [
            "timestamp": 1_789_041_600, "model": "m",
            "tokens_input": 800, "tokens_output": 200,
            "tokens_cache_read": 150, "tokens_cache_write": 50,
        ]
        let record = OpenCodeStore.decodeSnapshotRecord(dict)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.cachedTokens, 200)
        XCTAssertEqual(record?.inputTokens, 800)
        XCTAssertEqual(record?.totalTokens, 1000)
    }
}
