import Foundation
import XCTest
@testable import TokenBarCore

/// Remote auto-sync: config validation, safe argv, cache validation and
/// atomic replacement, failure fallback, and Store refresh integration.
/// Synthetic data only. No subprocess is ever spawned: fetches use injected
/// fakes, and argv builders are asserted pure (never a shell).
final class OpenCodeSyncTests: XCTestCase {
    private var now: Date {
        Date(timeIntervalSince1970: 1_789_227_200) // 2026-09-12T12:00:00Z
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func enabledConfig(
        host: String = "myserver",
        path: String = "/tmp/opencode-usage.json",
        command: String = "",
        poll: Int = 900,
        timeout: Int = 60
    ) -> OpenCodeSyncConfig {
        OpenCodeSyncConfig(
            enabled: true, hostAlias: host, remotePath: path,
            remoteCommand: command, pollIntervalSeconds: poll,
            timeoutSeconds: timeout)
    }

    private func snapshotData(_ records: [[String: Any]] = []) -> Data {
        let records = records.isEmpty ? [[
            "id": "opencode:sync-msg-1", "source": "opencode",
            "timestamp": "2026-09-12T10:00:00Z", "model": "opencode-go/m",
            "inputTokens": 400, "outputTokens": 100, "totalTokens": 500,
            "sessionId": "sync-ses-1", "requestId": "sync-msg-1",
            "origin": "remote",
        ]] : records
        return try! JSONSerialization.data(withJSONObject: records)
    }

    // MARK: - Config validation

    func testDefaultsAreDisabledAndValid() {
        let config = OpenCodeSyncConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.hostAlias, "")
        XCTAssertNil(config.validated())
    }

    func testDisabledConfigIsAlwaysValid() {
        var config = OpenCodeSyncConfig()
        config.hostAlias = "bogus host; rm -rf"
        XCTAssertNil(config.validated())
    }

    func testEnabledRequiresHostAlias() {
        XCTAssertEqual(
            enabledConfig(host: "").validated(),
            "Remote sync needs an SSH host alias.")
    }

    func testHostAliasAllowlist() {
        for good in ["myserver", "my-host.1", "mac_mini", "user@host", "H0ST-2.x_y"] {
            XCTAssertTrue(OpenCodeSyncConfig.isValidHostAlias(good), good)
            XCTAssertNil(enabledConfig(host: good).validated(), good)
        }
        for bad in ["", "has space", "a;b", "a|b", "a&b", "a$b", "a`b", "a'b",
                    "a\"b", "-leading-dash", "a:b", "a/b", "a\nb", "a$(x)"] {
            XCTAssertFalse(OpenCodeSyncConfig.isValidHostAlias(bad), bad)
        }
        XCTAssertNotNil(enabledConfig(host: "has space").validated())
        XCTAssertNotNil(enabledConfig(host: "-ssh").validated())
    }

    func testEnabledRequiresRemotePathOrCommand() {
        XCTAssertEqual(
            enabledConfig(path: "").validated(),
            "Remote sync needs a remote snapshot path or exporter command.")
        // Remote-command mode does not need a path.
        XCTAssertNil(enabledConfig(
            path: "",
            command: "python3 export-opencode-usage.py --db x.db").validated())
    }

    func testLineBreaksRejected() {
        XCTAssertNotNil(enabledConfig(path: "/tmp/a\nb.json").validated())
        XCTAssertNotNil(enabledConfig(
            path: "", command: "export x\nevil").validated())
    }

    func testIntervalAndTimeoutBounds() {
        XCTAssertNil(enabledConfig(poll: 300, timeout: 5).validated())
        XCTAssertNil(enabledConfig(poll: 86_400, timeout: 300).validated())
        XCTAssertEqual(
            enabledConfig(poll: 60).validated(),
            "Sync interval must be 5 minutes to 24 hours.")
        XCTAssertEqual(
            enabledConfig(poll: 100_000).validated(),
            "Sync interval must be 5 minutes to 24 hours.")
        XCTAssertEqual(
            enabledConfig(timeout: 1).validated(),
            "Sync timeout must be 5 to 300 seconds.")
        XCTAssertEqual(
            enabledConfig(timeout: 999).validated(),
            "Sync timeout must be 5 to 300 seconds.")
    }

    func testConfigRoundTripAndCorruptFallsBackToDefaults() throws {
        let dir = tempDir()
        let path = dir.appendingPathComponent("sync.json")
        let config = enabledConfig(host: "myhost", path: "/remote/u.json", poll: 1800, timeout: 30)
        try OpenCodeSync.saveConfig(config, to: path)
        let loaded = OpenCodeSync.loadConfig(from: path)
        XCTAssertEqual(loaded, config)
        // Corrupt file maps to safe disabled defaults, never throws.
        try "not json".data(using: .utf8)!.write(to: path)
        XCTAssertFalse(OpenCodeSync.loadConfig(from: path).enabled)
        XCTAssertFalse(OpenCodeSync.loadConfig(
            from: dir.appendingPathComponent("missing.json")).enabled)
    }

    // MARK: - Safe argv construction (never a shell)

    func testScpArgumentsAreDiscreteAndBatchMode() {
        let (exe, args) = OpenCodeSync.scpArguments(
            config: enabledConfig(host: "myhost", path: "/remote/u.json"),
            destination: "/tmp/local.json")
        XCTAssertEqual(exe, "/usr/bin/scp")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        // host:path travels as ONE argv element (the scp separator), never
        // through a shell: no sh, no -c anywhere.
        XCTAssertTrue(args.contains("myhost:/remote/u.json"))
        XCTAssertFalse(args.contains { $0.contains("/bin/sh") || $0 == "-c" })
        XCTAssertFalse(args.contains { $0.contains(";") || $0.contains("|") })
        XCTAssertEqual(args.last, "/tmp/local.json")
    }

