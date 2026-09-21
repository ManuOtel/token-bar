import Foundation

/// Persisted trend chart style preference (M12, see
/// `docs/CHART_STYLE_PROPOSAL.md`).
///
/// Pure view-layer selection over the stored `DashboardSnapshot` trend
/// fields (`trendBuckets`, `trendGrain`, `trendTitle`, `comparison`).
/// Style never re-derives buckets, never stacks sources, never splits
/// input vs output: every style renders the same single total-token series
/// with the same zero-filled coverage, so bucket-token sums equal the hero
/// total in every style. No file access, no network, no subprocess; the
/// only write is the single user-default string below.
public enum ChartStyle: String, Hashable, Sendable, CaseIterable {
    case automatic
    case bars
    case line
    case area

    /// Single user-default key backing the preference (read through
    /// `AppStorage` in `DashboardView`, applied at launch before first
    /// render). One string read per launch plus one write per user change.
    public static let storageKey = "chartStyle"

    /// Default when unset, and the explicit Reset target. Reset is never a
    /// silent migration: only an explicit user action (or defaults delete)
    /// returns to Automatic.
    public static let defaultStyle = ChartStyle.automatic

    /// Safe fallback for the persisted value: a missing or unknown string
    /// reads as Automatic, never a fabricated style.
    public init(storedRawValue: String?) {
        guard let raw = storedRawValue, let style = ChartStyle(rawValue: raw) else {
            self = .automatic
            return
        }
        self = style
    }

    /// Short menu label for the Details style picker.
    public var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .bars:
            return "Bars"
        case .line:
            return "Line with points"
        case .area:
            return "Area"
        }
    }

    /// Renderer chosen for one snapshot. Explicit picks render the
    /// requested marks for the same stored buckets; Automatic maps from
    /// the active range and grain (section 4 of the proposal):
    ///
    /// - Today / Last 24H by hour: Bars (discrete hourly comparisons with
    ///   frequent zeros).
    /// - Last 7D by day: Bars (seven to eight daily buckets fit the 400pt
    ///   width as bars).
    /// - Last 30D by day: one documented sparsity rule. Bars when at least
    ///   half the daily buckets are zero (sparse), Line with points when
    ///   dense. `zeroShare >= 0.5` reads as Bars.
    /// - Best month by day: Bars (single-day spikes read as comparisons
    ///   first, shape second).
    /// - All time by month: Line with points (long, often sparse-tailed
    ///   lifetime series keep continuity while points keep single-record
    ///   months visible).
    ///
    /// Automatic never resolves to Area: area is a manual pick for the
    /// total-volume shape only. An empty bucket list resolves to Bars; the
    /// views render the empty copy with no chart frame regardless of style.
    /// Constant time over the stored buckets (count plus zero-bucket
    /// share): no sorting, no re-aggregation.
    public func resolved(for preset: DatePreset, buckets: [TrendBucket]) -> ResolvedTrendStyle {
        switch self {
        case .bars:
            return .bars
        case .line:
            return .linePoints
        case .area:
            return .area
        case .automatic:
            switch preset {
            case .today, .last24Hours, .last7Days, .bestMonth:
                return .bars
            case .last30Days:
                guard !buckets.isEmpty else { return .bars }
                let zeroCount = buckets.filter { $0.totalTokens <= 0 }.count
                let zeroShare = Double(zeroCount) / Double(buckets.count)
                return zeroShare >= 0.5 ? .bars : .linePoints
            case .lifetime:
                return .linePoints
            }
        }
    }
}

/// Concrete renderer behind a `ChartStyle` selection. Automatic is gone by
/// this point: see `ChartStyle.resolved(for:buckets:)`.
public enum ResolvedTrendStyle: String, Hashable, Sendable {
    case bars
    case linePoints
    case area

    /// Short label used in accessibility summaries and the grain caption.
    public var displayName: String {
        switch self {
        case .bars:
            return "bars"
        case .linePoints:
            return "line with points"
        case .area:
            return "area"
        }
    }
}
