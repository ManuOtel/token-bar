import SwiftUI
import TokenBarCore

/// Small chart views for the menu-bar dashboard (macOS 14, SwiftUI only).
///
/// All views render `AggregatedStats` via `DashboardInsights` shares.
/// Cached tokens read as a subset of input and reasoning as a subset of
/// output: the expanded composition ring splits the total into input vs
/// output only, and subset ratios appear as captions so charts never imply
/// double-counting. The compact summary uses a paired input/output bar
/// comparison instead of the ring: a linear ring goes blind when one side
/// dominates (for example 7.2B input vs 19.6M output leaves the output arc
/// at ~0.3%, effectively invisible), while the paired bars keep exact
/// counts prominent and use a labeled log scale plus a single 6%
/// visibility floor so the smaller side stays discoverable. Bar widths are
/// log-scaled, never shares; shares render via
/// `DashboardInsights.percentLabel` (whole percent rounded, one decimal
/// under 1%, so a small nonzero share never reads "0%"). Zero stays zero:
/// a zero side renders no bar and never trips the floor.

// MARK: - Compact input/output comparison (paired bars)

/// Truthful compact replacement for the proportional ring: two labeled
/// horizontal bars with exact counts, log-scaled widths, and subset
/// captions. Cached stays a caption on the input row and reasoning on the
/// output row, never a third bar, so neither reads as additional tokens.
/// Widths use the single `DashboardInsights.ioComparison` 6% floor (zero
/// stays zero); there is no extra point floor in this view.
struct TokenIOComparison: View {
    var stats: AggregatedStats
    var compactCount: (Int) -> String
    var fullCount: (Int) -> String

    var body: some View {
        let cmp = DashboardInsights.ioComparison(for: stats)
        let comp = DashboardInsights.composition(for: stats)
        VStack(alignment: .leading, spacing: 4) {
            Text("INPUT VS OUTPUT")
                .font(.caption2)
                .fontWeight(.semibold)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            if cmp.isEmpty {
                Text("No input/output split in this view.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No input or output tokens in this view")
            } else {
                ioRow(
                    color: .blue,
                    label: "Input",
                    value: cmp.inputTokens,
                    share: comp.inputShare,
                    display: cmp.inputDisplay
                )
                ioRow(
                    color: .orange,
                    label: "Output",
                    value: cmp.outputTokens,
                    share: comp.outputShare,
                    display: cmp.outputDisplay
                )
                Text("Cached \(compactCount(stats.cachedTokens)) · \(DashboardInsights.percentLabel(for: comp.cachedShareOfInput)) of input (subset)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Cached \(fullCount(stats.cachedTokens)) tokens, \(DashboardInsights.percentSpoken(for: comp.cachedShareOfInput)) of input, a subset")
                Text("Reasoning \(compactCount(stats.reasoningTokens)) · \(DashboardInsights.percentLabel(for: comp.reasoningShareOfOutput)) of output (subset)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Reasoning \(fullCount(stats.reasoningTokens)) tokens, \(DashboardInsights.percentSpoken(for: comp.reasoningShareOfOutput)) of output, a subset")
                Text(scaleFootnote(floored: cmp.smallerIsFloored))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel(scaleFootnote(floored: cmp.smallerIsFloored))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Input versus output comparison")
    }

    private func ioRow(color: Color, label: String, value: Int, share: Double, display: Double) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(label)
                .font(.callout)
                .lineLimit(1)
                .frame(width: 46, alignment: .leading)
                .accessibilityHidden(true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.9))
                        .frame(width: proxy.size.width * CGFloat(display), height: 8)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 0) {
                Text(fullCount(value))
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(DashboardInsights.percentLabel(for: share))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(minWidth: 92, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .help("\(label): \(fullCount(value)) tokens, \(DashboardInsights.percentLabel(for: share)) of total")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(fullCount(value)) tokens, \(DashboardInsights.percentSpoken(for: share)) of total")
        .accessibilityHint("Bar length uses a log scale so small values stay visible")
    }

    private func scaleFootnote(floored: Bool) -> String {
        if floored {
            return "Log-scale bars (widths are not shares); 6% minimum keeps the smaller side visible. Counts exact; % rounded, one decimal under 1%."
        }
        return "Log-scale bars so small values stay visible; widths are not shares. Counts exact; % rounded, one decimal under 1%."
    }
}

// MARK: - Token composition ring (expanded Details only)

struct TokenCompositionRing: View {
    var stats: AggregatedStats
    var compactCount: (Int) -> String