    func testSshArgumentsCarryCommandAfterSeparator() {
        let (exe, args) = OpenCodeSync.sshArguments(
            config: enabledConfig(command: "python3 export.py --db x.db"))
        XCTAssertEqual(exe, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("myserver"))
        // Discrete elements: host, "--", then the remote command verbatim.
        let sep = args.firstIndex(of: "--")!
        XCTAssertEqual(args[sep - 1], "myserver")
        XCTAssertEqual(args[sep + 1], "python3 export.py --db x.db")
        XCTAssertFalse(args.contains { $0.contains("/bin/sh") })
    }

    func testHostMetacharactersNeverReachArgv() {
        // Even a hostile alias stays one inert argv element: validation
        // rejects it, and construction never splits or shells it.
        var hostile = enabledConfig(host: "h;touch evil")
        XCTAssertNotNil(hostile.validated())
        hostile.hostAlias = "myserver"
        let (_, args) = OpenCodeSync.scpArguments(
            config: hostile, destination: "/tmp/l.json")
        XCTAssertEqual(args.filter { $0.hasPrefix("myserver:") }.count, 1)
    }

    // MARK: - Cache validation

    func testValidateSnapshotData() {
        XCTAssertTrue(OpenCodeSync.validateSnapshotData(snapshotData()))
        XCTAssertTrue(OpenCodeSync.validateSnapshotData(
            try! JSONSerialization.data(withJSONObject: [] as [Any])))
        XCTAssertFalse(OpenCodeSync.validateSnapshotData(Data("not json".utf8)))
        XCTAssertFalse(OpenCodeSync.validateSnapshotData(
            Data("{\"not\":\"an array\"}".utf8)))
        XCTAssertFalse(OpenCodeSync.validateSnapshotData(Data("<html>oops</html>".utf8)))
        // All-skipped garbage (wrong source, no timestamp, all-zero) must
        // NOT wipe a good cache.
        XCTAssertFalse(OpenCodeSync.validateSnapshotData(snapshotData([
            ["source": "codex", "timestamp": "2026-09-12T10:00:00Z",
             "inputTokens": 5, "outputTokens": 5],
            ["timestamp": "2026-09-12T10:00:00Z",
             "inputTokens": 0, "outputTokens": 0],
            ["inputTokens": 3],
        ])))
        // Oversize payloads are rejected before decode.
        XCTAssertFalse(OpenCodeSync.validateSnapshotData(
            Data(count: OpenCodeSync.maxSnapshotBytes + 1)))
    }

