import Foundation

/// Opt-in SSH pull of a sanitized OpenCode snapshot from a homeserver.
///
/// Problem: recent OpenCode tokens live on another host, so local-only
/// ranges (24h, 7d) read zero until the user hand-copies a snapshot file.
/// This service automates that copy over the user's own SSH setup: it runs
/// the system `ssh`/`scp` executable with an argument array (never a shell)
/// under the user's existing `~/.ssh/config` alias, pulls a pre-generated
/// token-only JSON snapshot (or runs the read-only exporter remotely and
/// captures its stdout), validates the payload, and atomically replaces the
/// local sync cache. `TokenBarStore` then loads that cache like any other
/// snapshot (origin `homeserver`, source `opencode`); aggregation and
/// dedupe are untouched.
///
/// Privacy and safety contract (pinned by tests + CI):
/// - No shell is ever invoked: `Process(executableURL:arguments:)` with
///   discrete argv elements. Host aliases, remote paths, and remote commands
///   travel as inert arguments, never through a command interpreter, so
///   metacharacters cannot escape.
/// - `BatchMode=yes` is always set: sync never prompts for a password and
///   never accepts interactive auth. Credentials live in the user's ssh
///   setup, never in this config (there is no password/key field by design).
/// - No usage data is ever sent: both modes are downloads only (scp copy or
///   remote stdout capture). No prompt text, token counts, paths, or
///   credentials leave the machine except the ssh connection itself.
/// - Errors are sanitized to generic labels: remote stdout/stderr, absolute
///   paths, and usage contents never enter results, status, or logs.
/// - Bounded: configurable timeout (default 60s, hard range 5-300s),
///   cancellable `Task`, snapshot size cap (32MB). Failures preserve the
///   last good cache: replacement happens only after successful validation.
///
/// This file is the ONLY place allowed to spawn a subprocess (CI-pinned).
/// Usage loading (`TokenBarStore.load`) stays file-reads-only and never
/// touches the network.
public enum OpenCodeSync {
    // MARK: - Tunables

    /// Default poll interval: 15 minutes. Range enforced by validation.
    public static let defaultPollIntervalSeconds = 900
    public static let minPollIntervalSeconds = 300
    public static let maxPollIntervalSeconds = 86_400
    /// Default per-attempt timeout. Range enforced by validation.
    public static let defaultTimeoutSeconds = 60
    public static let minTimeoutSeconds = 5
    public static let maxTimeoutSeconds = 300
    /// Snapshot size cap: token-only JSON is kilobytes; anything larger is
    /// rejected before decode so a runaway remote cannot blow up memory.
    public static let maxSnapshotBytes = 32 * 1024 * 1024
    public static let defaultSSHExecutable = "/usr/bin/ssh"
    public static let defaultSCPExecutable = "/usr/bin/scp"
    public static let configFileName = "opencode-sync.json"
    public static let cacheFileName = "opencode-homeserver.json"
    public static let statusFileName = "opencode-sync-status.json"

