import Foundation
import XCTest
@testable import TokenBarCore

/// Adaptive trend (M9): per-range grain, full zero-filled coverage, local
/// calendar behavior, rolling 24H buckets, previous-period comparison,
/// source filtering, and lifetime monthly aggregation.
///
/// All fixtures are synthetic; no file access, no network.
final class TrendModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_789_041_600) // 2026-09-10T12:00:00Z
    }

    private func record(
        _ id: String, source: UsageSource = .codex, at date: Date,
        model: String = "gpt-5-mini", input: Int = 100, output: Int = 50,
        cached: Int = 0, reasoning: Int = 0
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: source, timestamp: date,
            model: model, inputTokens: input, outputTokens: output,
            cachedTokens: cached, reasoningTokens: reasoning,
            totalTokens: 0, sessionId: id, requestId: id)
    }

    private func hoursAgo(_ hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 24 * 3600)
    }

    // MARK: - Grain and titles

    func testGrainAndTitlePerPreset() {
        XCTAssertEqual(TrendModel.grain(for: .today), .hour)
        XCTAssertEqual(TrendModel.grain(for: .last24Hours), .hour)
        XCTAssertEqual(TrendModel.grain(for: .last7Days), .day)
        XCTAssertEqual(TrendModel.grain(for: .last30Days), .day)
        XCTAssertEqual(TrendModel.grain(for: .bestMonth), .day)
        XCTAssertEqual(TrendModel.grain(for: .lifetime), .month)
        XCTAssertEqual(TrendModel.title(for: .today), "TODAY BY HOUR")
        XCTAssertEqual(TrendModel.title(for: .last24Hours), "LAST 24H BY HOUR")
        XCTAssertEqual(TrendModel.title(for: .last7Days), "LAST 7D BY DAY")
        XCTAssertEqual(TrendModel.title(for: .last30Days), "LAST 30D BY DAY")
        XCTAssertEqual(TrendModel.title(for: .bestMonth), "BEST MONTH BY DAY")
        XCTAssertEqual(TrendModel.title(for: .lifetime), "ALL TIME BY MONTH")
    }

    // MARK: - Today hourly coverage

    func testTodayHasHourlyCoverageIncludingEmptyHours() {
        // One record at 09:xx; every hour 00..12 still gets a bucket.
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 30
        let morning = calendar.date(from: components)!
        let scoped = Aggregator.filter(
            [record("a", at: morning)], source: .all, preset: .today,
            now: now, calendar: calendar)
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .today, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 13) // hours 00 through 12
        XCTAssertEqual(buckets.map(\.label).first, "00")
        XCTAssertEqual(buckets.map(\.label).last, "12")
        // Full zero-filled coverage: only hour 09 carries tokens.
        XCTAssertEqual(buckets.filter { $0.requests == 0 }.count, 12)
        XCTAssertEqual(buckets[9].totalTokens, 150)
        XCTAssertEqual(buckets[9].requests, 1)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 150)
        // Stable ascending starts, one hour apart.
        for offset in 1..<buckets.count {
            XCTAssertEqual(
                buckets[offset].start.timeIntervalSince(buckets[offset - 1].start),
                3600, accuracy: 1)
        }
    }

    func testTodayEmptyScopeStillCoversEveryHour() {
        let buckets = TrendModel.buckets(
            scoped: [], preset: .today, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 13)
        XCTAssertTrue(buckets.allSatisfy { $0.totalTokens == 0 && $0.requests == 0 })
    }

    // MARK: - Rolling 24H hourly buckets

    func testLast24HoursHas24HourlyBuckets() {
        let scoped = Aggregator.filter(
            [record("a", at: hoursAgo(1)), record("b", at: hoursAgo(23))],
            source: .all, preset: .last24Hours, now: now, calendar: calendar)
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .last24Hours, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 300)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.requests }, 2)
        // Half-open rolling hourly buckets: bucket 0 is [now-24h, now-23h),
        // so the 23h-ago record belongs to bucket 1 and the 1h-ago record
        // belongs to bucket 23.
        XCTAssertEqual(buckets[1].requests, 1)
        XCTAssertEqual(buckets[23].requests, 1)
        XCTAssertEqual(buckets[0].requests, 0)
        XCTAssertEqual(buckets[2..<23].reduce(0) { $0 + $1.requests }, 0)
    }

    func testLast24HoursBoundaryRecordCountsOnce() {
        // A record at exactly now-24h is inside the rolling predicate, so it
        // must land in bucket 0 (never dropped, never doubled).
        let edge = record("edge", at: hoursAgo(24))
        let scoped = Aggregator.filter(
            [edge], source: .all, preset: .last24Hours, now: now, calendar: calendar)
        XCTAssertEqual(scoped.count, 1)
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .last24Hours, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[0].requests, 1)
        XCTAssertEqual(buckets[1...].reduce(0) { $0 + $1.requests }, 0)
    }

    func testLast24HoursEmptyScopeHas24ZeroBuckets() {
        let buckets = TrendModel.buckets(
            scoped: [], preset: .last24Hours, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertTrue(buckets.allSatisfy { $0.totalTokens == 0 && $0.requests == 0 })
    }

    // MARK: - Daily coverage for 7D / 30D

    func testLast7DaysHasFullDailyCoverage() {
        // now = Sep 10 12:00Z; window start = Sep 3 12:00Z, so calendar days
        // Sep 3 through Sep 10 are covered (8 buckets, first partial).
        let scoped = Aggregator.filter(
            [record("a", at: daysAgo(1)), record("b", at: daysAgo(6))],
            source: .all, preset: .last7Days, now: now, calendar: calendar)
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .last7Days, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 8)
        XCTAssertEqual(buckets.first?.label, "2026-09-03")
        XCTAssertEqual(buckets.last?.label, "2026-09-10")
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 300)
        XCTAssertEqual(buckets.filter { $0.requests == 0 }.count, 6)
    }

    func testLast30DaysHasFullDailyCoverage() {
        let scoped = Aggregator.filter(
            [record("a", at: daysAgo(1))],
            source: .all, preset: .last30Days, now: now, calendar: calendar)
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .last30Days, now: now, calendar: calendar)
        // Aug 11 through Sep 10 inclusive.
        XCTAssertEqual(buckets.count, 31)
        XCTAssertEqual(buckets.first?.label, "2026-08-11")
        XCTAssertEqual(buckets.last?.label, "2026-09-10")
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 150)
        XCTAssertEqual(buckets.filter { $0.requests == 0 }.count, 30)
    }

    // MARK: - Local calendar behavior

    func testDailyBucketsRespectLocalCalendarTimeZone() {
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-09-10T02:00:00Z is Sep 9 22:00 in New York.
        let ts = ISO8601DateFormatter().date(from: "2026-09-10T02:00:00Z")!
        let scoped = Aggregator.filter(
            [record("t", at: ts)], source: .all, preset: .last7Days,
            now: now, calendar: nyCalendar)
        XCTAssertEqual(scoped.count, 1)
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .last7Days, now: now, calendar: nyCalendar)
        let hit = buckets.first { $0.requests > 0 }
        XCTAssertEqual(hit?.label, "2026-09-09")
    }

    func testTodayHourlyPlacementAcrossSpringForward() {
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 skips 02:00 in New York (spring forward). A 10:30
        // record is only 9.5 elapsed hours after midnight, but its local
        // hour is 10 and must land in bucket 10.
        var nowComponents = DateComponents()
        nowComponents.year = 2026
        nowComponents.month = 3
        nowComponents.day = 8
        nowComponents.hour = 12
        nowComponents.minute = 0
        let dstNow = nyCalendar.date(from: nowComponents)!
        var recordComponents = DateComponents()
        recordComponents.year = 2026
        recordComponents.month = 3
        recordComponents.day = 8
        recordComponents.hour = 10
        recordComponents.minute = 30
        let dstDate = nyCalendar.date(from: recordComponents)!
        XCTAssertEqual(nyCalendar.component(.hour, from: dstDate), 10)
        let scoped = Aggregator.filter(
            [record("dst", at: dstDate)], source: .all, preset: .today,
            now: dstNow, calendar: nyCalendar)
        XCTAssertEqual(scoped.count, 1)
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .today, now: dstNow, calendar: nyCalendar)
        XCTAssertEqual(buckets.count, 13) // local hours 00 through 12
        XCTAssertEqual(buckets[10].requests, 1)
        XCTAssertEqual(buckets[10].totalTokens, 150)
        XCTAssertEqual(buckets[10].label, "10")
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 150)
    }

    // MARK: - Best month daily buckets

    func testBestMonthHasDailyBucketsForWinningMonth() {
        let formatter = ISO8601DateFormatter()
        func dated(_ id: String, _ iso: String, total: Int) -> NormalizedUsage {
            record(id, at: formatter.date(from: iso)!, input: total, output: 0)
        }
        let records = [
            dated("aug", "2026-08-05T10:00:00Z", total: 1000),
            dated("sep", "2026-09-05T10:00:00Z", total: 5000),
        ]
        let lifetime = Aggregator.filter(
            records, source: .all, preset: .lifetime, now: now, calendar: calendar)
        let best = Aggregator.bestMonth(lifetime, calendar: calendar)!
        XCTAssertEqual(best.monthKey, "2026-09")
        let monthRecords = lifetime.filter {
            Aggregator.monthKey(for: $0.timestamp, calendar: calendar) == best.monthKey
        }
        let buckets = TrendModel.buckets(
            scoped: monthRecords, preset: .bestMonth, now: now,
            calendar: calendar, bestMonthKey: best.monthKey)
        // September 2026 has 30 days, all covered including empty ones.
        XCTAssertEqual(buckets.count, 30)
        XCTAssertEqual(buckets.first?.label, "2026-09-01")
        XCTAssertEqual(buckets.last?.label, "2026-09-30")
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 5000)
        XCTAssertEqual(buckets.filter { $0.requests == 0 }.count, 29)
    }

    func testBestMonthWithoutKeyHasNoBuckets() {
        XCTAssertTrue(TrendModel.buckets(
            scoped: [], preset: .bestMonth, now: now,
            calendar: calendar, bestMonthKey: nil).isEmpty)
    }

    // MARK: - Lifetime monthly aggregation

    func testLifetimeAggregatesByMonth() {
        let formatter = ISO8601DateFormatter()
        func dated(_ id: String, _ iso: String, total: Int) -> NormalizedUsage {
            record(id, at: formatter.date(from: iso)!, input: total, output: 0)
        }
        let scoped = [
            dated("jul", "2026-07-15T10:00:00Z", total: 100),
            dated("aug", "2026-08-05T10:00:00Z", total: 200),
            dated("sep", "2026-09-05T10:00:00Z", total: 300),
        ]
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(buckets.map(\.label), ["2026-07", "2026-08", "2026-09"])
        XCTAssertEqual(buckets.map(\.totalTokens), [100, 200, 300])
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 600)
    }

    func testLifetimeIncludesEmptyMonths() {
        let formatter = ISO8601DateFormatter()
        let scoped = [
            record("jul", at: formatter.date(from: "2026-07-15T10:00:00Z")!, input: 100, output: 0),
            record("sep", at: formatter.date(from: "2026-09-05T10:00:00Z")!, input: 300, output: 0),
        ]
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(buckets.map(\.label), ["2026-07", "2026-08", "2026-09"])
        XCTAssertEqual(buckets[1].totalTokens, 0)
        XCTAssertEqual(buckets[1].requests, 0)
    }

    func testLifetimeEmptyScopeHasNoBuckets() {
        XCTAssertTrue(TrendModel.buckets(
            scoped: [], preset: .lifetime, now: now, calendar: calendar).isEmpty)
    }

    // MARK: - Token totals never add subsets

    func testBucketTotalsNeverAddCachedOrReasoning() {
        let rec = record(
            "a", at: hoursAgo(1), input: 1000, output: 500,
            cached: 1000, reasoning: 500)
        XCTAssertEqual(rec.totalTokens, 1500)
        let scoped = Aggregator.filter(
            [rec], source: .all, preset: .last24Hours, now: now, calendar: calendar)
        let buckets = TrendModel.buckets(
            scoped: scoped, preset: .last24Hours, now: now, calendar: calendar)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.totalTokens }, 1500)
    }

    // MARK: - Source filtering

    func testBucketsRespectSourceFilter() {
        let records = [
            record("codex", source: .codex, at: hoursAgo(1), input: 100, output: 0),
            record("open", source: .opencode, at: hoursAgo(1), input: 200, output: 0),
        ]
        let codexScoped = Aggregator.filter(
            records, source: .codex, preset: .today, now: now, calendar: calendar)
        let codexBuckets = TrendModel.buckets(
            scoped: codexScoped, preset: .today, now: now, calendar: calendar)
        XCTAssertEqual(codexBuckets.reduce(0) { $0 + $1.totalTokens }, 100)
        let allScoped = Aggregator.filter(
            records, source: .all, preset: .today, now: now, calendar: calendar)
        let allBuckets = TrendModel.buckets(
            scoped: allScoped, preset: .today, now: now, calendar: calendar)
        XCTAssertEqual(allBuckets.reduce(0) { $0 + $1.totalTokens }, 300)
    }

    // MARK: - Comparison deltas

    func testTodayComparisonAgainstYesterday() {
        let records = [
            record("now", at: hoursAgo(1), input: 100, output: 50), // 150 today
            record("prev", at: hoursAgo(24 + 1), input: 60, output: 40), // 100 yesterday
        ]
        let comparison = TrendModel.comparison(
            records: records, source: .all, preset: .today,
            now: now, calendar: calendar)!
        XCTAssertTrue(comparison.hasBaseline)
        XCTAssertEqual(comparison.currentTotalTokens, 150)
        XCTAssertEqual(comparison.previousTotalTokens, 100)
        XCTAssertEqual(comparison.direction, .up)
        XCTAssertEqual(comparison.percentChange ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(comparison.previousLabel, "yesterday")
    }

    func testComparisonDecrease() {
        let records = [
            record("now", at: hoursAgo(1), input: 60, output: 40), // 100
            record("prev", at: daysAgo(8), input: 100, output: 100), // 200 in prev 7d
        ]
        let comparison = TrendModel.comparison(
            records: records, source: .all, preset: .last7Days,
            now: now, calendar: calendar)!
        XCTAssertTrue(comparison.hasBaseline)
        XCTAssertEqual(comparison.direction, .down)
        XCTAssertEqual(comparison.percentChange ?? 0, -50, accuracy: 1e-9)
        XCTAssertEqual(comparison.previousLabel, "previous 7 days")
    }

    func testComparisonFlatWhenTotalsMatch() {
        let records = [
            record("now", at: hoursAgo(1), input: 100, output: 0),
            record("prev", at: hoursAgo(30), input: 100, output: 0),
        ]
        let comparison = TrendModel.comparison(
            records: records, source: .all, preset: .last24Hours,
            now: now, calendar: calendar)!
        XCTAssertTrue(comparison.hasBaseline)
        XCTAssertEqual(comparison.direction, .flat)
        XCTAssertEqual(comparison.percentChange ?? 99, 0, accuracy: 1e-9)
        XCTAssertEqual(comparison.previousLabel, "previous 24 hours")
    }

    func testComparisonHasNoBaselineWhenPreviousWindowEmpty() {
        let records = [record("now", at: hoursAgo(1), input: 100, output: 50)]
        let comparison = TrendModel.comparison(
            records: records, source: .all, preset: .last30Days,
            now: now, calendar: calendar)!
        // Never a fabricated 0 percent: no baseline, no direction, no delta.
        XCTAssertFalse(comparison.hasBaseline)
        XCTAssertNil(comparison.direction)
        XCTAssertNil(comparison.percentChange)
        XCTAssertEqual(comparison.currentTotalTokens, 150)
        XCTAssertEqual(comparison.previousTotalTokens, 0)
        XCTAssertEqual(comparison.previousLabel, "previous 30 days")
    }

    func testComparisonWindowsShareOnlyTheBoundary() {
        // A record at exactly now-24h belongs to the current 24H window
        // (inclusive bound), not the previous one (exclusive upper bound).
        let records = [record("edge", at: hoursAgo(24), input: 100, output: 0)]
        let comparison = TrendModel.comparison(
            records: records, source: .all, preset: .last24Hours,
            now: now, calendar: calendar)!
        XCTAssertEqual(comparison.currentTotalTokens, 100)
        XCTAssertFalse(comparison.hasBaseline)
    }

    func testComparisonAppliesSourceFilter() {
        let records = [
            record("codex-now", source: .codex, at: hoursAgo(1), input: 100, output: 50),
            record("open-prev", source: .opencode, at: daysAgo(1), input: 500, output: 500),
        ]
        let codex = TrendModel.comparison(
            records: records, source: .codex, preset: .today,
            now: now, calendar: calendar)!
        // The OpenCode previous-day record is filtered out: no baseline for
        // the Codex scope, and the current total is Codex-only.
        XCTAssertEqual(codex.currentTotalTokens, 150)
        XCTAssertFalse(codex.hasBaseline)
        let all = TrendModel.comparison(
            records: records, source: .all, preset: .today,
            now: now, calendar: calendar)!
        XCTAssertTrue(all.hasBaseline)
        XCTAssertEqual(all.previousTotalTokens, 1000)
    }

    func testComparisonNilForBestMonthAndLifetime() {
        let records = [record("a", at: hoursAgo(1))]
        XCTAssertNil(TrendModel.comparison(
            records: records, source: .all, preset: .bestMonth,
            now: now, calendar: calendar))
        XCTAssertNil(TrendModel.comparison(
            records: records, source: .all, preset: .lifetime,
            now: now, calendar: calendar))
        XCTAssertNil(TrendModel.previousLabel(for: .bestMonth))
        XCTAssertNil(TrendModel.previousLabel(for: .lifetime))
    }

    // MARK: - Snapshot threading

    func testSnapshotThreadsAdaptiveTrendPerPreset() {
        let records = [
            record("codex-recent", source: .codex, at: hoursAgo(1), input: 1000, output: 500),
            record("open-recent", source: .opencode, at: daysAgo(2), input: 2000, output: 1000),
            record("claude-old", source: .claude, at: daysAgo(45), input: 300, output: 200),
        ]
        let expectedTitles: [DatePreset: String] = [
            .today: "TODAY BY HOUR",
            .last24Hours: "LAST 24H BY HOUR",
            .last7Days: "LAST 7D BY DAY",
            .last30Days: "LAST 30D BY DAY",
            .lifetime: "ALL TIME BY MONTH",
        ]
        for (preset, title) in expectedTitles {
            let dash = DashboardSnapshot.make(
                records: records, source: .all, preset: preset,
                now: now, snapshot: nil, calendar: calendar)
            XCTAssertEqual(dash.trendTitle, title, "\(preset)")
            XCTAssertEqual(dash.trendGrain, TrendModel.grain(for: preset), "\(preset)")
            // Bucket tokens reconcile with the hero total; no file rescan.
            XCTAssertEqual(
                dash.trendBuckets.reduce(0) { $0 + $1.totalTokens },
                dash.stats.totalTokens, "\(preset)")
            if preset == .lifetime {
                XCTAssertNil(dash.comparison, "\(preset)")
            } else {
                // Comparison current total keeps the exact hero total.
                XCTAssertEqual(dash.comparison?.currentTotalTokens, dash.stats.totalTokens, "\(preset)")
            }
        }
        // Full coverage per grain: Today has hourly buckets through hour 12,
        // 24H has exactly 24, lifetime spans Jul-Sep monthly.
        let today = DashboardSnapshot.make(
            records: records, source: .all, preset: .today,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(today.trendBuckets.count, 13)
        let day = DashboardSnapshot.make(
            records: records, source: .all, preset: .last24Hours,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(day.trendBuckets.count, 24)
        let life = DashboardSnapshot.make(
            records: records, source: .all, preset: .lifetime,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(life.trendBuckets.map(\.label), ["2026-07", "2026-08", "2026-09"])
    }

    func testSnapshotBestMonthTrendIsDailyWithNoComparison() {
        let formatter = ISO8601DateFormatter()
        func dated(_ id: String, _ iso: String, total: Int) -> NormalizedUsage {
            record(id, at: formatter.date(from: iso)!, input: total, output: 0)
        }
        let records = [
            dated("aug", "2026-08-05T10:00:00Z", total: 1000),
            dated("sep", "2026-09-05T10:00:00Z", total: 5000),
        ]
        let dash = DashboardSnapshot.make(
            records: records, source: .all, preset: .bestMonth,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(dash.trendTitle, "BEST MONTH BY DAY")
        XCTAssertEqual(dash.trendGrain, .day)
        XCTAssertEqual(dash.trendBuckets.count, 30)
        XCTAssertEqual(
            dash.trendBuckets.reduce(0) { $0 + $1.totalTokens }, dash.stats.totalTokens)
        XCTAssertNil(dash.comparison)
    }

    // MARK: - Trend fractions over the new buckets

    func testTrendFractionsSupportTrendBuckets() {
        let start = calendar.startOfDay(for: now)
        let buckets = [
            TrendBucket(start: start, label: "00", totalTokens: 0, requests: 0),
            TrendBucket(start: start, label: "01", totalTokens: 50, requests: 1),
            TrendBucket(start: start, label: "02", totalTokens: 1000, requests: 4),
        ]
        let fractions = DashboardInsights.trendFractions(for: buckets)
        XCTAssertEqual(fractions[0], 0)
        XCTAssertEqual(fractions[2], 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(fractions[1], 0)
        XCTAssertTrue(DashboardInsights.trendFractions(for: [TrendBucket]()).isEmpty)
    }
}
