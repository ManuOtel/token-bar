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
    // no cache keeps the previous empty + loading behavior.
    @State private var report: LoadReport = StartupReportCache.load()
        ?? LoadReport(records: [], skippedCodexLines: 0, skippedOpenCodeRows: 0, warnings: [])
    @State private var source: SourceFilter = .all
    @State private var preset: DatePreset = .today
    @State private var isLoading = false
    @State private var isExpanded = false
    // True only when the on-screen report came from the startup cache and
    // the fresh background scan has not finished yet. Cleared on the first
    // fresh completion so cached values read as stale, never as live.
    @State private var isShowingStaleCache: Bool = (StartupReportCache.load()?.records.isEmpty == false)
    @State private var refreshState = StartupRefreshState()
    @StateObject private var loginItem = LaunchAtLoginController()
    @StateObject private var pricing = PricingController()

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
            VStack(alignment: .leading, spacing: 0) {
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
                    loginItem: loginItem
                )
                pricingFooter
            }
            .frame(width: 400, height: isExpanded ? 660 : nil)
        }
        .menuBarExtraStyle(.window)
    }

    /// Pricing footer: user-initiated refresh only, last-update/source line,
    /// and an offline/error line. Never blocks usage loading: the refresh
    /// button only drives `PricingController`, and failures keep the
    /// previous snapshot (or static estimates) for the cost basis.
    private var pricingFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 8) {
                if pricing.isRefreshing {
                    ProgressView().scaleEffect(0.7)
                    Text("Updating pricing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Cancel", action: pricing.cancel)
                        .buttonStyle(.bordered)
                        .help("Cancel the in-flight pricing refresh")
                } else {
                    Button("Update pricing", action: pricing.refresh)
                        .buttonStyle(.bordered)
                        .help("Fetch the public model pricing catalog now (GET only, no usage data sent)")
                }
                Spacer()
            }
            Text(pricing.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let error = pricing.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("Costs are estimates, not a bill.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