    public static var configPathOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_OPENCODE_SYNC_CONFIG"]
    }

    public static var cachePathOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_OPENCODE_SYNC_CACHE"]
    }

    public static var statusPathOverride: String? {
        ProcessInfo.processInfo.environment["TOKENBAR_OPENCODE_SYNC_STATUS"]
    }

    // MARK: - Paths

    public static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("TokenBar", isDirectory: true)
    }

    public static func defaultConfigURL(fileManager: FileManager = .default) -> URL {
        if let override = configPathOverride, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory(fileManager: fileManager).appendingPathComponent(configFileName)
    }

    public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        if let override = cachePathOverride, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory(fileManager: fileManager).appendingPathComponent(cacheFileName)
    }

    public static func defaultStatusURL(fileManager: FileManager = .default) -> URL {
        if let override = statusPathOverride, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory(fileManager: fileManager).appendingPathComponent(statusFileName)
    }

    // MARK: - Config persistence

    /// Loads the saved config, or safe empty-state defaults (disabled) when
    /// no config file exists yet. Never throws: a corrupt file maps to
    /// defaults so the app always starts with sync off.
    public static func loadConfig(
        from url: URL? = nil,
        fileManager: FileManager = .default
    ) -> OpenCodeSyncConfig {
        let path = url ?? defaultConfigURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: path),
              let config = try? JSONDecoder().decode(OpenCodeSyncConfig.self, from: data)
        else { return OpenCodeSyncConfig() }
        return config
    }

    public static func saveConfig(
        _ config: OpenCodeSyncConfig,
        to url: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let path = url ?? defaultConfigURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(config).write(to: path, options: .atomic)
    }

    // MARK: - Safe argv construction (pure, unit-pinned)

    /// scp mode (preferred): copies a pre-generated sanitized snapshot file.
    /// Returns `(executable, arguments)`: the `host:remote` pair is ONE argv
    /// element passed directly to the executable, never through a shell.
    /// `BatchMode=yes` forbids password prompts; `ConnectTimeout` bounds
    /// the TCP handshake on top of the service-level timeout.
    public static func scpArguments(
        config: OpenCodeSyncConfig,
        destination: String,
        scpExecutable: String = defaultSCPExecutable
    ) -> (executable: String, arguments: [String]) {
        (
            scpExecutable,
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=\(config.timeoutSeconds)",
                "\(config.hostAlias):\(config.remotePath)",
                destination,
            ]
        )
    }

    /// ssh mode: runs the read-only exporter on the remote host and captures
    /// its stdout. The command travels as discrete argv elements after `--`
    /// (no local shell); it is executed by the remote sshd with the remote
    /// user's privileges, so only a trusted user-supplied read-only exporter
    /// invocation belongs here (see `remoteCommand`).
    public static func sshArguments(
        config: OpenCodeSyncConfig,
        sshExecutable: String = defaultSSHExecutable
    ) -> (executable: String, arguments: [String]) {
        (
            sshExecutable,
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=\(config.timeoutSeconds)",
                config.hostAlias,
                "--",
                config.remoteCommand,
            ]
        )
    }

    // MARK: - Snapshot validation (pure, unit-pinned)

    /// Validates a candidate snapshot BEFORE it may replace the cache.
    /// Valid: a JSON top-level array that is empty or holds at least one
    /// record decodable by `OpenCodeStore.decodeSnapshotRecord` (token-only,
    /// source `opencode`, usable timestamp + counts). Anything else (HTML
    /// error pages, truncated transfers, all-skipped garbage) is invalid so
    /// a bad pull preserves the last good cache instead of zeroing it.
    /// Records with forbidden non-token keys are ignored by the loader, not
    /// rejected here. Size-capped before decode.
    ///
    /// Documented decision: a valid empty `[]` DOES replace the cache with
    /// zero rows. It means the remote host genuinely has no usage (for
    /// example a fresh install), and the global combine/dedupe renders that
    /// honestly. Only malformed or all-skipped payloads preserve the last
    /// good cache.
    public static func validateSnapshotData(_ data: Data) -> Bool {
        guard data.count <= maxSnapshotBytes else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let array = json as? [[String: Any]]
        else { return false }
        if array.isEmpty { return true }
        return array.contains {
            OpenCodeStore.decodeSnapshotRecord($0, originFallback: "homeserver") != nil
        }
    }

    // MARK: - Atomic cache replacement

    /// Replaces the cache atomically with no remove-then-move gap. When the
    /// destination exists, the validated bytes land in a same-directory temp
    /// file and `replaceItemAt` swaps them in one step (previous cache
    /// preserved on any failure); otherwise a single `.atomic` write creates
    /// it. Creates parent directories. Throws on failure with the previous
    /// cache untouched and no temp files left behind.
    public static func writeSnapshotAtomically(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let tmp = directory.appendingPathComponent(
            url.lastPathComponent + ".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - Subprocess (only Process use in the codebase)

    /// Runs one argv vector with stdout captured and a hard timeout.
    /// No shell, no stdin, stderr discarded (never logged: it may echo
    /// remote paths). Cancellation terminates the child. Stdout is drained
    /// incrementally and rejected with `invalidSnapshot` past
    /// `maxOutputBytes`, so oversized remote output is never fully buffered.
    /// Errors are sanitized: callers map them to generic labels, never raw
    /// output.
    public static func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: Int,
        maxOutputBytes: Int = maxSnapshotBytes
    ) async throws -> Data {
        let cap = max(1, maxOutputBytes)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = nil
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let outHandle = stdout.fileHandleForReading
        var output = Data()
        output.reserveCapacity(min(cap, 1_048_576))
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                throw OpenCodeSyncError.timedOut
            }
            // Non-blocking drain: `availableData` returns what the pipe
            // holds without waiting, so a chatty child is cut off at the cap
            // instead of filling memory before rejection.
            let chunk = outHandle.availableData
            if !chunk.isEmpty {
                output.append(chunk)
                if output.count > cap {
                    process.terminate()
                    throw OpenCodeSyncError.invalidSnapshot
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard process.terminationStatus == 0 else {
            throw OpenCodeSyncError.remoteFailed(process.terminationStatus)
        }
        let tail = outHandle.readDataToEndOfFile()
        guard output.count + tail.count <= cap else {
            throw OpenCodeSyncError.invalidSnapshot
        }
        output.append(tail)
        return output
    }

    /// Reads a freshly pulled file enforcing the snapshot size cap BEFORE
    /// the bytes are buffered: the on-disk size is checked first, then the
    /// read length is re-checked (TOCTOU-tolerant). Throws
    /// `invalidSnapshot` (last good cache preserved downstream) or the
    /// read error.
    public static func readCappedFile(
        at url: URL,
        maxBytes: Int = maxSnapshotBytes,
        fileManager: FileManager = .default
    ) throws -> Data {
        let cap = max(1, maxBytes)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > cap {
            throw OpenCodeSyncError.invalidSnapshot
        }
        let data = try Data(contentsOf: url)
        guard data.count <= cap else { throw OpenCodeSyncError.invalidSnapshot }
        return data
    }

    // MARK: - Sanitized errors (never paths, usage, or remote output)

    public static func sanitizedError(_ error: Error) -> String {
        if error is CancellationError { return "Homeserver sync cancelled." }
        if let syncError = error as? OpenCodeSyncError {
            switch syncError {
            case .timedOut: return "Homeserver sync timed out; kept previous data."
            case .invalidSnapshot: return "Remote snapshot invalid; kept previous data."
            case .configInvalid(let message): return message
            case .remoteFailed: return "Homeserver sync failed (host unreachable); kept previous data."
            }
        }
        return "Homeserver sync failed; kept previous data."
    }
}

/// User-configured sync endpoint. No secrets by design: auth comes from the
/// user's own `~/.ssh/config` + agent/keys, referenced by alias only.
/// Empty-state defaults are safe: sync ships disabled with blank host/path.
public struct OpenCodeSyncConfig: Codable, Hashable, Sendable {
    /// Master switch. Default false: upgrade never phones home on its own.
    public var enabled: Bool
    /// Non-secret SSH host alias from the user's own ssh config
    /// (for example `homeserver`). Never a password, key, or token.
    public var hostAlias: String
    /// Absolute (or `~/`-relative) path of the pre-generated sanitized
    /// snapshot on the remote host. Used in scp mode. Spaces are allowed:
    /// the path travels as one argv element and is never word-split (only
    /// line breaks are rejected by validation).
    public var remotePath: String
    /// Optional remote exporter invocation (for example
    /// `python3 ~/bin/export-opencode-usage.py --db ~/.local/share/opencode/opencode.db`).
    /// When non-empty, ssh mode runs it remotely and captures stdout instead
    /// of copying `remotePath`. Empty means scp mode.
    ///
    /// TRUST: the command executes through the REMOTE sshd shell with your
    /// remote user privileges. Enter only the read-only exporter invocation
    /// you wrote yourself. Local argv safety (no local shell, discrete
    /// arguments) does not and cannot sanitize remote execution.
    public var remoteCommand: String
    /// Poll interval for background sync, seconds. Clamped to 5min-24h.
    public var pollIntervalSeconds: Int
    /// Per-attempt timeout, seconds. Clamped to 5-300s.
    public var timeoutSeconds: Int

    public init(
        enabled: Bool = false,
        hostAlias: String = "",
        remotePath: String = "",
        remoteCommand: String = "",
        pollIntervalSeconds: Int = OpenCodeSync.defaultPollIntervalSeconds,
        timeoutSeconds: Int = OpenCodeSync.defaultTimeoutSeconds
    ) {
        self.enabled = enabled
        self.hostAlias = hostAlias
        self.remotePath = remotePath
        self.remoteCommand = remoteCommand
        self.pollIntervalSeconds = pollIntervalSeconds
        self.timeoutSeconds = timeoutSeconds
    }

    /// Allowed host-alias shape: short, no whitespace, no shell
    /// metacharacters, no colon (the scp `host:path` separator), never
    /// starting with `-` (flag injection). `user@host` passes.
    public static func isValidHostAlias(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 128 else { return false }
        guard let first = raw.unicodeScalars.first,
              CharacterSet.letters.union(.decimalDigits).contains(first)
        else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-@")
        return raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Nil when the config is usable; otherwise a short user-visible message
    /// (local-only, no secrets). A disabled config is always valid.
    public func validated() -> String? {
        guard enabled else { return nil }
        let host = hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return "Homeserver sync needs an SSH host alias."
        }
        guard Self.isValidHostAlias(host) else {
            return "Sync host alias has invalid characters (letters, digits, ., _, -, @)."
        }
        let command = remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty {
            guard !path.isEmpty else {
                return "Homeserver sync needs a remote snapshot path or exporter command."
            }
            guard !path.contains("\n") && !path.contains("\r") else {
                return "Remote snapshot path must not contain line breaks."
            }
        } else if command.contains("\n") || command.contains("\r") {
            return "Remote exporter command must not contain line breaks."
        }
        guard (OpenCodeSync.minPollIntervalSeconds...OpenCodeSync.maxPollIntervalSeconds)
            .contains(pollIntervalSeconds)
        else {
            return "Sync interval must be 5 minutes to 24 hours."
        }
        guard (OpenCodeSync.minTimeoutSeconds...OpenCodeSync.maxTimeoutSeconds)
            .contains(timeoutSeconds)
        else {
            return "Sync timeout must be 5 to 300 seconds."
        }
        return nil
    }
}

/// Last-known sync outcome, persisted beside the cache for the Settings
/// status line. Carries timestamps plus a sanitized message only: no paths,
/// counts, or remote output.
public struct OpenCodeSyncStatus: Codable, Hashable, Sendable {
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    /// Sanitized one-liner (see `OpenCodeSync.sanitizedError`), or nil.
    public var lastError: String?

    public init(lastSuccessAt: Date? = nil, lastAttemptAt: Date? = nil, lastError: String? = nil) {
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }
}

public enum OpenCodeSyncError: Error, Sendable {
    case timedOut
    case invalidSnapshot
    case remoteFailed(Int32)
    case configInvalid(String)
}

/// Outcome of one sync attempt. The cache file is replaced only on
/// validated success; every other path preserves the last good cache.
public struct OpenCodeSyncResult: Sendable {
    public var didUpdateCache: Bool
    /// Sanitized user-visible message (never paths, usage, or remote output).
    public var message: String
    public var error: String?

    public init(didUpdateCache: Bool, message: String, error: String? = nil) {
        self.didUpdateCache = didUpdateCache
        self.message = message
        self.error = error
    }
}

/// Fetch seam: the live implementation shells out to the system ssh/scp;
/// tests inject fakes. The fetcher returns raw snapshot bytes (scp mode
/// reads the copied temp file itself, size-capped); validation + atomic
/// replacement always happen in `OpenCodeSyncService`, never in the fetcher.
public protocol OpenCodeSnapshotFetching: Sendable {
    func fetchSnapshot(config: OpenCodeSyncConfig) async throws -> Data
}

/// Single cancellable owner for the in-flight pull.
///
/// The controller funnels every pull (startup, manual, polling) through one
/// tracked task, so Settings Cancel and disabling sync cancel whatever is
/// running -- not just polling pulls. Newest wins: tracking a task cancels
/// the previous one, and only the still-current token may publish its
/// outcome. Identity is a UUID token because `Task` is a struct and has no
/// reference identity. Lock-guarded; safe from any thread.
public final class OpenCodeSyncTaskOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var currentID: UUID?
    private var currentTask: Task<OpenCodeSyncResult, Never>?

    public init() {}

    /// Tracks `task` as the in-flight pull, cancelling any previous one.
    /// Returns the identity token to present to `complete`.
    @discardableResult
    public func track(_ task: Task<OpenCodeSyncResult, Never>) -> UUID {
        let id = UUID()
        lock.lock()
        defer { lock.unlock() }
        currentTask?.cancel()
        currentTask = task
        currentID = id
        return id
    }

    /// Clears the tracked pull if `id` is still current. Returns true only
    /// then, so a superseded pull never publishes stale UI state.
    @discardableResult
    public func complete(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentID == id else { return false }
        currentID = nil
        currentTask = nil
        return true
    }

    /// Cancels the in-flight pull, if any. Last-good cache is preserved by
    /// the service; the UI keeps rendering local data.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        currentTask?.cancel()
        currentTask = nil
        currentID = nil
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentID != nil
    }
}