    func testValidateSnapshotMatchesFixture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Fixtures/synthetic-remote-sync-snapshot.json"))
        XCTAssertTrue(OpenCodeSync.validateSnapshotData(data))
    }

    func testValidateSnapshotMatchesLegacyFixture() throws {
        // Pre-rename `homeserver` labels still validate (backward compat).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Fixtures/synthetic-homeserver-sync-snapshot.json"))
        XCTAssertTrue(OpenCodeSync.validateSnapshotData(data))
    }

    // MARK: - Atomic replacement

    func testAtomicWriteRoundTripAndReplace() throws {
        let dir = tempDir()
        let dest = dir.appendingPathComponent("cache.json")
        try OpenCodeSync.writeSnapshotAtomically(Data("v1".utf8), to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), Data("v1".utf8))
        try OpenCodeSync.writeSnapshotAtomically(Data("v2".utf8), to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), Data("v2".utf8))
        // No temp files leak beside the cache.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["cache.json"])
    }

    // MARK: - Service: success, fallback, cancellation

    enum FakeFetchError: Error, Sendable { case boom }

    struct FakeFetcher: OpenCodeSnapshotFetching {
        let result: Result<Data, FakeFetchError>
        let slowNanoseconds: UInt64
        init(_ result: Result<Data, FakeFetchError>, slowNanoseconds: UInt64 = 0) {
            self.result = result
            self.slowNanoseconds = slowNanoseconds
        }
        func fetchSnapshot(config: OpenCodeSyncConfig) async throws -> Data {
            if slowNanoseconds > 0 { try await Task.sleep(nanoseconds: slowNanoseconds) }
            switch result {
            case .success(let data): return data
            case .failure(let error): throw error
            }
        }
    }

    func testSyncSuccessReplacesCacheAndMarksStatus() async throws {
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        let service = OpenCodeSyncService(fetcher: FakeFetcher(.success(snapshotData())))
        let result = await service.sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertTrue(result.didUpdateCache)
        XCTAssertNil(result.error)
        let loaded = try OpenCodeStore.loadSnapshot(at: cache.path)
        XCTAssertEqual(loaded.records.count, 1)
        // Stamping: the fixture's default `remote` origin becomes the
        // alias-derived endpoint label (`myserver` from enabledConfig).
        XCTAssertEqual(loaded.records.first?.origin, "myserver")
        XCTAssertEqual(loaded.records.first?.source, .opencode)
        let persisted = service.loadStatus(from: status)
        XCTAssertNotNil(persisted.lastSuccessAt)
        XCTAssertNil(persisted.lastError)
    }

    func testSyncInvalidSnapshotPreservesLastGoodCache() async throws {
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        let good = snapshotData()
        try OpenCodeSync.writeSnapshotAtomically(good, to: cache)
        let service = OpenCodeSyncService(
            fetcher: FakeFetcher(.success(Data("truncated {".utf8))))
        let result = await service.sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertFalse(result.didUpdateCache)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.message.contains("kept previous data"))
        XCTAssertEqual(try Data(contentsOf: cache), good)
    }

    func testSyncFailureIsSanitizedAndPreservesCache() async throws {
        struct SecretLeak: Error { var path = "/Users/someone/SECRET-DB-KEY" }
        struct LeakyFetcher: OpenCodeSnapshotFetching {
            func fetchSnapshot(config: OpenCodeSyncConfig) async throws -> Data {
                throw SecretLeak()
            }
        }
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        let good = snapshotData()
        try OpenCodeSync.writeSnapshotAtomically(good, to: cache)
        let result = await OpenCodeSyncService(fetcher: LeakyFetcher()).sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertFalse(result.didUpdateCache)
        XCTAssertNotNil(result.error)
        // The underlying error (paths, secrets) never surfaces.
        XCTAssertFalse(result.message.contains("SECRET"))
        XCTAssertFalse(result.message.contains("/Users/"))
        XCTAssertTrue(result.message.contains("kept previous data"))
        XCTAssertEqual(try Data(contentsOf: cache), good)
    }

    func testSyncDisabledNeverFetches() async {
        struct ExplodingFetcher: OpenCodeSnapshotFetching {
            func fetchSnapshot(config: OpenCodeSyncConfig) async throws -> Data {
                XCTFail("disabled sync must not fetch")
                throw FakeFetchError.boom
            }
        }
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let result = await OpenCodeSyncService(fetcher: ExplodingFetcher()).sync(
            config: OpenCodeSyncConfig(), now: now,
            cacheURL: cache, statusURL: dir.appendingPathComponent("status.json"))
        XCTAssertFalse(result.didUpdateCache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testSyncCancellationPreservesCache() async throws {
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let good = snapshotData()
        try OpenCodeSync.writeSnapshotAtomically(good, to: cache)
        let service = OpenCodeSyncService(fetcher: FakeFetcher(
            .success(snapshotData()), slowNanoseconds: 30_000_000_000))
        let task = Task {
            await service.sync(
                config: enabledConfig(), now: now,
                cacheURL: cache,
                statusURL: dir.appendingPathComponent("status.json"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.didUpdateCache)
        XCTAssertTrue((result.error ?? "").lowercased().contains("cancell"))
        XCTAssertEqual(try Data(contentsOf: cache), good)
    }

    func testSanitizedErrorMapping() {
        XCTAssertTrue(OpenCodeSync.sanitizedError(CancellationError()).contains("cancelled"))
        XCTAssertTrue(OpenCodeSync.sanitizedError(OpenCodeSyncError.timedOut).contains("timed out"))
        XCTAssertTrue(OpenCodeSync.sanitizedError(OpenCodeSyncError.invalidSnapshot).contains("kept previous data"))
        XCTAssertTrue(OpenCodeSync.sanitizedError(OpenCodeSyncError.remoteFailed(255)).contains("unreachable"))
        XCTAssertTrue(OpenCodeSync.sanitizedError(OpenCodeSyncError.configInvalid("Custom msg.")).contains("Custom msg."))
        // Empty-kept notice: sanitized, keeps-history, actionable retry hint.
        let emptyKept = OpenCodeSync.sanitizedError(OpenCodeSyncError.emptySnapshotKeptPrevious)
        XCTAssertTrue(emptyKept.contains("kept previous data"))
        XCTAssertTrue(emptyKept.lowercased().contains("retry"))
        XCTAssertFalse(emptyKept.contains("/"))
    }

    // MARK: - Single cancellable owner (review: Cancel reaches every pull)

    private func slowPullResult(_ note: String) -> Task<OpenCodeSyncResult, Never> {
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return OpenCodeSyncResult(didUpdateCache: false, message: note)
        }
    }

    func testTaskOwnerNewestWinsAndSupersededCannotPublish() async {
        let owner = OpenCodeSyncTaskOwner()
        XCTAssertFalse(owner.isRunning)
        let first = slowPullResult("first")
        let id1 = owner.track(first)
        XCTAssertTrue(owner.isRunning)
        let second = slowPullResult("second")
        let id2 = owner.track(second)
        // Tracking the second pull cancels the first.
        XCTAssertTrue(first.isCancelled)
        XCTAssertFalse(second.isCancelled)
        // The superseded token must not publish.
        XCTAssertFalse(owner.complete(id: id1))
        XCTAssertNotEqual(id1, id2)
        XCTAssertTrue(owner.isRunning)
        XCTAssertTrue(owner.complete(id: id2))
        XCTAssertFalse(owner.isRunning)
        // Completing twice is a no-op: the token is spent.
        XCTAssertFalse(owner.complete(id: id2))
        _ = await first.value
        second.cancel()
        _ = await second.value
    }

    func testTaskOwnerCancelReachesInFlightPull() async {
        let owner = OpenCodeSyncTaskOwner()
        let slow = slowPullResult("slow")
        let id = owner.track(slow)
        owner.cancel()
        XCTAssertTrue(slow.isCancelled)
        XCTAssertFalse(owner.isRunning)
        XCTAssertFalse(owner.complete(id: id))
        _ = await slow.value
    }

    // MARK: - Bounded capture and capped reads (review: size cap first)

    func testReadCappedFile() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("snap.json")
        try Data(repeating: 0x41, count: 100).write(to: file)
        XCTAssertEqual(try OpenCodeSync.readCappedFile(at: file, maxBytes: 1000).count, 100)
        XCTAssertThrowsError(try OpenCodeSync.readCappedFile(at: file, maxBytes: 10)) { error in
            guard let syncError = error as? OpenCodeSyncError,
                  case .invalidSnapshot = syncError
            else { return XCTFail("expected invalidSnapshot, got \(error)") }
        }
        XCTAssertThrowsError(
            try OpenCodeSync.readCappedFile(
                at: dir.appendingPathComponent("missing.json"), maxBytes: 1000))
    }

    private func requireBinary(_ path: String) throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: path), "missing \(path)")
    }

    func testRunProcessEcho() async throws {
        try requireBinary("/bin/echo")
        let out = try await OpenCodeSync.runProcess(
            executable: "/bin/echo", arguments: ["hello-sync"], timeoutSeconds: 10)
        XCTAssertEqual(out, Data("hello-sync\n".utf8))
    }

    func testRunProcessTinyCapRejectsOversizedOutput() async throws {
        try requireBinary("/bin/echo")
        do {
            _ = try await OpenCodeSync.runProcess(
                executable: "/bin/echo", arguments: ["hello-world-over-cap"],
                timeoutSeconds: 10, maxOutputBytes: 5)
            XCTFail("expected invalidSnapshot")
        } catch let error as OpenCodeSyncError {
            guard case .invalidSnapshot = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testRunProcessCancellationIsPrompt() async throws {
        try requireBinary("/bin/sleep")
        let task = Task {
            try await OpenCodeSync.runProcess(
                executable: "/bin/sleep", arguments: ["30"], timeoutSeconds: 60)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Prompt exit: the 30s child never runs to completion.
        }
    }

    // MARK: - Atomic replacement without remove-then-move (review)

    func testReplaceFailurePreservesOriginalCache() throws {
        let dir = tempDir()
        let dest = dir.appendingPathComponent("cache.json")
        try OpenCodeSync.writeSnapshotAtomically(Data("good".utf8), to: dest)
        // Read-only directory: the swap cannot proceed, so it must throw
        // with the previous cache byte-identical and no temp leftovers.
        let roDir = dir.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let roDest = roDir.appendingPathComponent("cache.json")
        try OpenCodeSync.writeSnapshotAtomically(Data("good".utf8), to: roDest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: roDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: roDir.path)
        }
        XCTAssertThrowsError(
            try OpenCodeSync.writeSnapshotAtomically(Data("new".utf8), to: roDest))
        XCTAssertEqual(try Data(contentsOf: roDest), Data("good".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: roDir.path),
            ["cache.json"])
        XCTAssertEqual(try Data(contentsOf: dest), Data("good".utf8))
    }

    // MARK: - Documented decisions (review low-cost notes)

    // MARK: - Empty-snapshot guard (valid [] must not wipe history)

    func testEmptyFirstSyncAccepted() async throws {
        // No prior cache: a genuine empty first sync is valid, not corrupt.
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        let service = OpenCodeSyncService(fetcher: FakeFetcher(.success(Data("[]".utf8))))
        let result = await service.sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertTrue(result.didUpdateCache)
        XCTAssertNil(result.error)
        let loaded = try OpenCodeStore.loadSnapshot(at: cache.path)
        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertNil(service.loadStatus(from: status).lastError)
    }

    func testEmptySyncWithPriorEmptyCacheAccepted() async throws {
        // Prior cache exists but holds no records: nothing to protect, so
        // the empty pull is accepted like a first sync.
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        try OpenCodeSync.writeSnapshotAtomically(Data("[]".utf8), to: cache)
        let service = OpenCodeSyncService(fetcher: FakeFetcher(.success(Data("[]".utf8))))
        let result = await service.sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertTrue(result.didUpdateCache)
        XCTAssertNil(result.error)
        XCTAssertTrue(try OpenCodeStore.loadSnapshot(at: cache.path).records.isEmpty)
    }

    func testEmptySyncPreservesPriorRecords() async throws {
        // A transient exporter/server hiccup returning [] must not zero
        // previously imported usage: the last good cache wins and the user
        // gets a sanitized actionable notice.
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        let good = snapshotData()
        try OpenCodeSync.writeSnapshotAtomically(good, to: cache)
        let service = OpenCodeSyncService(fetcher: FakeFetcher(.success(Data("[]".utf8))))
        let result = await service.sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertFalse(result.didUpdateCache)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.message.contains("kept previous data"))
        XCTAssertTrue(result.message.lowercased().contains("retry"))
        // Sanitized: no paths, no host alias, no payload contents.
        XCTAssertFalse(result.message.contains("/"))
        XCTAssertFalse(result.message.contains("myserver"))
        XCTAssertFalse(result.message.contains(".json"))
        XCTAssertEqual(try Data(contentsOf: cache), good)
        XCTAssertEqual(try OpenCodeStore.loadSnapshot(at: cache.path).records.count, 1)
        // The retry notice persists on the status line for Settings/CLI.
        XCTAssertEqual(service.loadStatus(from: status).lastError, result.message)
    }

    func testEmptySyncWithMalformedPriorCacheAccepted() async throws {
        // Malformed prior cache holds no decodable records, so there is no
        // history to protect: the empty pull is accepted, not treated as
        // corruption.
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        try Data("not json".utf8).write(to: cache)
        let service = OpenCodeSyncService(fetcher: FakeFetcher(.success(Data("[]".utf8))))
        let result = await service.sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertTrue(result.didUpdateCache)
        XCTAssertNil(result.error)
        XCTAssertTrue(try OpenCodeStore.loadSnapshot(at: cache.path).records.isEmpty)
    }

    func testNonemptyReplacementStillWorks() async throws {
        // The guard only fires on empty pulls: a fresh nonempty snapshot
        // still replaces a nonempty cache.
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        try OpenCodeSync.writeSnapshotAtomically(snapshotData(), to: cache)
        let replacement = snapshotData([[
            "id": "opencode:sync-msg-2", "source": "opencode",
            "timestamp": "2026-09-12T11:00:00Z", "model": "opencode-go/m",
            "inputTokens": 10, "outputTokens": 5, "totalTokens": 15,
            "sessionId": "sync-ses-2", "requestId": "sync-msg-2",
            "origin": "remote",
        ]])
        let service = OpenCodeSyncService(fetcher: FakeFetcher(.success(replacement)))
        let result = await service.sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertTrue(result.didUpdateCache)
        XCTAssertNil(result.error)
        let loaded = try OpenCodeStore.loadSnapshot(at: cache.path)
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.records.first?.requestId, "sync-msg-2")
    }

    func testMalformedPayloadPreservesLastGoodCache() async throws {
        // Unchanged behavior: malformed pulls never touch the cache, and
        // local records keep rendering.
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        let good = snapshotData()
        try OpenCodeSync.writeSnapshotAtomically(good, to: cache)
        let service = OpenCodeSyncService(
            fetcher: FakeFetcher(.success(Data("truncated {".utf8))))
        let result = await service.sync(
            config: enabledConfig(), now: now, cacheURL: cache, statusURL: status)
        XCTAssertFalse(result.didUpdateCache)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.message.contains("kept previous data"))
        XCTAssertEqual(try Data(contentsOf: cache), good)
        XCTAssertEqual(try OpenCodeStore.loadSnapshot(at: cache.path).records.count, 1)
    }

    func testIsEmptySnapshotAndExistingCacheHasRecords() throws {
        XCTAssertTrue(OpenCodeSync.isEmptySnapshot(Data("[]".utf8)))
        XCTAssertFalse(OpenCodeSync.isEmptySnapshot(snapshotData()))
        XCTAssertFalse(OpenCodeSync.isEmptySnapshot(Data("not json".utf8)))
        XCTAssertFalse(OpenCodeSync.isEmptySnapshot(Data("{\"not\":\"array\"}".utf8)))
        let dir = tempDir()
        let missing = dir.appendingPathComponent("missing.json")
        XCTAssertFalse(OpenCodeSync.existingCacheHasRecords(at: missing))
        let empty = dir.appendingPathComponent("empty.json")
        try Data("[]".utf8).write(to: empty)
        XCTAssertFalse(OpenCodeSync.existingCacheHasRecords(at: empty))
        let malformed = dir.appendingPathComponent("malformed.json")
        try Data("truncated {".utf8).write(to: malformed)
        XCTAssertFalse(OpenCodeSync.existingCacheHasRecords(at: malformed))
        let full = dir.appendingPathComponent("full.json")
        try OpenCodeSync.writeSnapshotAtomically(snapshotData(), to: full)
        XCTAssertTrue(OpenCodeSync.existingCacheHasRecords(at: full))
    }

    func testRemotePathWithSpacesIsAllowed() {
        // Paths travel as one argv element (never word-split); only line
        // breaks are rejected. Host aliases stay strict (see allowlist test).
        XCTAssertNil(enabledConfig(path: "/tmp/my dir/opencode usage.json").validated())
    }

    // MARK: - Endpoint origin stamping (review: the label must take effect)

    private func stampRecord(origin: String?, useHostKey: Bool = false, id: String) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id, "source": "opencode",
            "timestamp": "2026-09-12T10:00:00Z", "model": "opencode-go/m",
            "inputTokens": 100, "outputTokens": 50, "totalTokens": 150,
            "sessionId": "sync-ses", "requestId": id,
        ]
        if let origin {
            dict[useHostKey ? "host" : "origin"] = origin
        }
        return dict
    }

    private func stampedOrigins(
        _ records: [[String: Any]], label: String
    ) throws -> [String: [String: Any]] {
        let data = try JSONSerialization.data(withJSONObject: records)
        let out = try OpenCodeSync.applyEffectiveOrigin(to: data, effectiveLabel: label)
        let decoded = try JSONSerialization.jsonObject(with: out) as! [[String: Any]]
        var byId: [String: [String: Any]] = [:]
        for record in decoded {
            byId[record["id"] as! String] = record
        }
        return byId
    }

    func testApplyEffectiveOriginStampsGenericKeepsExplicit() throws {
        let byId = try stampedOrigins([
            stampRecord(origin: nil, id: "opencode:missing"),
            stampRecord(origin: "remote", id: "opencode:default"),
            stampRecord(origin: "remote", useHostKey: true, id: "opencode:hostkey"),
            stampRecord(origin: "office", id: "opencode:custom"),
            stampRecord(origin: "local", id: "opencode:local"),
            stampRecord(origin: "homeserver", id: "opencode:legacy"),
            stampRecord(origin: "evil/x\ny", id: "opencode:hostile"),
        ], label: "myserver")
        XCTAssertEqual(byId["opencode:missing"]?["origin"] as? String, "myserver")
        XCTAssertEqual(byId["opencode:default"]?["origin"] as? String, "myserver")
        XCTAssertEqual(byId["opencode:hostkey"]?["origin"] as? String, "myserver")
        // Explicitly distinct labels survive: custom, local, legacy.
        XCTAssertEqual(byId["opencode:custom"]?["origin"] as? String, "office")
        XCTAssertNotEqual(byId["opencode:custom"]?["origin"] as? String, "myserver")
        XCTAssertEqual(byId["opencode:local"]?["origin"] as? String, "local")
        XCTAssertEqual(byId["opencode:legacy"]?["origin"] as? String, "homeserver")
        // Hostile labels never reach the cache verbatim.
        XCTAssertEqual(byId["opencode:hostile"]?["origin"] as? String, "myserver")
        // Non-token-adjacent content passes through untouched.
        XCTAssertEqual(byId["opencode:missing"]?["inputTokens"] as? Int, 100)
        XCTAssertEqual(byId["opencode:missing"]?["sessionId"] as? String, "sync-ses")
        // Decoding agrees: stamped generics land on the endpoint label.
        for id in ["opencode:missing", "opencode:default", "opencode:hostkey", "opencode:hostile"] {
            XCTAssertEqual(OpenCodeStore.decodeSnapshotRecord(byId[id]!)?.origin, "myserver", id)
        }
        XCTAssertEqual(OpenCodeStore.decodeSnapshotRecord(byId["opencode:legacy"]!)?.origin, "homeserver")
    }

    func testApplyEffectiveOriginEmptyPassesThrough() throws {        let empty = Data("[]".utf8)
        XCTAssertEqual(try OpenCodeSync.applyEffectiveOrigin(to: empty, effectiveLabel: "myserver"), empty)
    }

    func testApplyEffectiveOriginRejectsNonArray() {
        for raw in ["not json", "{\"not\":\"an array\"}", "<html>oops</html>"] {
            XCTAssertThrowsError(
                try OpenCodeSync.applyEffectiveOrigin(
                    to: Data(raw.utf8), effectiveLabel: "myserver")) { error in
                guard let syncError = error as? OpenCodeSyncError,
                      case .invalidSnapshot = syncError
                else { return XCTFail("expected invalidSnapshot for \(raw)") }
            }
        }
    }

    func testApplyEffectiveOriginSanitizesHostileLabel() throws {
        // A hostile configured label falls back to the generic default
        // instead of reaching the cache.
        let byId = try stampedOrigins(
            [stampRecord(origin: nil, id: "opencode:u")], label: "evil/x\ny")
        XCTAssertEqual(byId["opencode:u"]?["origin"] as? String, "remote")
    }

    func testApplyEffectiveOriginScansAllFields() throws {
        // All origin-ish fields are scanned in decode precedence: an
        // explicit label in any field beats a generic `origin`, and the
        // generic default counts case-insensitively.
        func multi(_ fields: [String: String], id: String) -> [String: Any] {
            var dict: [String: Any] = [
                "id": id, "source": "opencode",
                "timestamp": "2026-09-12T10:00:00Z", "model": "m",
                "inputTokens": 100, "outputTokens": 50,
                "sessionId": "s", "requestId": id,
            ]
            for (key, value) in fields { dict[key] = value }
            return dict
        }
        let byId = try stampedOrigins([
            multi(["origin": "remote", "host": "office"], id: "opencode:host-wins"),
            multi(["origin": "REMOTE"], id: "opencode:upper-remote"),
            multi(["host": "office"], id: "opencode:host-only"),
            multi(["origin": "office", "host": "remote"], id: "opencode:origin-precedence"),
            multi(["origin": "evil/x", "host": "office"], id: "opencode:hostile-origin"),
            multi(["origin": "homeserver", "host": "office"], id: "opencode:legacy-precedence"),
        ], label: "myserver")
        XCTAssertEqual(byId["opencode:host-wins"]?["origin"] as? String, "office")
        XCTAssertEqual(byId["opencode:upper-remote"]?["origin"] as? String, "myserver")
        XCTAssertEqual(byId["opencode:host-only"]?["origin"] as? String, "office")
        XCTAssertEqual(byId["opencode:origin-precedence"]?["origin"] as? String, "office")
        XCTAssertEqual(byId["opencode:hostile-origin"]?["origin"] as? String, "office")
        XCTAssertEqual(byId["opencode:legacy-precedence"]?["origin"] as? String, "homeserver")
        // Canonicalization agrees with decode: the stored `origin` key wins.
        XCTAssertEqual(
            OpenCodeStore.decodeSnapshotRecord(byId["opencode:host-wins"]!)?.origin, "office")
    }

    func testCacheURLToLoadBranches() throws {
        // Isolated support directory: never touches real user paths.
        let dir = tempDir()
        let support = dir.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let generic = support.appendingPathComponent(OpenCodeSync.cacheFileName)
        let legacy = support.appendingPathComponent(OpenCodeSync.legacyCacheFileName)
        // Neither exists: the generic destination (missing stays silent).
        XCTAssertEqual(OpenCodeSync.cacheURLToLoad(supportDirectory: support), generic)
        // Only legacy: upgrades keep their last good pull.
        try Data("old".utf8).write(to: legacy)
        XCTAssertEqual(OpenCodeSync.cacheURLToLoad(supportDirectory: support), legacy)
        // Both exist: the generic cache wins.
        try Data("new".utf8).write(to: generic)
        XCTAssertEqual(OpenCodeSync.cacheURLToLoad(supportDirectory: support), generic)
    }

    func testCacheURLToLoadOverrideBypassesFallback() {
        // An explicit override is read exactly as set: no fallback lookup.
        let custom = tempDir().appendingPathComponent("custom.json")
        setenv("TOKENBAR_OPENCODE_SYNC_CACHE", custom.path, 1)
        defer { unsetenv("TOKENBAR_OPENCODE_SYNC_CACHE") }
        XCTAssertEqual(OpenCodeSync.cacheURLToLoad().path, custom.path)
    }

    func testSyncStampsEffectiveOriginIntoCache() async throws {
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        let payload = try JSONSerialization.data(withJSONObject: [
            stampRecord(origin: nil, id: "opencode:u1"),
            stampRecord(origin: "remote", id: "opencode:u2"),
            stampRecord(origin: "office", id: "opencode:u3"),
            stampRecord(origin: "homeserver", id: "opencode:u4"),
        ])
        let service = OpenCodeSyncService(fetcher: FakeFetcher(.success(payload)))
        let result = await service.sync(
            config: enabledConfig(host: "myserver"), now: now,
            cacheURL: cache, statusURL: status)
        XCTAssertTrue(result.didUpdateCache)
        XCTAssertNil(result.error)
        let loaded = try OpenCodeStore.loadSnapshot(at: cache.path)
        XCTAssertEqual(loaded.records.count, 4)
        let origins = Dictionary(grouping: loaded.records, by: \.origin)
        XCTAssertEqual(Set(origins.keys), ["myserver", "office", "homeserver"])
        XCTAssertEqual(origins["myserver"]?.count, 2)
    }

    func testSyncStampsCustomOriginLabel() async throws {
        // An explicit originLabel wins over the alias-derived default.
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        let payload = try JSONSerialization.data(withJSONObject: [
            stampRecord(origin: nil, id: "opencode:u1"),
        ])
        var config = enabledConfig(host: "myserver")
        config.originLabel = "office"
        let service = OpenCodeSyncService(fetcher: FakeFetcher(.success(payload)))
        let result = await service.sync(
            config: config, now: now, cacheURL: cache, statusURL: status)
        XCTAssertTrue(result.didUpdateCache)
        let loaded = try OpenCodeStore.loadSnapshot(at: cache.path)
        XCTAssertEqual(loaded.records.first?.origin, "office")
    }

    func testSyncInvalidSnapshotStillPreservesLastGood() async throws {
        // Stamping never rescues a malformed pull: the last good cache wins.
        let dir = tempDir()
        let cache = dir.appendingPathComponent("cache.json")
        let status = dir.appendingPathComponent("status.json")
        let good = snapshotData()
        try OpenCodeSync.writeSnapshotAtomically(good, to: cache)
        let service = OpenCodeSyncService(
            fetcher: FakeFetcher(.success(Data("truncated {".utf8))))
        let result = await service.sync(
            config: enabledConfig(host: "myserver"), now: now,
            cacheURL: cache, statusURL: status)
        XCTAssertFalse(result.didUpdateCache)
        XCTAssertEqual(try Data(contentsOf: cache), good)
    }

    // MARK: - Refresh integration: synced rows join the load pass

    private func isolateLocalInputs() -> URL {
        let temp = tempDir()
        setenv("TOKENBAR_CODEX_ROOT", temp.path, 1)
        setenv("TOKENBAR_CLAUDE_ROOT", temp.path, 1)
        setenv("TOKENBAR_OPENCODE_DB", temp.appendingPathComponent("missing.db").path, 1)
        setenv("TOKENBAR_OPENCODE_DB_EXTRA", "", 1)
        setenv("TOKENBAR_OPENCODE_USAGE_JSON", "", 1)
        return temp
    }

    func testStoreLoadsSyncCacheAsRemoteOpencode() throws {
        let temp = isolateLocalInputs()
        defer {
            unsetenv("TOKENBAR_CODEX_ROOT")
            unsetenv("TOKENBAR_CLAUDE_ROOT")
            unsetenv("TOKENBAR_OPENCODE_DB")
            unsetenv("TOKENBAR_OPENCODE_DB_EXTRA")
            unsetenv("TOKENBAR_OPENCODE_USAGE_JSON")
            unsetenv("TOKENBAR_OPENCODE_SYNC_CACHE")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: root.appendingPathComponent(
            "Fixtures/synthetic-remote-sync-snapshot.json"))
        let cache = temp.appendingPathComponent("synced.json")
        try OpenCodeSync.writeSnapshotAtomically(fixture, to: cache)
        setenv("TOKENBAR_OPENCODE_SYNC_CACHE", cache.path, 1)

        let report = TokenBarStore.load()
        let synced = report.records.filter { $0.origin == "remote" || $0.origin == "myserver" }
        XCTAssertEqual(synced.count, 2)
        XCTAssertTrue(synced.allSatisfy { $0.source == .opencode })

        // Recent synced rows land in the 24h scope: the reported gap.
        let scoped = Aggregator.filter(
            report.records, source: .opencode, preset: .last24Hours,
            now: now, calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                return calendar
            }())
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.requestId, "sync-msg-1")
        let stats = Aggregator.aggregate(scoped)
        XCTAssertEqual(stats.totalTokens, 540)
    }

    func testStoreLoadsLegacyHomeserverSnapshot() throws {
        // Backward compatibility: pre-rename `homeserver` snapshots load.
        let temp = isolateLocalInputs()
        defer {
            unsetenv("TOKENBAR_CODEX_ROOT")
            unsetenv("TOKENBAR_CLAUDE_ROOT")
            unsetenv("TOKENBAR_OPENCODE_DB")
            unsetenv("TOKENBAR_OPENCODE_DB_EXTRA")
            unsetenv("TOKENBAR_OPENCODE_USAGE_JSON")
            unsetenv("TOKENBAR_OPENCODE_SYNC_CACHE")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: root.appendingPathComponent(
            "Fixtures/synthetic-homeserver-sync-snapshot.json"))
        let cache = temp.appendingPathComponent("synced.json")
        try OpenCodeSync.writeSnapshotAtomically(fixture, to: cache)
        setenv("TOKENBAR_OPENCODE_SYNC_CACHE", cache.path, 1)

        let report = TokenBarStore.load()
        XCTAssertEqual(report.records.filter { $0.origin == "homeserver" }.count, 2)
    }

    func testGenericDefaultsAndLegacyNames() {
        // New public defaults are generic; legacy names stay readable.
        XCTAssertEqual(OpenCodeSync.cacheFileName, "opencode-remote.json")
        XCTAssertEqual(OpenCodeSync.legacyCacheFileName, "opencode-homeserver.json")
        XCTAssertEqual(OpenCodeSync.defaultOrigin, "remote")
        XCTAssertEqual(OpenCodeSync.legacyOrigin, "homeserver")
        XCTAssertTrue(OpenCodeSync.defaultCacheURL().lastPathComponent == "opencode-remote.json")
    }

    func testEffectiveOriginLabelDerivesFromAliasSafely() {
        // Blank config falls back to the generic default.
        XCTAssertEqual(OpenCodeSyncConfig().effectiveOriginLabel, "remote")
        // A plain alias derives verbatim (sanitized).
        XCTAssertEqual(enabledConfig(host: "myserver").effectiveOriginLabel, "myserver")
        // An explicit custom label wins when valid.
        var custom = enabledConfig(host: "myserver")
        custom.originLabel = "office-mac_2.0"
        XCTAssertEqual(custom.effectiveOriginLabel, "office-mac_2.0")
        // Hostile labels fall back instead of leaking verbatim.
        var hostile = enabledConfig(host: "myserver")
        hostile.originLabel = "evil/x\ny"
        XCTAssertEqual(hostile.effectiveOriginLabel, "myserver")
        // user@host aliases are valid for SSH but not for origin labels:
        // they fall back to the generic default unless overridden.
        XCTAssertEqual(enabledConfig(host: "user@host").effectiveOriginLabel, "remote")
        var override = enabledConfig(host: "user@host")
        override.originLabel = "office"
        XCTAssertEqual(override.effectiveOriginLabel, "office")
        // Validation rejects hostile custom labels with a short message.
        var invalid = enabledConfig(host: "myserver")
        invalid.originLabel = "bad/label"
        XCTAssertNotNil(invalid.validated())
        // Old config files without the new key decode as blank (compat).
        let oldJSON = """
        {"enabled":true,"hostAlias":"myserver","remotePath":"/remote/u.json",\
        "remoteCommand":"","pollIntervalSeconds":900,"timeoutSeconds":60}
        """.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(OpenCodeSyncConfig.self, from: oldJSON)
        XCTAssertEqual(decoded.originLabel, "")
        XCTAssertEqual(decoded.effectiveOriginLabel, "myserver")
    }

    func testMissingSyncCacheIsSilent() {
        _ = isolateLocalInputs()
        defer {
            unsetenv("TOKENBAR_CODEX_ROOT")
            unsetenv("TOKENBAR_CLAUDE_ROOT")
            unsetenv("TOKENBAR_OPENCODE_DB")
            unsetenv("TOKENBAR_OPENCODE_DB_EXTRA")
            unsetenv("TOKENBAR_OPENCODE_USAGE_JSON")
            unsetenv("TOKENBAR_OPENCODE_SYNC_CACHE")
        }
        setenv("TOKENBAR_OPENCODE_SYNC_CACHE",
               tempDir().appendingPathComponent("never-synced.json").path, 1)
        let report = TokenBarStore.load()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertFalse(report.warnings.joined(separator: "\n").contains("sync"))
    }

    func testSyncCacheSkippedRowsAreCountedInWarning() throws {
        // Review: the skipped-row warning fires after EVERY OpenCode input,
        // so undecodable sync-cache rows are included, not dropped silently.
        let temp = isolateLocalInputs()
        defer {
            unsetenv("TOKENBAR_CODEX_ROOT")
            unsetenv("TOKENBAR_CLAUDE_ROOT")
            unsetenv("TOKENBAR_OPENCODE_DB")
            unsetenv("TOKENBAR_OPENCODE_DB_EXTRA")
            unsetenv("TOKENBAR_OPENCODE_USAGE_JSON")
            unsetenv("TOKENBAR_OPENCODE_SYNC_CACHE")
        }
        let cache = temp.appendingPathComponent("synced.json")
        let payload = try JSONSerialization.data(withJSONObject: [
            ["id": "opencode:ok-1", "source": "opencode",
             "timestamp": "2026-09-12T10:00:00Z", "model": "m",
             "inputTokens": 10, "outputTokens": 5,
             "sessionId": "s", "requestId": "r-ok"],
            ["inputTokens": 5], // no timestamp: undecodable, skipped + counted
        ])
        try OpenCodeSync.writeSnapshotAtomically(payload, to: cache)
        setenv("TOKENBAR_OPENCODE_SYNC_CACHE", cache.path, 1)
        let report = TokenBarStore.load()
        XCTAssertEqual(report.records.count, 1)
        XCTAssertTrue(report.warnings.contains(where: {
            $0.contains("OpenCode row(s) skipped")
        }), "warnings: \(report.warnings)")
    }
}
