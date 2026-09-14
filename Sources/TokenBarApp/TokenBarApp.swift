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
    @State private var report = LoadReport(records: [], skippedCodexLines: 0, skippedOpenCodeRows: 0, warnings: [])
    @State private var source: SourceFilter = .all
    @State private var preset: DatePreset = .today
    @State private var isLoading = false
    @State private var isExpanded = false
    @StateObject private var loginItem = LaunchAtLoginController()
    @StateObject private var pricing = PricingController()

    var body: some Scene {
        // One explicit clock per render: the snapshot reuses it for the
        // selected stats, chip totals, best-month key, and menu title, so
        // one render costs one sorted scope + one aggregate + one unsorted
        // chip pass instead of ~8 filter sorts + a second Date() for stale
        // menu titles. Pure value, no cache: report/source/preset/pricing
        // changes are inputs, so nothing can go stale.
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
                    onRefresh: refresh,
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
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            let loaded = TokenBarStore.load()
            DispatchQueue.main.async {
                self.report = loaded
                self.isLoading = false
            }
        }
    }
}
