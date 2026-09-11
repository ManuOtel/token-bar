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
    @StateObject private var loginItem = LaunchAtLoginController()

    private static let sourceOrder: [SourceFilter] = [.all, .codex, .opencode, .claude]

    var body: some Scene {
        MenuBarExtra("Tokens \(menuTitle)", systemImage: "chart.bar") {
            // One clock per render so filter + stats + chips agree.
            let now = Date()
            let scoped = Aggregator.filter(report.records, source: source, preset: preset, now: now)
            let stats = Self.stats(records: report.records, source: source, preset: preset, now: now)
            let bestKey = Self.bestMonthKey(records: report.records, source: source, preset: preset, now: now)
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
                onRefresh: refresh,
                loginItem: loginItem
            )
            .frame(width: 400, height: 600)
        }
        .menuBarExtraStyle(.window)
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
        now: Date
    ) -> AggregatedStats {
        if preset == .bestMonth {
            let lifetime = Aggregator.filter(records, source: source, preset: .lifetime, now: now)
            return Aggregator.bestMonth(lifetime)?.stats ?? .empty
        }
        let scoped = Aggregator.filter(records, source: source, preset: preset, now: now)
        return Aggregator.aggregate(scoped)
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
