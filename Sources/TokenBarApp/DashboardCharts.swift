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
/// counts prominent and use a labeled log scale plus a visibility floor so
/// the smaller side stays discoverable.

// MARK: - Compact input/output comparison (paired bars)

/// Truthful compact replacement for the proportional ring: two labeled
/// horizontal bars with exact counts, log-scaled widths, and subset
/// captions. Cached stays a caption on the input row and reasoning on the
/// output row, never a third bar, so neither reads as additional tokens.
struct TokenIOComparison: View {
    var stats: AggregatedStats
    var compactCount: (Int) -> String
    var fullCount: (Int) -> String

    var body: some View {
        let cmp = DashboardInsights.ioComparison(for: stats)
        let comp = DashboardInsights.composition(for: stats)
        VStack(alignment: .leading, spacing: 6) {
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
                Text("Cached \(compactCount(stats.cachedTokens)) · \(Int(comp.cachedShareOfInput * 100))% of input (subset)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Cached \(fullCount(stats.cachedTokens)) tokens, \(Int(comp.cachedShareOfInput * 100)) percent of input, a subset")
                Text("Reasoning \(compactCount(stats.reasoningTokens)) · \(Int(comp.reasoningShareOfOutput * 100))% of output (subset)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Reasoning \(fullCount(stats.reasoningTokens)) tokens, \(Int(comp.reasoningShareOfOutput * 100)) percent of output, a subset")
                Text(scaleFootnote(floored: cmp.smallerIsFloored))
                    .font(.caption2).foregroundStyle(.secondary)
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
                        .frame(width: max(value > 0 ? 2.0 : 0.0, proxy.size.width * CGFloat(display)), height: 8)
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
                Text("\(Int(share * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(minWidth: 92, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .help("\(label): \(fullCount(value)) tokens, \(Int(share * 100))% of total")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(fullCount(value)) tokens, \(Int(share * 100)) percent of total")
        .accessibilityHint("Bar length uses a log scale so small values stay visible")
    }

    private func scaleFootnote(floored: Bool) -> String {
        if floored {
            return "Bars use a log scale with a minimum width, so the smaller side stays visible. Counts and % are exact."
        }
        return "Bars use a log scale so small values stay visible; counts and % are exact."
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
            .accessibilityValue("Input \(Int(comp.inputShare * 100)) percent, output \(Int(comp.outputShare * 100)) percent")
            .help("Input \(Int(comp.inputShare * 100))% / output \(Int(comp.outputShare * 100))% of total")
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
            .accessibilityValue(shares.map { "\($0.key) \(Int($0.share * 100)) percent" }.joined(separator: ", "))
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
                    .help("\(item.key): \(fullCount(item.totalTokens)) tokens, \(item.requests) requests, \(Int(item.share * 100))% of total")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.key), \(Int(item.share * 100)) percent of total")
                }
            }
        }
    }
}

// MARK: - Daily trend chart

struct DailyTrendChart: View {
    var stats: AggregatedStats
    var fullCount: (Int) -> String
    var maxBars: Int = 14
    var barHeight: CGFloat = 64

    var body: some View {
        let buckets = Array(stats.dailyTrend.suffix(maxBars))
        if buckets.isEmpty {
            Text("No daily buckets in this view.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            let fractions = DashboardInsights.trendFractions(for: buckets)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(buckets.indices, id: \.self) { index in
                        let bucket = buckets[index]
                        let fraction = fractions[index]
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(bucket.totalTokens > 0 ? 0.85 : 0.25))
                                .frame(width: 14, height: max(3, fraction * barHeight))
                            Text(String(bucket.dayLabel.suffix(2)))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help("\(bucket.dayLabel): \(fullCount(bucket.totalTokens)) tokens, \(bucket.requests) requests")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(bucket.dayLabel), \(bucket.totalTokens) tokens")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let first = buckets.first?.dayLabel, let last = buckets.last?.dayLabel, first != last {
                    Text("\(first) - \(last)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
