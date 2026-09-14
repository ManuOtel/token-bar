import AppKit
import SwiftUI
import TokenBarCore

/// AppKit bridge: keeps the utility as a menu-bar-only accessory app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    // Perceived startup: show the last normalized report immediately so the
    // menu is useful before the full history scan finishes. First run with
    // no cache keeps the previous empty + loading behavior. Both values
    // derive from one shared seed so startup reads/decodes the file once.
    @State private var report: LoadReport
    @State private var source: SourceFilter = .all
    @State private var preset: DatePreset = .today
    @State private var isLoading = false
    @State private var isExpanded = false
    // True only when the on-screen report came from the startup cache and
    // the fresh background scan has not finished yet. Cleared on the first
    // fresh completion so cached values read as stale, never as live.
    @State private var isShowingStaleCache: Bool
    @State private var refreshState = StartupRefreshState()
    @StateObject private var loginItem = LaunchAtLoginController()
    @StateObject private var pricing = PricingController()
    @StateObject private var sync = OpenCodeSyncController()

    init() {
        let initial = StartupReportCache.initialState(cached: StartupReportCache.load())
        _report = State(initialValue: initial.report)
        _isShowingStaleCache = State(initialValue: initial.isShowingStaleCache)
    }

    var body: some Scene {
        // One explicit clock per render: the snapshot reuses it for the
        // selected stats, chip totals, best-month key, and menu title, so
        // one render costs one sorted scope + one aggregate + one unsorted
        // chip pass instead of ~8 filter sorts + a second Date() for stale
        // menu titles. The snapshot stays a pure value with no cache:
        // report/source/preset/pricing changes are inputs, so nothing can
        // go stale. The startup disk cache only seeds `report` once at
        // launch; every render still derives from the current report.
        let now = Date()
        let dash = DashboardSnapshot.make(
            records: report.records, source: source, preset: preset,
            now: now, snapshot: pricing.snapshot)
        return MenuBarExtra("Tokens \(DashboardSnapshot.menuTitle(forTotal: dash.menuTotalTokens))", systemImage: "chart.bar") {
            DashboardView(
                report: $report,
                source: $source,
                preset: $preset,
                stats: dash.stats,
                scopedCount: dash.scopedCount,
                sourceTotals: dash.sourceTotals.map { entry in
                    SourceChipData(
                        filter: entry.filter,
                        tokens: entry.tokens,
                        requests: entry.requests
                    )
                },
                bestMonthKey: dash.bestMonthKey,
                isLoading: $isLoading,
                isExpanded: $isExpanded,
                isStaleCache: isShowingStaleCache && isLoading && !report.records.isEmpty,
                onRefresh: refresh,
                onInitialAppear: ensureInitialLoad,
                loginItem: loginItem,
                pricing: pricing,
                sync: sync,
                onSyncNow: syncNow,
                onPollTick: pollTick
            )
            .frame(width: 400, height: isExpanded ? 660 : nil)
        }
        .menuBarExtraStyle(.window)
    }

    private func refresh() {
        var state = refreshState
        guard let generation = state.beginManual() else { return }
        refreshState = state
        startLoad(generation: generation)
    }

    /// Sync Now (Settings): pulls the homeserver snapshot first when sync is
    /// enabled, then runs the normal usage reload. With sync disabled it is
    /// just a refresh. Never blocks the popover: both steps run off-main.
    private func syncNow() {
        guard sync.config.enabled else {
            refresh()
            return
        }
        var state = refreshState
        let generation = state.beginForced()
        refreshState = state
        startLoad(generation: generation, withSync: true)
    }

    /// Periodic tick: reloads usage after the controller's pull. Load-only
    /// by design -- the pull already happened exactly once in the polling
    /// tick, so this must not start another. Skips politely when a scan is
    /// already in flight.
    private func pollTick() {
        var state = refreshState
        guard let generation = state.beginManual() else { return }
        refreshState = state
        startLoad(generation: generation)
    }

    /// First-appearance entry point: succeeds exactly once per process, even
    /// when cached records exist, so a cached menu still refreshes in the
    /// background. Menu opens never call this twice; the refresh button
    /// stays on `refresh()`. With sync enabled the first load pulls the
    /// homeserver snapshot first, then scans; the periodic timer starts too.
    private func ensureInitialLoad() {
        var state = refreshState
        guard let generation = state.beginInitial() else { return }
        refreshState = state
        if sync.config.enabled {
            sync.startPolling(onTick: pollTick)
            startLoad(generation: generation, withSync: true)
        } else {
            startLoad(generation: generation)
        }
    }

    /// Off-main full scan with last-write-wins: only the latest generation
    /// may publish, so a stale/late completion is dropped instead of
    /// overwriting a newer report. Cache write failure is ignored so it
    /// never breaks a successful fresh load. With `withSync`, the opt-in
    /// homeserver pull runs first (bounded, cancellable, last-good-cache
    /// preserving); usage loading never waits on pricing and never fails
    /// because sync failed. Structured concurrency throughout: no semaphores,
    /// no blocked threads; the heavy scan runs on a detached utility task.
    private func startLoad(generation: Int, withSync: Bool = false) {
        isLoading = true
        Task {
            if withSync {
                await sync.performSync()
            }
            let loaded = await Task.detached(priority: .utility) {
                TokenBarStore.load()
            }.value
            try? StartupReportCache.save(loaded)
            await MainActor.run {
                var state = self.refreshState
                guard state.finish(generation: generation) else { return }
                self.refreshState = state
                self.report = loaded
                self.isLoading = false
                self.isShowingStaleCache = false
            }
        }
    }
}
