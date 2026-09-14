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
/// `PricingContext` per PR #16), and one unsorted single pass for the four
/// chip totals.
///
/// Pure value type, no caching, no shared state: callers pass a fresh `now`
/// per render, so results can never go stale. Pricing changes are an input
/// (`snapshot`), so a new snapshot trivially recomputes cost basis.
public struct DashboardSnapshot: Hashable, Sendable {
    /// Fixed chip order, mirrors the menu-bar UI.
    public static let sourceOrder: [SourceFilter] = [.all, .codex, .opencode, .claude]

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

    public init(
        stats: AggregatedStats,
        scopedCount: Int,
        menuTotalTokens: Int,
        sourceTotals: [DashboardSourceTotal],
        bestMonthKey: String? = nil
    ) {
        self.stats = stats
        self.scopedCount = scopedCount
        self.menuTotalTokens = menuTotalTokens
        self.sourceTotals = sourceTotals
        self.bestMonthKey = bestMonthKey
    }

    /// Builds the full snapshot in: one sorted selected-scope filter, one
    /// aggregate (one `PricingContext`, per PR #16), and one unsorted pass
    /// for the four chip totals. Chip totals need no sorted arrays.
    public static func make(
        records: [NormalizedUsage],
        source: SourceFilter,
        preset: DatePreset,
        now: Date,
        snapshot: CatalogSnapshot? = nil,
        calendar: Calendar = .current
    ) -> DashboardSnapshot {
        let chips = chipTotals(records: records, preset: preset, now: now, calendar: calendar)
        if preset == .bestMonth {
            let lifetime = Aggregator.filter(
                records, source: source, preset: .lifetime, now: now, calendar: calendar)
            let menuTotal = lifetime.reduce(0) { $0 + $1.totalTokens }
            guard let best = Aggregator.bestMonth(lifetime, snapshot: snapshot, calendar: calendar) else {
                return DashboardSnapshot(
                    stats: .empty, scopedCount: lifetime.count,
                    menuTotalTokens: menuTotal, sourceTotals: chips, bestMonthKey: nil)
            }
            return DashboardSnapshot(
                stats: best.stats, scopedCount: lifetime.count,
                menuTotalTokens: menuTotal, sourceTotals: chips, bestMonthKey: best.monthKey)
        }
        let scoped = Aggregator.filter(
            records, source: source, preset: preset, now: now, calendar: calendar)
        let stats = Aggregator.aggregate(scoped, snapshot: snapshot, calendar: calendar)
        return DashboardSnapshot(
            stats: stats, scopedCount: scoped.count,
            menuTotalTokens: stats.totalTokens, sourceTotals: chips, bestMonthKey: nil)
    }

    /// Menu-bar title formatting, extracted unchanged from `TokenBarApp`:
    /// `%.2fM` over 1M, `%.1fk` over 1k, else the raw count.
    public static func menuTitle(forTotal total: Int) -> String {
        if total >= 1_000_000 {
            return String(format: "%.2fM", Double(total) / 1_000_000.0)
        } else if total >= 1_000 {
            return String(format: "%.1fk", Double(total) / 1_000.0)
        }
        return "\(total)"
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
