import Foundation

/// Chart-ready shares derived from `AggregatedStats`.
///
/// Display-only helpers for the menu-bar dashboard. No pricing, no file
/// access, no filtering semantics. Cached and reasoning tokens are subsets
/// (cached of input, reasoning of output) and are exposed as such so ring
/// and bar visuals never imply double-counting: the composition ring splits
/// the total into input vs output only, while subset shares read as
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