/// Live fetcher over the system ssh/scp executables. No shell, BatchMode
/// only, bounded by the config timeout, cancellable via Task.
///
/// `Sendable` is unchecked but sound, same as `PricingService`: all state
/// is set at init and fetches mutate nothing shared.
public struct ProcessSnapshotFetcher: OpenCodeSnapshotFetching, @unchecked Sendable {
    public var sshExecutable: String
    public var scpExecutable: String
    public var fileManager: FileManager

    public init(
        sshExecutable: String = OpenCodeSync.defaultSSHExecutable,
        scpExecutable: String = OpenCodeSync.defaultSCPExecutable,
        fileManager: FileManager = .default
    ) {
        self.sshExecutable = sshExecutable
        self.scpExecutable = scpExecutable
        self.fileManager = fileManager
    }

    public func fetchSnapshot(config: OpenCodeSyncConfig) async throws -> Data {
        let command = config.remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            let (exe, args) = OpenCodeSync.sshArguments(config: config, sshExecutable: sshExecutable)
            return try await OpenCodeSync.runProcess(
                executable: exe, arguments: args,
                timeoutSeconds: config.timeoutSeconds,
                maxOutputBytes: OpenCodeSync.maxSnapshotBytes)
        }
        let tmp = fileManager.temporaryDirectory
            .appendingPathComponent("tokenbar-sync-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: tmp) }
        let (exe, args) = OpenCodeSync.scpArguments(
            config: config, destination: tmp.path, scpExecutable: scpExecutable)
        _ = try await OpenCodeSync.runProcess(
            executable: exe, arguments: args,
            timeoutSeconds: config.timeoutSeconds,
            maxOutputBytes: OpenCodeSync.maxSnapshotBytes)
        // Size-capped BEFORE buffering: a huge remote file never lands fully
        // in memory.
        return try OpenCodeSync.readCappedFile(at: tmp, fileManager: fileManager)
    }
}