    var body: some View {
        let comp = DashboardInsights.composition(for: stats)
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 10)
                // Output arc first (background slice), then input arc.
                Circle()
                    .trim(from: 0, to: CGFloat(comp.outputShare))
                    .stroke(Color.orange.opacity(0.9), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: CGFloat(comp.outputShare), to: 1.0)
                    .stroke(Color.blue.opacity(0.9), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(comp.inputShare > 0 ? 1 : 0)
            }
            .frame(width: 64, height: 64)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Token composition")
            .accessibilityValue("Input \(DashboardInsights.percentSpoken(for: comp.inputShare)), output \(DashboardInsights.percentSpoken(for: comp.outputShare))")
            .help("Input \(DashboardInsights.percentLabel(for: comp.inputShare)) / output \(DashboardInsights.percentLabel(for: comp.outputShare)) of total")
            VStack(alignment: .leading, spacing: 3) {
                legendDot(color: .blue, label: "Input \(compactCount(stats.inputTokens))")
                legendDot(color: .orange, label: "Output \(compactCount(stats.outputTokens))")
                Text("Cached \(compactCount(stats.cachedTokens)) subset of input")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text("Reasoning \(compactCount(stats.reasoningTokens)) subset of output")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).monospacedDigit().lineLimit(1)
        }
    }
}

// MARK: - Source stacked bar

struct SourceStackedBar: View {
    var stats: AggregatedStats
    var compactCount: (Int) -> String

    private static let order = ["codex", "opencode", "claude"]

