import Foundation
import TokenBarCore

/// Observable wrapper around `OpenCodeSyncService` for the menu-bar popover.
///
/// - Startup and periodic sync are opt-in: with `config.enabled == false`
///   (the default) this controller never spawns a subprocess.
/// - Sync-then-load keeps the popover responsive: the pull runs off-main in
///   a cancellable `Task`, and the caller reloads usage after it finishes.
///   A second Sync Now cancels the first; sync success, failure, or
///   cancellation never blocks usage loading (the last good cache, or local
///   data, still renders).
/// - Published state hops back to the main actor. Status strings are the
///   sanitized service messages (no paths, usage, or remote output).
final class OpenCodeSyncController: ObservableObject {
    @Published var config = OpenCodeSync.loadConfig()
    @Published private(set) var status = OpenCodeSyncStatus()
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastDidUpdate = false

    private let service: OpenCodeSyncService
    private var syncTask: Task<Void, Never>?
    private var pollTimer: Timer?

    init(service: OpenCodeSyncService = OpenCodeSyncService()) {
        self.service = service
        self.status = service.loadStatus()
    }

    /// Persists the edited config (Settings fields). Disabling takes effect
    /// immediately: any in-flight pull is cancelled and the timer stops.
    func saveConfig() {
        trimFields()
        try? OpenCodeSync.saveConfig(config)
        if !config.enabled {
            cancel()
            stopPolling()
        }
    }

    /// The pull itself, safe from any thread. Publishes progress on the
    /// main actor. Concurrent callers are serialized by the UI-level
    /// `isSyncing` guard in `syncNow`; `forced` supersedes an in-flight
    /// pull for startup/periodic edges.
    func performSync() async {
        // Snapshot the config on the main actor: the Settings fields edit
        // it there, and this method may run from a background queue.
        let config = await MainActor.run { self.config }
        await MainActor.run {
            isSyncing = true
            lastError = nil
        }
        let result = await service.sync(config: config)
        await MainActor.run {
            status = service.loadStatus()
            lastError = result.error
            lastDidUpdate = result.didUpdateCache
            isSyncing = false
        }
    }

    /// Button entry point: runs the pull in the background and calls
    /// `onFinished` (the caller reloads usage there) on the main actor.
    /// Ignored while a pull is already running unless `forced`.
    func syncNow(forced: Bool = false, onFinished: (() -> Void)? = nil) {
        if isSyncing, !forced { return }
        syncTask?.cancel()
        syncTask = Task {
            await performSync()
            await MainActor.run {
                guard !Task.isCancelled else { return }
                onFinished?()
            }
        }
    }

    func cancel() {
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
    }

    /// Starts the periodic pull. Each tick runs sync-then-`onTick` only when
    /// enabled and idle. Safe to call repeatedly: the previous timer is
    /// replaced. Interval follows the saved config at each tick.
    func startPolling(onTick: @escaping () -> Void) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.config.enabled, !self.isSyncing else { return }
            let last = self.service.loadStatus().lastSuccessAt ?? .distantPast
            guard Date().timeIntervalSince(last) >= Double(self.config.pollIntervalSeconds) else { return }
            self.syncNow(forced: true, onFinished: onTick)
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Compact status line for Settings (one line, no setup prose).
    var statusLine: String {
        if !config.enabled { return "Homeserver sync: off." }
        if isSyncing { return "Syncing…" }
        if let error = lastError { return error }
        if let at = status.lastSuccessAt {
            return "Last synced \(at.formatted(date: .abbreviated, time: .shortened))."
        }
        return "On. Not synced yet."
    }

    private func trimFields() {
        config.hostAlias = config.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        config.remotePath = config.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        config.remoteCommand = config.remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        config.pollIntervalSeconds = min(
            max(config.pollIntervalSeconds, OpenCodeSync.minPollIntervalSeconds),
            OpenCodeSync.maxPollIntervalSeconds)
        config.timeoutSeconds = min(
            max(config.timeoutSeconds, OpenCodeSync.minTimeoutSeconds),
            OpenCodeSync.maxTimeoutSeconds)
    }
}