/// Orchestrates one pull: config check, bounded fetch, validate, atomic
/// replace, status persist. Failures (including cancellation) preserve the
/// last good cache and surface a sanitized message.
///
/// `Sendable` is unchecked but sound, same as `PricingService`: all state
/// is set at init and sync paths mutate nothing shared (each sync uses
/// local values plus the atomic file write).
public struct OpenCodeSyncService: @unchecked Sendable {
    public var fetcher: any OpenCodeSnapshotFetching
    public var fileManager: FileManager

    public init(
        fetcher: (any OpenCodeSnapshotFetching)? = nil,
        fileManager: FileManager = .default
    ) {
        self.fetcher = fetcher ?? ProcessSnapshotFetcher(fileManager: fileManager)
        self.fileManager = fileManager
    }

    public func sync(
        config: OpenCodeSyncConfig,
        now: Date = Date(),
        cacheURL: URL? = nil,
        statusURL: URL? = nil
    ) async -> OpenCodeSyncResult {
        let destination = cacheURL ?? OpenCodeSync.defaultCacheURL(fileManager: fileManager)
        let statusDestination = statusURL ?? OpenCodeSync.defaultStatusURL(fileManager: fileManager)
        if !config.enabled {
            return OpenCodeSyncResult(
                didUpdateCache: false, message: "Homeserver sync is disabled.",
                error: "Homeserver sync is disabled.")
        }
        if let problem = config.validated() {
            saveStatus(OpenCodeSyncStatus(
                lastSuccessAt: loadStatus(from: statusDestination).lastSuccessAt,
                lastAttemptAt: now, lastError: problem), to: statusDestination)
            return OpenCodeSyncResult(didUpdateCache: false, message: problem, error: problem)
        }
        do {
            let data = try await withTimeout(seconds: config.timeoutSeconds) {
                try await self.fetcher.fetchSnapshot(config: config)
            }
            guard OpenCodeSync.validateSnapshotData(data) else {
                throw OpenCodeSyncError.invalidSnapshot
            }
            try OpenCodeSync.writeSnapshotAtomically(data, to: destination, fileManager: fileManager)
            saveStatus(OpenCodeSyncStatus(
                lastSuccessAt: now, lastAttemptAt: now, lastError: nil), to: statusDestination)
            return OpenCodeSyncResult(didUpdateCache: true, message: "Homeserver sync updated.")
        } catch {
            let message = OpenCodeSync.sanitizedError(error)
            let previous = loadStatus(from: statusDestination).lastSuccessAt
            saveStatus(OpenCodeSyncStatus(
                lastSuccessAt: previous, lastAttemptAt: now, lastError: message),
                to: statusDestination)
            return OpenCodeSyncResult(didUpdateCache: false, message: message, error: message)
        }
    }

    // MARK: - Status persistence (best-effort, never fatal)

    public func loadStatus(from url: URL? = nil) -> OpenCodeSyncStatus {
        let path = url ?? OpenCodeSync.defaultStatusURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: path) else { return OpenCodeSyncStatus() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(OpenCodeSyncStatus.self, from: data)
        else { return OpenCodeSyncStatus() }
        return status
    }

    private func saveStatus(_ status: OpenCodeSyncStatus, to url: URL) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(status).write(to: url, options: .atomic)
        } catch {
            // Status is informational only; a failed write never fails sync.
        }
    }

    /// Bounds any fetcher (including injected fakes) with cancellation.
    /// The loser is cancelled on EVERY exit (success, fast fetch error,
    /// timeout, outer cancellation): without the `defer`, a fast fetch
    /// error would leak the sleeper until it fires.
    private func withTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await operation() }
            group.addTask {
                let clamped = min(max(1, seconds), 3_600)
                try await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000_000)
                throw OpenCodeSyncError.timedOut
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}