    var body: some View {
        let shares = DashboardInsights.shares(for: stats.bySource, totalTokens: stats.totalTokens)
        let byKey = Dictionary(uniqueKeysWithValues: shares.map { ($0.key, $0) })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(Self.order, id: \.self) { key in
                        let share = byKey[key]?.share ?? 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(sourceColor(key).opacity(share > 0 ? 0.9 : 0.15))
                            .frame(width: max(share > 0 ? proxy.size.width * CGFloat(share) - 2 : 4, 4))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Source distribution")
            .accessibilityValue(shares.map { "\($0.key) \(DashboardInsights.percentSpoken(for: $0.share))" }.joined(separator: ", "))
            HStack(spacing: 10) {
                ForEach(Self.order, id: \.self) { key in
                    let entry = byKey[key]
                    HStack(spacing: 4) {
                        Circle().fill(sourceColor(key)).frame(width: 6, height: 6)
                        Text("\(shortName(key)) \(compactCount(entry?.totalTokens ?? 0))")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    .help(entry == nil
                        ? "\(shortName(key)): no records in this range"
                        : "\(shortName(key)): \(entry!.totalTokens) tokens, \(entry!.requests) requests")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func sourceColor(_ key: String) -> Color {
        switch key {
        case "codex": return .green
        case "opencode": return .blue
        case "claude": return .orange
        default: return .gray
        }
    }

    private func shortName(_ key: String) -> String {
        switch key {
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "claude": return "Claude"
        default: return key
        }
    }
}

// MARK: - Model distribution bars

struct ModelDistributionBars: View {
    var stats: AggregatedStats
    var compactCount: (Int) -> String
    var fullCount: (Int) -> String
    var limit: Int = 5

    var body: some View {
        let models = Array(DashboardInsights.topModels(in: stats, limit: limit))
        let shares = DashboardInsights.shares(for: models, totalTokens: stats.totalTokens)
        VStack(alignment: .leading, spacing: 5) {
            if shares.isEmpty {
                Text("No models in this view.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(shares, id: \.key) { item in
                    HStack(spacing: 8) {
                        Text(item.key)
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.primary.opacity(0.12))
                                    .frame(height: 8)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.85))
                                    .frame(width: max(3, proxy.size.width * CGFloat(item.share)), height: 8)
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(width: 72, height: 10)
                        Text(compactCount(item.totalTokens))
                            .font(.callout).monospacedDigit().lineLimit(1)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .help("\(item.key): \(fullCount(item.totalTokens)) tokens, \(item.requests) requests, \(DashboardInsights.percentLabel(for: item.share)) of total")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.key), \(DashboardInsights.percentSpoken(for: item.share)) of total")
                }
            }
        }
    }
}

// MARK: - Adaptive trend chart

/// Trend bars, lines, and areas for the active range and grain (see
/// `TrendModel` and `ChartStyle`).
///
/// Renders the full selected coverage, not a 14-day suffix: hourly buckets
/// for Today/24H (including zero-token hours), daily buckets for 7D/30D/
/// Best (including empty days), monthly buckets for Lifetime. Bars size
/// down to fit the 400pt popover; histories wider than `maxInlineBars`
/// (long lifetimes) use a bounded horizontal scroll instead of shrinking
/// into illegibility. Line and area compress to the card width instead
/// (no scroll: continuity reads across the full range). X labels render
/// sparsely (every kth bucket plus the last) with the full first-last
/// range below; every bucket keeps its own tooltip and accessibility
/// label with the exact count. All styles share one series color, one
/// zero-based linear scale (`trendFractions`: zero stays zero, peak is 1),
/// and the thin `TrendComparisonLine` readout below the chart; the
/// comparison never becomes bars or area, and area is one unstacked
/// total-token series only.
struct AdaptiveTrendChart: View {
    var buckets: [TrendBucket]
    var grain: TrendGrain
    /// Active range: picks the Automatic renderer with the buckets.
    /// Compact always passes `.automatic` at mini size with no control.
    var preset: DatePreset
    /// User style selection; resolved per range via
    /// `ChartStyle.resolved(for:buckets:)`.
    var style: ChartStyle
    var fullCount: (Int) -> String
    var barHeight: CGFloat = 36

    /// Max bars that fit the 400pt popover without scrolling.
    private static let maxInlineBars = 32

    /// Resolved renderer for the stored snapshot (constant time over the
    /// stored buckets; no re-derivation).
    private var resolved: ResolvedTrendStyle {
        style.resolved(for: preset, buckets: buckets)
    }

    var body: some View {
        if buckets.isEmpty {
            Text("No trend buckets in this view.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            let fractions = DashboardInsights.trendFractions(for: buckets)
            VStack(alignment: .leading, spacing: 4) {
                switch resolved {
                case .bars:
                    chartContent(fractions: fractions)
                case .linePoints:
                    TrendSeriesPlot(
                        buckets: buckets,
                        grain: grain,
                        fractions: fractions,
                        fullCount: fullCount,
                        isArea: false,
                        plotHeight: barHeight)
                    tickRow
                case .area:
                    TrendSeriesPlot(
                        buckets: buckets,
                        grain: grain,
                        fractions: fractions,
                        fullCount: fullCount,
                        isArea: true,
                        plotHeight: barHeight)
                    tickRow
                }
                if let first = buckets.first?.label, let last = buckets.last?.label, first != last {
                    Text("\(first) - \(last)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func chartContent(fractions: [Double]) -> some View {
        if buckets.count > Self.maxInlineBars {
            ScrollView(.horizontal, showsIndicators: false) {
                bars(fractions: fractions, width: 8)
            }
            .frame(maxHeight: barHeight + 22)
        } else {
            bars(fractions: fractions, width: barWidth(for: buckets.count))
        }
    }

    private func bars(fractions: [Double], width: CGFloat) -> some View {
        // Sparse ticks: at most ~8 labels plus the last bucket, so hourly
        // and 30-day charts stay legible at 400pt.
        let stride = max(1, Int(ceil(Double(buckets.count) / 8.0)))
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(buckets.indices, id: \.self) { index in
                let bucket = buckets[index]
                let fraction = fractions[index]
                let showTick = index % stride == 0 || index == buckets.count - 1
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(bucket.totalTokens > 0 ? 0.85 : 0.25))
                        .frame(width: width, height: max(3, fraction * barHeight))
                    if showTick {
                        Text(shortTick(for: bucket))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(" ")
                            .font(.caption2).lineLimit(1)
                            .accessibilityHidden(true)
                    }
                }
                .help("\(bucket.label): \(fullCount(bucket.totalTokens)) tokens, \(bucket.requests) requests")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(spokenTick(for: bucket)), \(bucket.totalTokens) tokens")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sparse tick row under the line/area plot: at most ~8 labels plus
    /// the last bucket, the same stride rule as the bar ticks, so hourly
    /// and 30-day charts stay legible at 400pt. Ticks are display only;
    /// exact counts live in the per-bucket tooltips and labels above.
    private var tickRow: some View {
        let stride = max(1, Int(ceil(Double(buckets.count) / 8.0)))
        return HStack(spacing: 0) {
            ForEach(buckets.indices, id: \.self) { index in
                let bucket = buckets[index]
                let showTick = index % stride == 0 || index == buckets.count - 1
                Text(showTick ? shortTick(for: bucket) : " ")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Bar width that fits `count` bars in the ~344pt inner card width
    /// (400pt popover minus outer + card padding), 14pt max, 4pt min.
    private func barWidth(for count: Int) -> CGFloat {
        let inner: CGFloat = 344
        let spacing: CGFloat = 4
        let fit = (inner - spacing * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1))
        return min(14, max(4, floor(fit)))
    }

    private func shortTick(for bucket: TrendBucket) -> String {
        switch grain {
        case .hour:
            return bucket.label
        case .day, .month:
            return String(bucket.label.suffix(2))
        }
    }

    private func spokenTick(for bucket: TrendBucket) -> String {
        switch grain {
        case .hour:
            return "hour \(bucket.label)"
        case .day, .month:
            return bucket.label
        }
    }
}

// MARK: - Trend line / area plot

/// Zero-based linear plot behind the Line-with-points and Area renderers.
///
/// Same stored buckets, same peak scaling, same sparse ticks as Bars, one
/// series color throughout. Y maps 0...peak onto the plot height (no
/// truncated axis) with a hairline zero baseline; zero-token buckets sit
/// on the baseline, never hidden. Area is one unstacked total-token fill
/// with the line edge in the same series color: no stacked areas, no
/// per-source areas, no input/output split areas. The fill keeps a
/// contrast-safe opacity with a visible line edge under Increase Contrast.
/// The previous-period comparison stays the thin `TrendComparisonLine`
/// readout below the chart in all styles.
///
/// Standard content surface only: no material, no blur, no glass, no
/// animation. Style switches render the new marks immediately with no
/// transition that changes popover size.
struct TrendSeriesPlot: View {
    var buckets: [TrendBucket]
    var grain: TrendGrain
    /// Peak-scaled 0...1 heights (`trendFractions`: zero stays zero).
    var fractions: [Double]
    var fullCount: (Int) -> String
    /// True for the Area fill; false draws the line with visible points.
    var isArea: Bool
    var plotHeight: CGFloat
    @Environment(\.colorSchemeContrast) private var colorContrast

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                if isArea {
                    areaPath(width: width, height: height)
                        .fill(Color.accentColor.opacity(colorContrast == .increased ? 0.4 : 0.25))
                }
                seriesPath(width: width, height: height)
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
                // Zero baseline so the linear zero-based scale reads.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height - 0.5))
                    path.addLine(to: CGPoint(x: width, y: height - 0.5))
                }
                .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                if !isArea {
                    ForEach(buckets.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .position(
                                x: xPosition(index: index, width: width),
                                y: yPosition(fraction: fractions[index], height: height))
                            .accessibilityHidden(true)
                    }
                }
                // Per-bucket hover + VoiceOver slots: transparent
                // full-height strips so every bucket keeps its exact-count
                // tooltip and label in all styles (area draws no markers).
                HStack(spacing: 0) {
                    ForEach(buckets.indices, id: \.self) { index in
                        let bucket = buckets[index]
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .help("\(bucket.label): \(fullCount(bucket.totalTokens)) tokens, \(bucket.requests) requests")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(spokenTick(for: bucket)), \(bucket.totalTokens) tokens")
                    }
                }
            }
        }
        .frame(height: plotHeight)
    }

    private func xPosition(index: Int, width: CGFloat) -> CGFloat {
        guard buckets.count > 1 else { return width / 2 }
        return width * CGFloat(index) / CGFloat(buckets.count - 1)
    }

    private func yPosition(fraction: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        return height - CGFloat(clamped) * height
    }

    private func seriesPath(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            for index in buckets.indices {
                let point = CGPoint(
                    x: xPosition(index: index, width: width),
                    y: yPosition(fraction: fractions[index], height: height))
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }

    private func areaPath(width: CGFloat, height: CGFloat) -> Path {
        var path = seriesPath(width: width, height: height)
        guard !buckets.isEmpty else { return path }
        path.addLine(to: CGPoint(x: xPosition(index: buckets.count - 1, width: width), y: height))
        path.addLine(to: CGPoint(x: xPosition(index: 0, width: width), y: height))
        path.closeSubpath()
        return path
    }

    private func spokenTick(for bucket: TrendBucket) -> String {
        switch grain {
        case .hour:
            return "hour \(bucket.label)"
        case .day, .month:
            return bucket.label
        }
    }
}

// MARK: - Previous-period comparison line

/// Compact comparison readout under the trend chart.
///
/// Nil (Best/Lifetime, not one fixed period) renders nothing. A comparison
/// without baseline reads "No prior-period data", never a fabricated 0
/// percent. Otherwise "Up/Down X% vs <period>" (or "No change"), with exact
/// current-vs-previous counts in the tooltip and accessibility label.
struct TrendComparisonLine: View {
    var comparison: TrendComparison?
    var fullCount: (Int) -> String

    @ViewBuilder
    var body: some View {
        if let comparison {
            if !comparison.hasBaseline {
                Text("No prior-period data")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("No \(comparison.previousLabel) records to compare against")
                    .accessibilityLabel("No prior-period data")
                    .accessibilityHint("No \(comparison.previousLabel) records to compare against")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: iconName(for: comparison.direction))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(lineText(for: comparison))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help("\(fullCount(comparison.currentTotalTokens)) vs \(fullCount(comparison.previousTotalTokens)) tokens against \(comparison.previousLabel)")
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText(for: comparison))
            }
        }
    }

    private func lineText(for comparison: TrendComparison) -> String {
        switch comparison.direction {
        case .up:
            if let pct = comparison.percentChange {
                return "Up \(DashboardInsights.percentLabel(for: abs(pct) / 100)) vs \(comparison.previousLabel)"
            }
            return "Up vs \(comparison.previousLabel)"
        case .down:
            if let pct = comparison.percentChange {
                return "Down \(DashboardInsights.percentLabel(for: abs(pct) / 100)) vs \(comparison.previousLabel)"
            }
            return "Down vs \(comparison.previousLabel)"
        case .flat, .none:
            return "No change vs \(comparison.previousLabel)"
        }
    }

    private func accessibilityText(for comparison: TrendComparison) -> String {
        switch comparison.direction {
        case .up:
            if let pct = comparison.percentChange {
                return "Up \(DashboardInsights.percentSpoken(for: abs(pct) / 100)) versus \(comparison.previousLabel)"
            }
            return "Up versus \(comparison.previousLabel)"
        case .down:
            if let pct = comparison.percentChange {
                return "Down \(DashboardInsights.percentSpoken(for: abs(pct) / 100)) versus \(comparison.previousLabel)"
            }
            return "Down versus \(comparison.previousLabel)"
        case .flat, .none:
            return "No change versus \(comparison.previousLabel)"
        }
    }

    private func iconName(for direction: TrendComparison.Direction?) -> String {
        switch direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat, .none: return "minus"
        }
    }
}
