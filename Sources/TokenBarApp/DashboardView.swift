import SwiftUI
import TokenBarCore

/// Dark usage cockpit for the macOS menu-bar popover, in two modes.
///
/// - Compact (initial): hero total, estimated cost, source/range controls,
///   a compact visual summary (composition ring, source bar, mini trend),
///   and a clear Details action. Fits a ~400pt popover without scrolling.
/// - Expanded (Details): the full readable breakdown (metric cards,
///   composition, source rows with OpenCode origin split, model bars,
///   14-day trend, notices, launch-at-login toggle), scrollable.
///
/// Labels stay short and single-line so nothing wraps or clips at the
/// compact size; every control is a real button (keyboard focusable) with
/// a tooltip and accessibility label.
struct SourceChipData: Hashable {
    var filter: SourceFilter
    var tokens: Int
    var requests: Int
}

struct DashboardView: View {
    @Binding var report: LoadReport
    @Binding var source: SourceFilter
    @Binding var preset: DatePreset
    var stats: AggregatedStats
    var scopedCount: Int
    /// Per-source totals for the current range, in fixed source order.
    /// Shown on the source chips so an empty filter still reads as data
    /// ("OpenCode 0") instead of a dead control.
    var sourceTotals: [SourceChipData]
    var bestMonthKey: String?
    @Binding var isLoading: Bool
    @Binding var isExpanded: Bool
    var onRefresh: () -> Void
    @ObservedObject var loginItem: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sourceSection
            rangeSection
            if report.records.isEmpty {
                emptyState
            } else if scopedCount == 0 {
                noScopeState
            } else if !isExpanded {
                compactSummary
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        heroStats
                        metricGrid
                        compositionCard
                        sourceBreakdown
                        modelBreakdown
                        trendFull
                    }
                }
                .frame(maxHeight: 380)
            }
            if report.records.isEmpty || scopedCount == 0 {
                notices
                loginSection
            } else if !isExpanded {
                compactFooter
            } else {
                notices
                loginSection
            }
        }
        .padding(16)
        .frame(width: 400)
        .preferredColorScheme(.dark)
        .onAppear {
            if report.records.isEmpty && !isLoading { onRefresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TOKEN BAR")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Local usage")
                    .font(.headline)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Token Bar, local usage")
            Spacer()
            if isLoading { ProgressView().scaleEffect(0.7).accessibilityLabel("Loading") }
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
            .help("Reload local histories now")
            .accessibilityLabel("Refresh")
            Button(action: { isExpanded.toggle() }) {
                Label(
                    isExpanded ? "Show less" : "Details",
                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                )
                .font(.callout)
            }
            .buttonStyle(.bordered)
            .help(isExpanded ? "Collapse to the compact summary" : "Expand richer details")
            .accessibilityLabel(isExpanded ? "Collapse details" : "Expand details")
            .accessibilityHint(isExpanded ? "Shows the compact summary" : "Shows source, model and trend details")
        }
    }

    // MARK: - Controls

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCE")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(sourceTotals, id: \.filter) { entry in
                    chipButton(
                        title: sourceShortLabel(entry.filter),
                        detail: compactCount(entry.tokens),
                        isActive: source == entry.filter,
                        help: "\(sourceLongLabel(entry.filter)): \(entry.requests) records in range"
                    ) { source = entry.filter }
                    .accessibilityLabel("\(sourceLongLabel(entry.filter)), \(entry.requests) records")
                }
            }
        }
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RANGE")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(DatePreset.allCases, id: \.self) { item in
                    chipButton(
                        title: rangeShortLabel(item),
                        detail: nil,
                        isActive: preset == item,
                        help: rangeHelp(item)
                    ) { preset = item }
                    .accessibilityLabel("Range \(rangeHelp(item))")
                }
            }
        }
    }

    private func chipButton(
        title: String,
        detail: String?,
        isActive: Bool,
        help helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.caption)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(isActive ? .primary : .secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(isActive ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06))
            .foregroundStyle(isActive ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(isActive ? 0.0 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    // MARK: - Compact summary (no scroll)

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fullCount(stats.totalTokens))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel("\(fullCount(stats.totalTokens)) tokens")
                    Text("≈ \(costString(stats.estimatedCostUSD)) est.")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("\(stats.requests) req · \(stats.sessions) sess")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TokenCompositionRing(stats: stats, compactCount: compactCount)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SourceStackedBar(stats: stats, compactCount: compactCount)
            DailyTrendChart(stats: stats, fullCount: fullCount, maxBars: 14, barHeight: 36)
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text("Show details: sources, models, trend")
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Expand richer details")
            .accessibilityLabel("Show details")
            .accessibilityHint("Shows sources, models and trend details")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var compactFooter: some View {
        let clean = ReportFormatter.sanitizeWarnings(report.warnings)
        return HStack(spacing: 8) {
            if clean.isEmpty {
                Text("Updated \(lastUpdatedShort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button(action: { isExpanded = true }) {
                    Text("\(clean.count) notice\(clean.count == 1 ? "" : "s") - see Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Expand to read notices")
                .accessibilityLabel("\(clean.count) notices, expand details to read")
            }
            Spacer()
            Text(loginItem.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Hero + metrics (expanded)

    private var heroStats: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fullCount(stats.totalTokens))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("\(fullCount(stats.totalTokens)) tokens")
            Text("tokens in \(rangeLongLabel) · \(sourceLongLabel(source))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Text("≈ \(costString(stats.estimatedCostUSD)) est.")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("\(stats.requests) req · \(stats.sessions) sess")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Text("Estimate only; static table, not a bill; subscription use is not an API invoice.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if preset == .bestMonth, let key = bestMonthKey {
                Text("Best month: \(key)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let updated = stats.lastUpdated {
                Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metricCard(label: "Input", value: fullCount(stats.inputTokens))
            metricCard(label: "Output", value: fullCount(stats.outputTokens))
            metricCard(label: "Cached", value: fullCount(stats.cachedTokens), hint: "subset of input")
            metricCard(label: "Reasoning", value: fullCount(stats.reasoningTokens), hint: "subset of output")
        }
    }

    private func metricCard(label: String, value: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("\(label) \(value)\(hint.map { ", \($0)" } ?? "")")
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var compositionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMPOSITION")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            TokenCompositionRing(stats: stats, compactCount: compactCount)
            let comp = DashboardInsights.composition(for: stats)
            Text("Ring splits the total into input (\(Int(comp.inputShare * 100))%) vs output (\(Int(comp.outputShare * 100))%). Cached (\(Int(comp.cachedShareOfInput * 100))% of input) and reasoning (\(Int(comp.reasoningShareOfOutput * 100))% of output) are subsets, never added on top.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Breakdowns + trend (expanded)

    private var sourceBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCES IN THIS RANGE")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            SourceStackedBar(stats: stats, compactCount: compactCount)
            let byKey = Dictionary(uniqueKeysWithValues: stats.bySource.map { ($0.key, $0) })
            let maxTokens = max(stats.bySource.map(\.totalTokens).max() ?? 0, 1)
            ForEach([UsageSource.codex, .opencode, .claude], id: \.self) { usageSource in
                let entry = byKey[usageSource.rawValue]
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(sourceDot(usageSource))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(sourceName(usageSource))
                            .font(.callout)
                            .lineLimit(1)
                            .frame(width: 76, alignment: .leading)
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(sourceDot(usageSource).opacity(entry == nil ? 0.15 : 0.85))
                                .frame(
                                    width: max(3, proxy.size.width * CGFloat(entry?.totalTokens ?? 0) / CGFloat(maxTokens)),
                                    height: 8
                                )
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 10)
                        .accessibilityHidden(true)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(compactCount(entry?.totalTokens ?? 0))
                                .font(.callout)
                                .monospacedDigit()
                                .lineLimit(1)
                            Text(entry == nil ? "no records" : "\(entry!.requests) req")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 72, alignment: .trailing)
                    }
                    .opacity(entry == nil ? 0.65 : 1.0)
                    .help(entry == nil
                        ? "\(sourceName(usageSource)): no records in this range"
                        : "\(sourceName(usageSource)): \(fullCount(entry!.totalTokens)) tokens, \(entry!.requests) requests")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(entry == nil
                        ? "\(sourceName(usageSource)): no records"
                        : "\(sourceName(usageSource)): \(fullCount(entry!.totalTokens)) tokens, \(entry!.requests) requests")
                    // OpenCode origin split: combined total stays on the row
                    // above; local vs homeserver read as one short line each.
                    if usageSource == .opencode {
                        let origins = opencodeOriginRows
                        if origins.count > 1 {
                            ForEach(origins, id: \.key) { origin in
                                HStack(spacing: 6) {
                                    Text(originLabel(origin.key))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 76, alignment: .leading)
                                        .padding(.leading, 16)
                                    Spacer()
                                    Text("\(compactCount(origin.totalTokens)) · \(origin.requests) req")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                                .help("OpenCode \(originShort(origin.key)): \(fullCount(origin.totalTokens)) tokens, \(origin.requests) requests")
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("OpenCode \(originShort(origin.key)): \(fullCount(origin.totalTokens)) tokens")
                            }
                        }
                    }
                }
            }
        }
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOP MODELS")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            ModelDistributionBars(stats: stats, compactCount: compactCount, fullCount: fullCount, limit: 5)
        }
    }

    private var trendFull: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DAILY TREND")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            DailyTrendChart(stats: stats, fullCount: fullCount, maxBars: 14, barHeight: 64)
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Reading local histories…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("No usage data yet")
                    .font(.headline)
                Text("Token Bar reads local histories only. Nothing was found at:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex: ~/.codex/sessions/**/*.jsonl").font(.caption).monospaced()
                    Text("OpenCode: ~/.local/share/opencode/opencode.db").font(.caption).monospaced()
                    Text("Claude: ~/.claude/projects/**/*.jsonl").font(.caption).monospaced()
                }
                Text("Testing overrides: TOKENBAR_CODEX_ROOT, TOKENBAR_OPENCODE_DB, TOKENBAR_CLAUDE_ROOT.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Extras: TOKENBAR_OPENCODE_DB_EXTRA, TOKENBAR_OPENCODE_USAGE_JSON.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Retry now", action: onRefresh)
                    .buttonStyle(.bordered)
                    .help("Reload local histories now")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var noScopeState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing in this view")
                .font(.headline)
            Text("No \(sourceLongLabel(source)) records in \(rangeLongLabel.lowercased()). The data may live in another source or range.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Show all sources") { source = .all }
                    .buttonStyle(.bordered)
                    .help("Switch the source filter to all")
                Button("Show lifetime") { preset = .lifetime }
                    .buttonStyle(.bordered)
                    .help("Switch the range to lifetime")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var notices: some View {
        // Sanitized: raw Store warnings carry absolute home paths, which must
        // never reach the menu bar UI.
        let clean = ReportFormatter.sanitizeWarnings(report.warnings)
        if !clean.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("NOTICES (\(clean.count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                ForEach(clean, id: \.self) { warning in
                    Text(friendlyNotice(warning))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .accessibilityLabel("Launch at login")
            Text(loginItem.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(loginItem.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let error = loginItem.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Formatting helpers (display only, no semantics)

    private func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        } else if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    private static let fullFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    private func fullCount(_ value: Int) -> String {
        Self.fullFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func costString(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    private var lastUpdatedShort: String {
        guard let updated = stats.lastUpdated else { return "never" }
        return updated.formatted(date: .abbreviated, time: .shortened)
    }

    private func sourceShortLabel(_ filter: SourceFilter) -> String {
        switch filter {
        case .all: return "All"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .claude: return "Claude"
        }
    }

    private func sourceLongLabel(_ filter: SourceFilter) -> String {
        switch filter {
        case .all: return "All sources"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .claude: return "Claude"
        }
    }

    private func sourceName(_ source: UsageSource) -> String {
        switch source {
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .claude: return "Claude"
        }
    }

    private func sourceDot(_ source: UsageSource) -> Color {
        switch source {
        case .codex: return .green
        case .opencode: return .blue
        case .claude: return .orange
        }
    }

    private func rangeShortLabel(_ preset: DatePreset) -> String {
        switch preset {
        case .today: return "Today"
        case .last24Hours: return "24H"
        case .last7Days: return "7D"
        case .last30Days: return "30D"
        case .bestMonth: return "Best"
        case .lifetime: return "All"
        }
    }

    private var rangeLongLabel: String {
        switch preset {
        case .today: return "today"
        case .last24Hours: return "the last 24 hours"
        case .last7Days: return "the last 7 days"
        case .last30Days: return "the last 30 days"
        case .bestMonth: return "the best month"
        case .lifetime: return "lifetime"
        }
    }

    private func rangeHelp(_ preset: DatePreset) -> String {
        switch preset {
        case .today: return "Today: local calendar day"
        case .last24Hours: return "Range: rolling last 24 hours"
        case .last7Days: return "Range: rolling last 7 days"
        case .last30Days: return "Range: rolling last 30 days"
        case .bestMonth: return "Range: calendar month with most tokens"
        case .lifetime: return "Range: everything, no date filter"
        }
    }

    /// OpenCode origin rows for the current range, sorted tokens desc.
    private var opencodeOriginRows: [BreakdownEntry] {
        stats.byOrigin.filter { $0.key.hasPrefix("opencode/") }.sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.key < $1.key
        }
    }

    private func originLabel(_ key: String) -> String {
        "↳ \(originShort(key))"
    }

    private func originShort(_ key: String) -> String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    /// Rephrases raw sanitized warnings into scannable notice lines.
    /// Input is already path-free; this only shortens the phrasing.
    private func friendlyNotice(_ warning: String) -> String {
        if warning.contains("Codex sessions not found") { return "Codex history not found locally." }
        if warning.contains("OpenCode database not found") { return "OpenCode database not found locally." }
        if warning.contains("Claude sessions not found") { return "Claude history not found locally." }
        if warning.contains("SQLite module unavailable") { return "OpenCode skipped: SQLite unavailable in this build." }
        if warning.contains("OpenCode database unreadable") { return "OpenCode database unreadable; others still load." }
        if warning.contains("extra database not found") { return "OpenCode extra copy not found; using local data." }
        if warning.contains("extra database unreadable") { return "OpenCode extra copy unreadable; others still load." }
        if warning.contains("extra database skipped") { return "OpenCode extra skipped: SQLite unavailable." }
        if warning.contains("snapshot not found") { return "OpenCode snapshot not found; using local data." }
        if warning.contains("snapshot unreadable") { return "OpenCode snapshot unreadable; others still load." }
        if warning.contains("extra non-token fields") { return "Snapshot had extra fields; token counts only." }
        if warning.contains("snapshot row(s) skipped") { return "Some snapshot rows skipped; counts only." }
        return warning
    }
}
