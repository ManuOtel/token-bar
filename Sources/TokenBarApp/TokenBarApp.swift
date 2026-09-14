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
                pricing: pricing
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

    /// First-appearance entry point: succeeds exactly once per process, even
    /// when cached records exist, so a cached menu still refreshes in the
    /// background. Menu opens never call this twice; the refresh button
    /// stays on `refresh()`.
    private func ensureInitialLoad() {
        var state = refreshState
        guard let generation = state.beginInitial() else { return }
        refreshState = state
        startLoad(generation: generation)
    }

    /// Off-main full scan with last-write-wins: only the latest generation
    /// may publish, so a stale/late completion is dropped instead of
    /// overwriting a newer report. Cache write failure is ignored so it
    /// never breaks a successful fresh load.
    private func startLoad(generation: Int) {
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            let loaded = TokenBarStore.load()
            try? StartupReportCache.save(loaded)
            DispatchQueue.main.async {
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
