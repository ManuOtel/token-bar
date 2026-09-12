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

    private static let sourceOrder: [SourceFilter] = [.all, .codex, .opencode, .claude]

    var body: some Scene {
        MenuBarExtra("Tokens \(menuTitle)", systemImage: "chart.bar") {
            // One clock per render so filter + stats + chips agree.
            let now = Date()
            let snapshot = pricing.snapshot
            let scoped = Aggregator.filter(report.records, source: source, preset: preset, now: now)
            let stats = Self.stats(records: report.records, source: source, preset: preset, now: now, snapshot: snapshot)
            let bestKey = Self.bestMonthKey(records: report.records, source: source, preset: preset, now: now)
            VStack(alignment: .leading, spacing: 0) {
                DashboardView(
                    report: $report,
                    source: $source,
                    preset: $preset,
                    stats: stats,
                    scopedCount: scoped.count,
                    sourceTotals: Self.sourceOrder.map { filter in
                        let rows = Aggregator.filter(report.records, source: filter, preset: preset, now: now)
                        return SourceChipData(
                            filter: filter,
                            tokens: rows.reduce(0) { $0 + $1.totalTokens },
                            requests: rows.count
                        )
                    },
                    bestMonthKey: bestKey,
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

    private var menuTitle: String {
        let now = Date()
        let scoped = Aggregator.filter(report.records, source: source, preset: preset, now: now)
        let total = scoped.reduce(0) { $0 + $1.totalTokens }
        if total >= 1_000_000 {
            return String(format: "%.2fM", Double(total) / 1_000_000.0)
        } else if total >= 1_000 {
            return String(format: "%.1fk", Double(total) / 1_000.0)
        }
        return "\(total)"
    }

    private static func stats(
        records: [NormalizedUsage],
        source: SourceFilter,
        preset: DatePreset,
        now: Date,
        snapshot: CatalogSnapshot? = nil
    ) -> AggregatedStats {
        if preset == .bestMonth {
            let lifetime = Aggregator.filter(records, source: source, preset: .lifetime, now: now)
            return Aggregator.bestMonth(lifetime, snapshot: snapshot)?.stats ?? .empty
        }
        let scoped = Aggregator.filter(records, source: source, preset: preset, now: now)
        return Aggregator.aggregate(scoped, snapshot: snapshot)
    }

    private static func bestMonthKey(
        records: [NormalizedUsage],
        source: SourceFilter,
        preset: DatePreset,
        now: Date
    ) -> String? {
        guard preset == .bestMonth else { return nil }
        let lifetime = Aggregator.filter(records, source: source, preset: .lifetime, now: now)
        return Aggregator.bestMonth(lifetime)?.monthKey
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
