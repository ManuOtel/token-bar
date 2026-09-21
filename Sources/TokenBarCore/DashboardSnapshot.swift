import Foundation

/// Per-source totals for the current range, in fixed source order.
///
/// Display-only rollup for the menu-bar source chips. Tokens and request
/// counts only; no sorting, no breakdowns. Computed in one unsorted pass
/// over the records with the same date predicate as `Aggregator.filter`,
/// so chips never pay a per-source filter + sort.
public struct DashboardSourceTotal: Codable, Hashable, Sendable {
    public var filter: SourceFilter
    public var tokens: Int
    public var requests: Int

    public init(filter: SourceFilter, tokens: Int, requests: Int) {
        self.filter = filter
        self.tokens = tokens
        self.requests = requests
    }
}

/// One derived menu-bar snapshot for a (records, source, preset, pricing)
/// scope at one explicit `now`.
///
/// Replaces the repeated per-render work in `TokenBarApp.body`: previously
/// every SwiftUI render ran a separate `Aggregator.filter` (full scan +
/// sort) for the scoped rows, the selected stats, the best-month key, each
/// of the four source chips, plus another filter + reduce with a *second*
/// `Date()` for the menu title. This type computes one explicit `now`,
/// one sorted selected scope, one `aggregate` (which itself reuses one
/// `PricingContext` per PR #16), one unsorted single pass for the four
/// chip totals, one linear pass for the adaptive trend buckets, and one
/// linear pass for the previous-period comparison.
///
/// Pure value type, no caching, no shared state: callers pass a fresh `now`
/// per render, so results can never go stale. Pricing changes are an input
/// (`snapshot`), so a new snapshot trivially recomputes cost basis.
public struct DashboardSnapshot: Hashable, Sendable {
    /// Fixed chip order, mirrors the menu-bar UI.
    public static let sourceOrder: [SourceFilter] = [.all, .codex, .opencode, .claude]

    /// Initial dashboard range for the menu-bar app: rolling last 7 days.
    /// A usage tracker that opens on the narrow calendar-day window reads
    /// as empty most mornings; 7D shows the recent week immediately while
    /// every range chip (including Today) stays available. CLI default
    /// stays lifetime; token/source math is unchanged.
    public static let defaultPreset: DatePreset = .last7Days

    /// One-tap wider range for the empty/source-filter state (`noScopeState`).
    /// Narrow windows (Today/24H/7D) widen to 30D first; 30D and Best widen
    /// to lifetime; lifetime has no wider range (`nil`, source switch only).
    /// Source-agnostic on purpose: no per-source assumptions.
    public static func suggestedWiderPreset(for preset: DatePreset) -> DatePreset? {
        switch preset {
        case .today, .last24Hours, .last7Days:
            return .last30Days
        case .last30Days, .bestMonth:
            return .lifetime
        case .lifetime:
            return nil
        }
    }

    /// Stats for the selected (source, preset) scope. For `.bestMonth`
    /// this is the winning month's stats over the source-filtered lifetime
    /// set, mirroring `ReportFormatter.section` and the old app logic.
    public var stats: AggregatedStats
    /// Row count of the selected scope as the UI counts it: selected-scope
    /// count normally, source-filtered lifetime count for `.bestMonth`
    /// (where `filter` maps `.bestMonth` to lifetime).
    public var scopedCount: Int
    /// Token total behind the menu-bar title. Equals `stats.totalTokens`
    /// except for `.bestMonth`, where the legacy title shows the
    /// source-filtered lifetime total while `stats` shows the winning
    /// month. Preserved byte-for-byte.
    public var menuTotalTokens: Int
    /// Per-source totals for the current preset, in `sourceOrder`.
    public var sourceTotals: [DashboardSourceTotal]
    /// Winning month key, set only for `.bestMonth` with a non-empty scope.
    public var bestMonthKey: String?
    /// Adaptive trend buckets for the selected scope (zero-filled over the
    /// full selected range; see `TrendModel`). Derived from the same
    /// in-memory scope as `stats`, never a second file scan.
    public var trendBuckets: [TrendBucket]
    /// Adaptive chart title naming the active range and grain
    /// ("TODAY BY HOUR", "LAST 7D BY DAY", ...).
    public var trendTitle: String
    /// Bucket grain behind `trendBuckets` (hour, day, or month).
    public var trendGrain: TrendGrain
    /// Previous-period comparison for chronological ranges; nil for
    /// `.bestMonth` and `.lifetime`, which are not one fixed period.
    public var comparison: TrendComparison?

    public init(
        stats: AggregatedStats,
        scopedCount: Int,
        menuTotalTokens: Int,
        sourceTotals: [DashboardSourceTotal],
        bestMonthKey: String? = nil,
        trendBuckets: [TrendBucket] = [],
        trendTitle: String = TrendModel.title(for: .lifetime),
        trendGrain: TrendGrain = .month,
        comparison: TrendComparison? = nil
    ) {
        self.stats = stats
        self.scopedCount = scopedCount
        self.menuTotalTokens = menuTotalTokens
        self.sourceTotals = sourceTotals
        self.bestMonthKey = bestMonthKey
        self.trendBuckets = trendBuckets
        self.trendTitle = trendTitle
        self.trendGrain = trendGrain
        self.comparison = comparison
    }

