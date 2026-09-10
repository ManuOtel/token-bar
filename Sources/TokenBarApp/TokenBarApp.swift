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

    private var scoped: [NormalizedUsage] {
        Aggregator.filter(report.records, source: source, preset: preset, now: Date())
    }

    private var stats: AggregatedStats {
        if preset == .bestMonth {
            let lifetime = Aggregator.filter(report.records, source: source, preset: .lifetime, now: Date())
            return Aggregator.bestMonth(lifetime)?.stats ?? .empty
        }
        return Aggregator.aggregate(scoped)
    }

    private var menuTitle: String {
        if stats.totalTokens >= 1_000_000 {
            return String(format: "%.2fM", Double(stats.totalTokens) / 1_000_000.0)
        } else if stats.totalTokens >= 1_000 {
            return String(format: "%.1fk", Double(stats.totalTokens) / 1_000.0)
        }
        return "\(stats.totalTokens)"
    }

    var body: some Scene {
        MenuBarExtra("Tokens \(menuTitle)", systemImage: "chart.bar") {
            DashboardView(
                report: $report,
                source: $source,
                preset: $preset,
                stats: stats,
                scopedCount: scoped.count,
                isLoading: $isLoading,
                onRefresh: refresh
            )
            .frame(width: 360, height: 520)
        }
        .menuBarExtraStyle(.window)
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
