import SwiftUI
import TokenBarCore

/// Adaptive usage cockpit for the macOS menu-bar popover, in two modes.
/// Follows the system appearance: clean and bright under a normal light
/// appearance, coherent dark under a dark appearance. No forced color
/// scheme; all content surfaces use semantic SwiftUI colors so both
/// variants stay legible.
///
/// - Compact (initial): hero total, estimated cost, source/range controls,
///   a compact visual summary (paired input/output comparison, source bar,
///   adaptive mini trend plus a previous-period comparison line), and a
///   clear Details action. Fits a ~400pt popover without scrolling. The
///   comparison is a dual-bar view, not a proportional ring:
///   exact input/output counts stay prominent and log-scaled bars keep a
///   much smaller side discoverable.
/// - Expanded (Details): the full readable breakdown (section header with
///   a Show less action, metric cards, composition, source rows with
///   OpenCode origin split, model bars, adaptive trend with grain caption,
///   notices, plus a bottom Show less action), scrollable.
///
/// Launch at login, pricing, and remote sync live behind the gear button
/// in the header (a small settings popover), never as always-visible footer
/// sections. The header holds only Refresh and Settings so the title row
/// stays uncrowded; expand/collapse lives in the content flow where the
/// eye already is.
/// Labels stay short and single-line so nothing wraps or clips at the
/// compact size; every control is a real button (keyboard focusable) with
/// a tooltip and accessibility label. Escape collapses Details.
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
    /// Adaptive trend for the selected scope, computed once per render in
    /// `TokenBarApp` via `DashboardSnapshot` (zero-filled buckets over the
    /// full selected range). Chart views render these values only; they do
    /// no record scanning, so renders stay cheap.
    var trendBuckets: [TrendBucket]
    /// Chart title naming the active range and grain ("TODAY BY HOUR"...).
    var trendTitle: String
    /// Previous-period comparison for chronological ranges; nil for Best
    /// and Lifetime, which are not one fixed period.
    var comparison: TrendComparison?
    @Binding var isLoading: Bool
    @Binding var isExpanded: Bool
    /// True while the on-screen report is previous cached data and the
    /// fresh background scan is still running.
    var isStaleCache: Bool
    var onRefresh: () -> Void
    /// First-appearance hook, guarded once in `TokenBarApp`: fires even
    /// when cached records exist, never on every menu open.
    var onInitialAppear: () -> Void
    @ObservedObject var loginItem: LaunchAtLoginController
    @ObservedObject var pricing: PricingController
    @ObservedObject var sync: OpenCodeSyncController
    var onSyncNow: () -> Void
    var onPollTick: () -> Void
    @State private var showSettings = false
    // Trend chart style preference (M12): one persisted string, Automatic
    // default, unknown values fall back to Automatic. Read through
    // AppStorage so it applies at launch before first render; reset is
    // explicit only (the Reset control below), never a silent migration.
    // Compact always renders the Automatic mapping; the picker lives in
    // expanded Details only.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw: String = ChartStyle.defaultStyle.rawValue
    private var chartStyle: ChartStyle { ChartStyle(storedRawValue: chartStyleRaw) }
    // Liquid Glass inputs, read once per render: custom glass surfaces are
    // skipped under Reduce Transparency, and fallback strokes strengthen
    // under Increase Contrast. See LiquidGlass.swift.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorContrast
    private var increaseContrast: Bool { colorContrast == .increased }
    // Layout guards: these mirror the internal conditions of statusBanner
    // and notices so the parent omits them entirely when they would render
    // EmptyView. A bare EmptyView child still consumes VStack spacing,
    // leaving a bare window-material gap (a light/translucent strip in
    // light appearance) where content should hug. Hoisting the condition
    // keeps the content-sized popover tight with no behavior change when
    // content is present. Plain `if`, macOS 14-safe.
    private var showsStatusBanner: Bool {
        isStaleCache || (isLoading && !report.records.isEmpty && scopedCount > 0)
    }
    private var hasNotices: Bool {
        !ReportFormatter.sanitizeWarnings(report.warnings).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
                .padding(.vertical, -2)
                .accessibilityHidden(true)
            if showsStatusBanner {
                statusBanner
            }
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
                        detailsHeader
                        heroStats
                        metricGrid
                        compositionCard
                        sourceBreakdown
                        modelBreakdown
                        trendFull
                        if hasNotices {
                            notices
                        }
                        collapseFooter
                    }
                }
                // Sole expanded-height owner: nonzero viewport for the details
                // scroll region so the content-sized window (see TokenBarApp)
                // never grows unbounded. The minHeight is load-bearing: a
                // ScrollView has no intrinsic vertical size, so in the
                // content-sized MenuBarExtra window a maxHeight-only cap
                // resolves to ~0pt and Details renders only the outside
                // notices card. Plain frame, macOS 14-safe. Notices live
                // inside the scroll content so the first viewport shows
                // details and long notice lists scroll with them. Compact
                // mode has no scroll region.
                .frame(minHeight: 280, maxHeight: 380)
            }
            if report.records.isEmpty || scopedCount == 0 {
                if hasNotices {
                    notices
                }
            } else if !isExpanded {
                compactFooter
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            onInitialAppear()
        }
        .onExitCommand {
            // Escape collapses Details back to the compact summary.
            // No-op when already compact, when there is nothing to show,
            // or while the Settings popover is open (Escape belongs to
            // Settings then, not to the dashboard underneath).
            if !showSettings && isExpanded && !report.records.isEmpty && scopedCount > 0 {
                isExpanded = false
            }
        }
        .onDisappear {
            // If the outer menu-bar window is dismissed while the nested
            // settings popover is open, the presentation flag can stay true
            // and restore settings unexpectedly on the next reopen. Reset it
            // on teardown; normal popover open/close never triggers this.
            showSettings = false
        }
        .onReceive(sync.$config.map(\.enabled).removeDuplicates()) { enabled in
            // View-level lifecycle hook (Scene has no onReceive): a Settings
            // toggle takes effect without relaunch. Each tick is one pull
            // (in the controller) followed by one load-only pollTick here.
            if enabled {
                sync.startPolling(onTick: onPollTick)
            } else {
                sync.stopPolling()
            }
        }
    }

    // MARK: - Header

    /// Title row with only two icon actions (Refresh, Settings).
    /// Expand/collapse lives in the content flow, not here, so the top
    /// row scans as title + status + two targets. The caption names the
    /// active view for sighted scanning and VoiceOver.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
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
                Text("\(sourceShortLabel(source)) · \(rangeShortLabel(preset))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Token Bar, local usage, \(sourceLongLabel(source)), \(rangeHelp(preset))")
            Spacer()
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .accessibilityLabel("Loading updated usage")
            }
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.body)
                    .frame(minWidth: 30, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .liquidGlassHeaderButton()
            .disabled(isLoading)
            .help("Reload local histories now")
            .accessibilityLabel("Refresh")
            .accessibilityHint("Reloads local histories now")
            Button(action: { showSettings = true }) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.body)
                    .frame(minWidth: 30, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .liquidGlassHeaderButton()
            .help("Open settings: launch at login, pricing, remote sync")
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens launch at login, pricing, and sync settings")
            .popover(isPresented: $showSettings) {
                SettingsView(loginItem: loginItem, pricing: pricing, sync: sync, onSyncNow: onSyncNow)
            }
        }
    }

    // MARK: - Status banner (stale cache / background refresh)

    /// One-line status slot below the header. Stale cache reads as a calm
    /// pill with an icon; a manual refresh with live data keeps only the
    /// header spinner so the layout does not jump.
    @ViewBuilder
    private var statusBanner: some View {
        if isStaleCache {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Showing previous data - updating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Showing previous data, updating")
            .accessibilityHint("A background refresh is recomputing totals")
        } else if isLoading && !report.records.isEmpty && scopedCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Updating totals…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Updating totals")
        }
    }

    // MARK: - Controls

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionEyebrow("SOURCE")
                .accessibilityLabel("Source filter, \(sourceLongLabel(source)) selected")
            LiquidGlassContainer(spacing: LiquidGlass.chipRowSpacing) {
                HStack(spacing: 6) {
                    ForEach(sourceTotals, id: \.filter) { entry in
                        chipButton(
                            title: sourceShortLabel(entry.filter),
                            detail: compactCount(entry.tokens),
                            isActive: source == entry.filter,
                            help: "\(sourceLongLabel(entry.filter)): \(entry.requests) records in range"
                        ) { source = entry.filter }
                        .accessibilityLabel("\(sourceLongLabel(entry.filter)), \(entry.requests) records")
                        .accessibilityHint(source == entry.filter ? "Selected source filter" : "Switch source filter to \(sourceLongLabel(entry.filter))")
                        .accessibilityAddTraits(source == entry.filter ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionEyebrow("RANGE")
                .accessibilityLabel("Range filter, \(rangeHelp(preset)) selected")
            LiquidGlassContainer(spacing: LiquidGlass.chipRowSpacing) {
                HStack(spacing: 6) {
                    ForEach(DatePreset.allCases, id: \.self) { item in
                        chipButton(
                            title: rangeShortLabel(item),
                            detail: nil,
                            isActive: preset == item,
                            help: rangeHelp(item)
                        ) { preset = item }
                        .accessibilityLabel("Range \(rangeHelp(item))")
                        .accessibilityHint(preset == item ? "Selected range" : "Switch range to \(rangeHelp(item))")
                        .accessibilityAddTraits(preset == item ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }

    /// Shared small-caps section label. Callers attach a richer VoiceOver
    /// label naming the current selection; without an override the visible
    /// text itself is announced.
    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
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
                    .font(.callout)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .foregroundStyle(isActive ? .white : .primary)
            .liquidGlassChip(
                isActive: isActive,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            .contentShape(RoundedRectangle(cornerRadius: LiquidGlass.cornerRadius))
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    // MARK: - Compact summary (no scroll)

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TOTAL IN VIEW")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Text(fullCount(stats.totalTokens))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("\(fullCount(stats.totalTokens)) tokens in \(rangeLongLabel), \(sourceLongLabel(source))")
                Text("≈ \(costString(stats.estimatedCostUSD)) est.")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("\(stats.requests) req · \(stats.sessions) sess · \(rangeShortLabel(preset))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TokenIOComparison(stats: stats, compactCount: compactCount, fullCount: fullCount)
            SourceStackedBar(stats: stats, compactCount: compactCount)
            VStack(alignment: .leading, spacing: 4) {
                Text(trendTitle)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                AdaptiveTrendChart(
                    buckets: trendBuckets,
                    grain: TrendModel.grain(for: preset),
                    preset: preset,
                    // Compact stays compact: always the Automatic mapping
                    // at mini size, no style control, no added height.
                    style: .automatic,
                    fullCount: fullCount,
                    barHeight: 36)
                // Omitted (not EmptyView) when there is no previous period
                // (Best/Lifetime): keeps the trend stack tight instead of
                // leaving a bare-material spacing gap.
                if comparison != nil {
                    TrendComparisonLine(comparison: comparison, fullCount: fullCount)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Trend, \(trendAccessibilityLabel(for: .automatic))")
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Text("Show details: sources, models, trend")
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .liquidGlassAction(
                    isPrimary: true,
                    reduceTransparency: reduceTransparency,
                    increaseContrast: increaseContrast
                )
                .contentShape(RoundedRectangle(cornerRadius: LiquidGlass.cornerRadius))
            }
            .buttonStyle(.plain)
            .help("Expand richer details")
            .accessibilityLabel("Show details")
            .accessibilityHint("Shows sources, models and trend details. Escape collapses again.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var compactFooter: some View {
        let clean = ReportFormatter.sanitizeWarnings(report.warnings)
        // Note: no combined accessibility element on the outer row. The
        // notices Button must stay its own activatable element; combining
        // the row would swallow it from VoiceOver.
        return HStack(spacing: 6) {
            if clean.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Updated \(lastUpdatedShort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Button(action: { isExpanded = true }) {
                        Text("\(clean.count) notice\(clean.count == 1 ? "" : "s") - see Details")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Expand to read notices")
                    .accessibilityLabel("\(clean.count) notices, expand details to read")
                    .accessibilityHint("Opens the Details view with the notice list")
                }
            }
            Spacer()
        }
    }

    // MARK: - Details navigation (expanded)

    /// Section header pinned at the top of the expanded scroll content so
    /// collapse is reachable without hunting back to the title row.
    /// The header toggle was removed to declutter the title row.
    private var detailsHeader: some View {
        // Note: the combined element covers the label group only. The
        // Show less Button stays a sibling so VoiceOver keeps it as its
        // own activatable element; combining the whole row would swallow it.
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Details")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(sourceShortLabel(source)) · \(rangeShortLabel(preset))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Details, \(sourceLongLabel(source)), \(rangeHelp(preset))")
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: { isExpanded = false }) {
                Label("Show less", systemImage: "chevron.up")
                    .font(.callout)
            }
            .liquidGlassHeaderButton()
            .help("Collapse to the compact summary (or press Escape)")
            .accessibilityLabel("Collapse details")
            .accessibilityHint("Shows the compact summary")
        }
    }

    /// Bottom collapse target so long Details content does not force a
    /// scroll back to the top to get home.
    private var collapseFooter: some View {
        Button(action: { isExpanded = false }) {
            HStack {
                Text("Show less")
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .liquidGlassAction(
                isPrimary: false,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            .contentShape(RoundedRectangle(cornerRadius: LiquidGlass.cornerRadius))
        }
        .buttonStyle(.plain)
        .help("Collapse to the compact summary (or press Escape)")
        .accessibilityLabel("Collapse details")
        .accessibilityHint("Shows the compact summary")
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
        .background(Color.primary.opacity(0.06))
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
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var compositionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionEyebrow("COMPOSITION")
                .accessibilityLabel("Composition, input versus output split")
            TokenCompositionRing(stats: stats, compactCount: compactCount)
            let comp = DashboardInsights.composition(for: stats)
            Text("Ring splits the total into input (\(DashboardInsights.percentLabel(for: comp.inputShare))) vs output (\(DashboardInsights.percentLabel(for: comp.outputShare))). Cached (\(DashboardInsights.percentLabel(for: comp.cachedShareOfInput)) of input) and reasoning (\(DashboardInsights.percentLabel(for: comp.reasoningShareOfOutput)) of output) are subsets, never added on top.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Breakdowns + trend (expanded)

    private var sourceBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionEyebrow("SOURCES IN THIS RANGE")
                .accessibilityLabel("Sources in this range")
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
                    // above; local vs remote read as one short line each.
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
            sectionEyebrow("TOP MODELS")
                .accessibilityLabel("Top models in this view")
            ModelDistributionBars(stats: stats, compactCount: compactCount, fullCount: fullCount, limit: 5)
        }
    }

    private var trendFull: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Chart style menu: expanded Details only, next to the full
            // trend title and grain caption. Native menu control (Tab
            // reachable, visible focus ring); standard surface, no glass
            // on the chart or the menu. One selection applies to all
            // ranges; compact keeps the Automatic mapping.
            HStack(spacing: 8) {
                sectionEyebrow(trendTitle)
                    .accessibilityLabel("Trend, \(trendAccessibilityLabel(for: chartStyle))")
                Spacer()
                Picker("Chart style", selection: $chartStyleRaw) {
                    ForEach(ChartStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help("Choose the trend chart style for all ranges")
                .accessibilityLabel("Chart style")
                .accessibilityHint("Automatic picks bars or a line from the range; Bars, Line with points, and Area apply to all ranges")
                if chartStyle != .automatic {
                    Button("Reset") { chartStyleRaw = ChartStyle.defaultStyle.rawValue }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reset the chart style to Automatic")
                        .accessibilityLabel("Reset chart style")
                        .accessibilityHint("Returns the trend chart style to Automatic")
                }
            }
            AdaptiveTrendChart(
                buckets: trendBuckets,
                grain: TrendModel.grain(for: preset),
                preset: preset,
                style: chartStyle,
                fullCount: fullCount,
                barHeight: 64)
            // Same empty-gap guard as the compact trend: nil (Best/
            // Lifetime) stays out of the hierarchy entirely.
            if comparison != nil {
                TrendComparisonLine(comparison: comparison, fullCount: fullCount)
            }
            Text(trendCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Image(systemName: "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Reading local histories…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Reading local histories")
                .accessibilityHint("Scanning Codex, OpenCode, and Claude histories")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No usage data yet")
                        .font(.headline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("No usage data yet")
                Text("Token Bar reads local histories only. Nothing was found at:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex: ~/.codex/sessions/**/*.jsonl").font(.caption).monospaced()
                    Text("OpenCode: ~/.local/share/opencode/opencode.db").font(.caption).monospaced()
                    Text("Claude: ~/.claude/projects/**/*.jsonl").font(.caption).monospaced()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Checked Codex sessions, the OpenCode database, and Claude projects. Nothing found.")
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
                    .controlSize(.regular)
                    .help("Reload local histories now")
                    .accessibilityHint("Scans local histories again")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var noScopeState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Nothing in this view")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Nothing in this view")
            Text("No \(sourceLongLabel(source)) records in \(rangeLongLabel.lowercased()). Records may exist outside this range - try a wider range or another source.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Show all sources") { source = .all }
                    .buttonStyle(.bordered)
                    .help("Switch the source filter to all")
                    .accessibilityHint("Shows records from Codex, OpenCode, and Claude")
                if let wider = DashboardSnapshot.suggestedWiderPreset(for: preset) {
                    if wider == .lifetime {
                        Button("Show lifetime") { preset = .lifetime }
                            .buttonStyle(.bordered)
                            .help("Switch the range to lifetime")
                            .accessibilityHint("Removes the date filter")
                    } else {
                        Button("Show last 30 days") { preset = .last30Days }
                            .buttonStyle(.bordered)
                            .help("Switch the range to the last 30 days")
                            .accessibilityHint("Shows the last 30 days of records")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var notices: some View {
        // Sanitized: raw Store warnings carry absolute home paths, which must
        // never reach the menu bar UI.
        let clean = ReportFormatter.sanitizeWarnings(report.warnings)
        if !clean.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("NOTICES (\(clean.count))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(clean.count) notices")
                .accessibilityAddTraits(.isHeader)
                ForEach(clean, id: \.self) { warning in
                    Text("• \(friendlyNotice(warning))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Formatting helpers (display only, no semantics)

    private func compactCount(_ value: Int) -> String {
        TokenCountFormat.compact(value)
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

    /// VoiceOver summary of the adaptive trend: resolved style, grain,
    /// range, and comparison. Every style exposes this series summary;
    /// empty and no-baseline states read their explicit copy.
    private func trendAccessibilityLabel(for style: ChartStyle) -> String {
        let resolved = style.resolved(for: preset, buckets: trendBuckets)
        var parts = ["\(resolved.displayName) chart", trendCaptionShort]
        if let comparison {
            if comparison.hasBaseline {
                parts.append("compared with \(comparison.previousLabel)")
            } else {
                parts.append("no prior-period data")
            }
        }
        return parts.joined(separator: ", ")
    }

    private var trendCaptionShort: String {
        switch preset {
        case .today: return "hourly trend for today, including empty hours"
        case .last24Hours: return "hourly trend for the last 24 hours, including empty hours"
        case .last7Days: return "daily trend for the last 7 days, including empty days"
        case .last30Days: return "daily trend for the last 30 days, including empty days"
        case .bestMonth: return "daily trend for the best month"
        case .lifetime: return "monthly trend for all time"
        }
    }

    /// Expanded caption naming the bucket grain and the comparison period.
    /// Rolling ranges note the calendar-aligned display: buckets follow
    /// calendar days while the record window stays rolling, so edge days
    /// may be partial by design.
    private var trendCaption: String {
        switch preset {
        case .today:
            return "Hourly buckets for the local calendar day, including empty hours. Compared with yesterday."
        case .last24Hours:
            return "Hourly buckets for the rolling 24-hour window, including empty hours. Compared with the previous 24 hours."
        case .last7Days:
            return "Daily buckets for the rolling 7-day window, including empty days. Compared with the previous 7 days. Buckets are calendar-aligned; the record window stays rolling."
        case .last30Days:
            return "Daily buckets for the rolling 30-day window, including empty days. Compared with the previous 30 days. Buckets are calendar-aligned; the record window stays rolling."
        case .bestMonth:
            return "Daily buckets for the best month. No previous-period comparison: it is not one fixed chronological period."
        case .lifetime:
            return "Monthly buckets for the full history. No previous-period comparison: it is not one fixed chronological period."
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
        if warning.contains("sync cache unreadable") { return "Remote sync cache unreadable; using local data." }
        if warning.contains("extra non-token fields") { return "Snapshot had extra fields; token counts only." }
        if warning.contains("snapshot row(s) skipped") { return "Some snapshot rows skipped; counts only." }
        return warning
    }
}