    /// Builds the full snapshot in: one sorted selected-scope filter, one
    /// aggregate (one `PricingContext`, per PR #16), one unsorted pass for
    /// the four chip totals, one linear pass for the adaptive trend buckets
    /// (index math per record, no per-bucket scan), and one linear pass for
    /// the previous-period comparison. Chip totals, trend, and comparison
    /// need no sorted arrays and read no files: they work over the
    /// in-memory records handed in, so one render costs no extra history
    /// scans. SwiftUI callers compute `make` once per render and pass the
    /// stored trend/comparison down; the chart views do no derivation.
    public static func make(
        records: [NormalizedUsage],
        source: SourceFilter,
        preset: DatePreset,
        now: Date,
        snapshot: CatalogSnapshot? = nil,
        calendar: Calendar = .current
    ) -> DashboardSnapshot {
        let chips = chipTotals(records: records, preset: preset, now: now, calendar: calendar)
        let title = TrendModel.title(for: preset)
        let grain = TrendModel.grain(for: preset)
        if preset == .bestMonth {
            let lifetime = Aggregator.filter(
                records, source: source, preset: .lifetime, now: now, calendar: calendar)
            let menuTotal = lifetime.reduce(0) { $0 + $1.totalTokens }
            guard let best = Aggregator.bestMonth(lifetime, snapshot: snapshot, calendar: calendar) else {
                return DashboardSnapshot(
                    stats: .empty, scopedCount: lifetime.count,
                    menuTotalTokens: menuTotal, sourceTotals: chips, bestMonthKey: nil,
                    trendBuckets: [], trendTitle: title, trendGrain: grain, comparison: nil)
            }
            let monthRecords = lifetime.filter {
                Aggregator.monthKey(for: $0.timestamp, calendar: calendar) == best.monthKey
            }
            return DashboardSnapshot(
                stats: best.stats, scopedCount: lifetime.count,
                menuTotalTokens: menuTotal, sourceTotals: chips, bestMonthKey: best.monthKey,
                trendBuckets: TrendModel.buckets(
                    scoped: monthRecords, preset: preset, now: now,
                    calendar: calendar, bestMonthKey: best.monthKey),
                trendTitle: title, trendGrain: grain, comparison: nil)
        }
        let scoped = Aggregator.filter(
            records, source: source, preset: preset, now: now, calendar: calendar)
        let stats = Aggregator.aggregate(scoped, snapshot: snapshot, calendar: calendar)
        return DashboardSnapshot(
            stats: stats, scopedCount: scoped.count,
            menuTotalTokens: stats.totalTokens, sourceTotals: chips, bestMonthKey: nil,
            trendBuckets: TrendModel.buckets(
                scoped: scoped, preset: preset, now: now, calendar: calendar),
            trendTitle: title, trendGrain: grain,
            comparison: TrendModel.comparison(
                records: records, source: source, preset: preset, now: now, calendar: calendar))
    }

    /// Menu-bar title formatting. Delegates to the shared
    /// `TokenCountFormat.compact` so the menu title, source chips/rows,
    /// composition legends, model bars, and every other compact count share
    /// one unit contract (raw, k, M, B, T with rounding promotion at each boundary).
    public static func menuTitle(forTotal total: Int) -> String {
        TokenCountFormat.compact(total)
    }

    /// Single unsorted pass for the four chip totals. Uses the same date
    /// predicate as `Aggregator.filter` (same bounds, same `now` inclusive
    /// upper bound); source routing uses `SourceFilter.matches`.
    static func chipTotals(
        records: [NormalizedUsage],
        preset: DatePreset,
        now: Date,
        calendar: Calendar
    ) -> [DashboardSourceTotal] {
        var codexTokens = 0, codexCount = 0
        var openTokens = 0, openCount = 0
        var claudeTokens = 0, claudeCount = 0
        var allTokens = 0, allCount = 0
        for record in records {
            guard dateMatches(record.timestamp, preset: preset, now: now, calendar: calendar) else { continue }
            allTokens += record.totalTokens
            allCount += 1
            switch record.source {
            case .codex:
                codexTokens += record.totalTokens
                codexCount += 1
            case .opencode:
                openTokens += record.totalTokens
                openCount += 1
            case .claude:
                claudeTokens += record.totalTokens
                claudeCount += 1
            }
        }
        return [
            DashboardSourceTotal(filter: .all, tokens: allTokens, requests: allCount),
            DashboardSourceTotal(filter: .codex, tokens: codexTokens, requests: codexCount),
            DashboardSourceTotal(filter: .opencode, tokens: openTokens, requests: openCount),
            DashboardSourceTotal(filter: .claude, tokens: claudeTokens, requests: claudeCount),
        ]
    }

    /// Date half of `Aggregator.filter`, without source filtering or
    /// sorting. Bounds mirror `filter` exactly: `.lifetime`/`.bestMonth`
    /// match everything; the rest require `start <= ts <= now`.
    static func dateMatches(
        _ timestamp: Date,
        preset: DatePreset,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch preset {
        case .lifetime, .bestMonth:
            return true
        case .today:
            let start = calendar.startOfDay(for: now)
            return timestamp >= start && timestamp <= now
        case .last24Hours:
            let start = now.addingTimeInterval(-24 * 3600)
            return timestamp >= start && timestamp <= now
        case .last7Days:
            let start = now.addingTimeInterval(-7 * 24 * 3600)
            return timestamp >= start && timestamp <= now
        case .last30Days:
            let start = now.addingTimeInterval(-30 * 24 * 3600)
            return timestamp >= start && timestamp <= now
        }
    }
}
