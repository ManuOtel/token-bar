import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Chart-ready shares derived from `AggregatedStats`.
///
/// Display-only helpers for the menu-bar dashboard. No pricing, no file
/// access, no filtering semantics. Cached and reasoning tokens are subsets
/// (cached of input, reasoning of output) and are exposed as such so
/// composition visuals never imply double-counting: the expanded ring
/// splits the total into input vs output only, while subset shares read as
/// "X% of input/output".
public struct TokenComposition: Hashable, Sendable {
    public var inputShare: Double
    public var outputShare: Double
    /// Cached as a fraction of input (0 when input is 0).
    public var cachedShareOfInput: Double
    /// Reasoning as a fraction of output (0 when output is 0).
    public var reasoningShareOfOutput: Double

    public init(inputShare: Double, outputShare: Double, cachedShareOfInput: Double, reasoningShareOfOutput: Double) {
        self.inputShare = inputShare
        self.outputShare = outputShare
        self.cachedShareOfInput = cachedShareOfInput
        self.reasoningShareOfOutput = reasoningShareOfOutput
    }
}

/// Compact input/output comparison geometry for the dashboard.
///
/// A linear donut goes blind when one side dominates (for example 7.2B
/// input vs 19.6M output renders the output arc as ~0.3% of the ring, i.e.
/// invisible). This pairs exact linear shares (for counts and percents)
/// with log-scaled bar widths (for visibility): `inputShare`/`outputShare`
/// stay proportional to the total and carry the truth, while
/// `inputDisplay`/`outputDisplay` map `log(1 + value)` onto 0...1 so the
/// smaller side stays discoverable. A `visibleMinimum` floor keeps
/// extremely skewed nonzero values (where even the log width would be a
/// hairline) tappable/visible; zeros never lift off zero. Callers must
/// label the bars as log-scaled so the widths are never read as shares.
public struct IOComparison: Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Exact linear fractions of the authoritative total (match
    /// `composition(for:)`; 0 when the scope is empty).
    public var inputShare: Double
    public var outputShare: Double
    /// Log-scaled bar widths, 0...1. The larger side is always 1; a zero
    /// side is always 0.
    public var inputDisplay: Double
    public var outputDisplay: Double
    /// True when the floor lifted a nonzero smaller side to visibility.
    public var smallerIsFloored: Bool
    /// True when both sides are zero (no input/output split to show).
    public var isEmpty: Bool

    public init(
        inputTokens: Int, outputTokens: Int,
        inputShare: Double, outputShare: Double,
        inputDisplay: Double, outputDisplay: Double,
        smallerIsFloored: Bool, isEmpty: Bool
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.inputShare = inputShare
        self.outputShare = outputShare
        self.inputDisplay = inputDisplay
        self.outputDisplay = outputDisplay
        self.smallerIsFloored = smallerIsFloored
        self.isEmpty = isEmpty
    }
}

/// One normalized slice for stacked-bar / legend visuals.
public struct ChartShare: Hashable, Sendable {
    public var key: String
    public var totalTokens: Int
    public var requests: Int
    /// Fraction of the scope total, 0...1. Zero when the scope is empty.
    public var share: Double

    public init(key: String, totalTokens: Int, requests: Int, share: Double) {
        self.key = key
        self.totalTokens = totalTokens
        self.requests = requests
        self.share = share
    }
}

public enum DashboardInsights {
    /// Input vs output split of the token total plus subset ratios.
    ///
    /// `totalTokens` is authoritative; when it is zero (empty scope) all
    /// shares are zero so charts render an empty state instead of NaN.
    public static func composition(for stats: AggregatedStats) -> TokenComposition {
        guard stats.totalTokens > 0 else {
            return TokenComposition(inputShare: 0, outputShare: 0, cachedShareOfInput: 0, reasoningShareOfOutput: 0)
        }
        let total = Double(stats.totalTokens)
        let inputShare = min(max(Double(stats.inputTokens) / total, 0), 1)
        let outputShare = min(max(Double(stats.outputTokens) / total, 0), 1)
        let cachedShare: Double = stats.inputTokens > 0
            ? min(max(Double(stats.cachedTokens) / Double(stats.inputTokens), 0), 1)
            : 0
        let reasoningShare: Double = stats.outputTokens > 0
            ? min(max(Double(stats.reasoningTokens) / Double(stats.outputTokens), 0), 1)
            : 0
        return TokenComposition(
            inputShare: inputShare,
            outputShare: outputShare,
            cachedShareOfInput: cachedShare,
            reasoningShareOfOutput: reasoningShare
        )
    }

