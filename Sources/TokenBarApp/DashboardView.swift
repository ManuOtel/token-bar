import SwiftUI
import TokenBarCore

/// Compact clickable dashboard: filters, presets, totals, breakdowns, trend.
struct DashboardView: View {
    @Binding var report: LoadReport
    @Binding var source: SourceFilter
    @Binding var preset: DatePreset
    var stats: AggregatedStats
    var scopedCount: Int
    @Binding var isLoading: Bool
    var onRefresh: () -> Void
    @ObservedObject var loginItem: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            sourcePicker
            presetPicker
            if report.records.isEmpty {
                emptyState
            } else if scopedCount == 0 {
                noScopeState
            } else {
                statsGrid
                breakdowns
                trend
            }
            warnings
            loginSection
            Spacer(minLength: 0)
        }
        .padding(12)
        .onAppear {
            if report.records.isEmpty && !isLoading { onRefresh() }
        }
    }

    private var header: some View {
        HStack {
            Text("Token Bar")
                .font(.headline)
            Spacer()
            if isLoading { ProgressView().scaleEffect(0.7) }
            Button("Refresh") { onRefresh() }
                .buttonStyle(.bordered)
                .disabled(isLoading)
        }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $source) {
            Text("All").tag(SourceFilter.all)
            Text("Codex").tag(SourceFilter.codex)
            Text("OpenCode").tag(SourceFilter.opencode)
            Text("Claude").tag(SourceFilter.claude)
        }
        .pickerStyle(.segmented)
    }

    private var presetPicker: some View {
        Picker("Range", selection: $preset) {
            Text("Today").tag(DatePreset.today)
            Text("24h").tag(DatePreset.last24Hours)
            Text("7d").tag(DatePreset.last7Days)
            Text("30d").tag(DatePreset.last30Days)
            Text("Best mo").tag(DatePreset.bestMonth)
            Text("All time").tag(DatePreset.lifetime)
        }
        .pickerStyle(.segmented)
    }

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            statRow("Total", "\(stats.totalTokens)")
            statRow("Input", "\(stats.inputTokens)")
            statRow("Output", "\(stats.outputTokens)")
            statRow("Cached", "\(stats.cachedTokens)")
            statRow("Reasoning", "\(stats.reasoningTokens)")
            statRow("Requests", "\(stats.requests)")
            statRow("Sessions", "\(stats.sessions)")
            statRow("Est. cost", String(format: "$%.4f", stats.estimatedCostUSD))
            if let updated = stats.lastUpdated {
                Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.callout)
    }

    private var breakdowns: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By model").font(.subheadline).bold()
            ForEach(stats.byModel.prefix(5), id: \.key) { entry in
                HStack {
                    Text(entry.key).lineLimit(1)
                    Spacer()
                    Text("\(entry.totalTokens)").monospacedDigit()
                }.font(.caption)
            }
            Text("By source").font(.subheadline).bold()
            ForEach(stats.bySource, id: \.key) { entry in
                HStack {
                    Text(entry.key)
                    Spacer()
                    Text("\(entry.totalTokens)").monospacedDigit()
                }.font(.caption)
            }
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily trend").font(.subheadline).bold()
            let buckets = stats.dailyTrend.suffix(14)
            let maxTokens = buckets.map(\.totalTokens).max() ?? 1
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(buckets, id: \.dayLabel) { bucket in
                    VStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.blue)
                            .frame(
                                width: 12,
                                height: max(CGFloat(2), CGFloat(bucket.totalTokens) / CGFloat(max(maxTokens, 1)) * 60)
                            )
                        Text(String(bucket.dayLabel.suffix(2)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .help("\(bucket.dayLabel): \(bucket.totalTokens) tokens, \(bucket.requests) requests")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No usage data found.").bold()
            Text("Checked:")
            Text("~/.codex/sessions/**/*.jsonl").font(.caption).monospaced()
            Text("~/.local/share/opencode/opencode.db").font(.caption).monospaced()
            Text("~/.claude/projects/**/*.jsonl").font(.caption).monospaced()
            Text("Override with TOKENBAR_CODEX_ROOT / TOKENBAR_OPENCODE_DB / TOKENBAR_CLAUDE_ROOT for testing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var noScopeState: some View {
        Text("No records in this filter/range. Try All sources or Lifetime.")
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var warnings: some View {
        // Sanitized: raw Store warnings carry absolute home paths, which must
        // never reach the menu bar UI.
        let clean = ReportFormatter.sanitizeWarnings(report.warnings)
        if !clean.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(clean, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )
            )
            .disabled(!loginItem.isBundled || !loginItem.isAvailable)
            Text(loginItem.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(loginItem.helpText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = loginItem.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}