    /// Normalized shares for one breakdown list (source or model).
    /// Order is preserved (callers pass the already-sorted `bySource` /
    /// `byModel` arrays). Empty scope yields zero shares.
    public static func shares(for entries: [BreakdownEntry], totalTokens: Int) -> [ChartShare] {
        guard totalTokens > 0 else {
            return entries.map { ChartShare(key: $0.key, totalTokens: $0.totalTokens, requests: $0.requests, share: 0) }
        }
        let total = Double(totalTokens)
        return entries.map { entry in
            ChartShare(
                key: entry.key,
                totalTokens: entry.totalTokens,
                requests: entry.requests,
                share: min(max(Double(entry.totalTokens) / total, 0), 1)
            )
        }
    }

    /// Top models capped at `limit`, preserving `byModel` order.
    public static func topModels(in stats: AggregatedStats, limit: Int = 5) -> [BreakdownEntry] {
        guard limit > 0 else { return [] }
        return Array(stats.byModel.prefix(limit))
    }

    /// Paired input/output comparison for the compact dashboard.
    ///
    /// Linear shares come from `composition(for:)` (same source of truth as
    /// the expanded ring). Display widths use `log(1 + value)` normalized
    /// against the larger side, then clamped to `visibleMinimum` for nonzero
    /// values. Ordering is preserved (larger input renders a longer bar);
    /// zero sides render zero width and never trigger the floor.
    public static func ioComparison(for stats: AggregatedStats, visibleMinimum: Double = 0.06) -> IOComparison {
        let comp = composition(for: stats)
        let input = max(0, stats.inputTokens)
        let output = max(0, stats.outputTokens)
        let peak = max(input, output)
        guard peak > 0 else {
            return IOComparison(
                inputTokens: input, outputTokens: output,
                inputShare: 0, outputShare: 0,
                inputDisplay: 0, outputDisplay: 0,
                smallerIsFloored: false, isEmpty: true
            )
        }
        let floor = min(max(visibleMinimum, 0), 1)
        let denom = log(Double(peak) + 1)
        func display(_ value: Int) -> Double {
            guard value > 0 else { return 0 }
            guard denom > 0 else { return 0 }
            return min(max(log(Double(value) + 1) / denom, 0), 1)
        }
        var inputDisplay = display(input)
        var outputDisplay = display(output)
        var floored = false
        if input > 0, inputDisplay < floor {
            inputDisplay = floor
            floored = true
        }
        if output > 0, outputDisplay < floor {
            outputDisplay = floor
            floored = true
        }
        return IOComparison(
            inputTokens: input, outputTokens: output,
            inputShare: comp.inputShare, outputShare: comp.outputShare,
            inputDisplay: inputDisplay, outputDisplay: outputDisplay,
            smallerIsFloored: floored, isEmpty: false
        )
    }

    /// Per-bucket heights as 0...1 fractions of the peak bucket.
    /// Empty input yields an empty array. A uniform floor keeps zero-token
    /// buckets visible as a hairline when `visibleMinimum` > 0.
    public static func trendFractions(for buckets: [DailyBucket], visibleMinimum: Double = 0.04) -> [Double] {
        guard !buckets.isEmpty else { return [] }
        let peak = buckets.map(\.totalTokens).max() ?? 0
        guard peak > 0 else { return buckets.map { _ in 0 } }
        let floor = min(max(visibleMinimum, 0), 1)
        return buckets.map { bucket in
            if bucket.totalTokens <= 0 { return 0 }
            let raw = Double(bucket.totalTokens) / Double(peak)
            return min(max(raw, floor), 1)
        }
    }
}
