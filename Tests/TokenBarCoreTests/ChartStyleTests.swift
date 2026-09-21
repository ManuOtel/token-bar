import Foundation
import XCTest
@testable import TokenBarCore

/// Configurable trend chart styles (M12): persisted preference with an
/// Automatic default and safe fallback, renderer selection per range and
/// grain, and style-invariant bucket behavior.
///
/// Style picks a renderer over the stored `DashboardSnapshot` trend fields
/// only: bucket count, order, labels, and token sums are identical in every
/// style. All fixtures are synthetic; no file access, no network.
final class ChartStyleTests: XCTestCase {
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
        model: String = "gpt-5-mini", input: Int = 100, output: Int = 50
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: source, timestamp: date,
            model: model, inputTokens: input, outputTokens: output,
            cachedTokens: 0, reasoningTokens: 0,
            totalTokens: 0, sessionId: id, requestId: id)
    }

    private func hoursAgo(_ hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 24 * 3600)
    }

    private func bucket(_ label: String, tokens: Int) -> TrendBucket {
        TrendBucket(start: now, label: label, totalTokens: tokens, requests: tokens > 0 ? 1 : 0)
    }

    // MARK: - Persistence: default, fallback, reset

    func testDefaultIsAutomaticWhenUnset() {
        XCTAssertEqual(ChartStyle.defaultStyle, .automatic)
        XCTAssertEqual(ChartStyle(storedRawValue: nil), .automatic)
    }

    func testUnknownStoredValuesFallBackToAutomatic() {
        for raw in ["heatmap", "BARS", "", "automatic ", "stacked-area", "line-points"] {
            XCTAssertEqual(ChartStyle(storedRawValue: raw), .automatic, "raw: \(raw)")
        }
    }

    func testStoredValuesRoundTrip() {
        for style in ChartStyle.allCases {
            XCTAssertEqual(ChartStyle(storedRawValue: style.rawValue), style, "\(style)")
        }
        XCTAssertEqual(Set(ChartStyle.allCases.map(\.rawValue)),
                       ["automatic", "bars", "line", "area"])
    }

    func testStorageKeyIsStable() {
        // Single user-default key backing the preference; renaming it would
        // orphan persisted selections.
        XCTAssertEqual(ChartStyle.storageKey, "chartStyle")
    }

    func testResetReturnsToAutomatic() {
        // Model a stored non-default value, then an explicit reset to the
        // default raw value; the result must read back as Automatic.
        for style in ChartStyle.allCases where style != .automatic {
            XCTAssertEqual(
                ChartStyle(storedRawValue: style.rawValue), style,
                "stores \(style)")
            let reset = ChartStyle(storedRawValue: ChartStyle.defaultStyle.rawValue)
            XCTAssertEqual(reset, .automatic, "reset from \(style)")
        }
        XCTAssertEqual(ChartStyle.defaultStyle, .automatic)
        XCTAssertEqual(
            ChartStyle(storedRawValue: ChartStyle.defaultStyle.rawValue), .automatic)
    }

    func testDisplayNames() {
        XCTAssertEqual(ChartStyle.automatic.displayName, "Automatic")
        XCTAssertEqual(ChartStyle.bars.displayName, "Bars")
        XCTAssertEqual(ChartStyle.line.displayName, "Line with points")
        XCTAssertEqual(ChartStyle.area.displayName, "Area")
    }

    // MARK: - Renderer selection: Automatic mapping

    func testAutomaticPicksBarsForHourlyAndShortDailyRanges() {
        let buckets = [bucket("00", tokens: 100), bucket("01", tokens: 0)]
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .today, buckets: buckets), .bars)
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .last24Hours, buckets: buckets), .bars)
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .last7Days, buckets: buckets), .bars)
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .bestMonth, buckets: buckets), .bars)
    }

    func testAutomaticPicksLineWithPointsForAllTime() {
        let buckets = [bucket("2026-07", tokens: 100), bucket("2026-08", tokens: 0)]
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .lifetime, buckets: buckets), .linePoints)
    }

    func testAutomatic30DSparseReadsAsBars() {
        // Documented rule: zeroShare >= 0.5 reads as Bars.
        let sparse = (0..<31).map { bucket("d\($0)", tokens: $0 == 3 ? 150 : 0) }
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .last30Days, buckets: sparse), .bars)
        // Boundary: exactly half zero still reads as Bars.
        let half = (0..<8).map { bucket("d\($0)", tokens: $0 < 4 ? 0 : 150) }
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .last30Days, buckets: half), .bars)
        // All zero is fully sparse: Bars.
        let allZero = (0..<8).map { bucket("d\($0)", tokens: 0) }
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .last30Days, buckets: allZero), .bars)
    }

    func testAutomatic30DDenseReadsAsLineWithPoints() {
        let dense = (0..<31).map { bucket("d\($0)", tokens: $0 < 5 ? 0 : 150) }
        XCTAssertEqual(ChartStyle.automatic.resolved(for: .last30Days, buckets: dense), .linePoints)
    }

    func testAutomaticNeverResolvesToArea() {
        let sparse = (0..<8).map { bucket("d\($0)", tokens: 0) }
        let dense = (0..<8).map { bucket("d\($0)", tokens: 150) }
        for preset in DatePreset.allCases {
            for buckets in [sparse, dense, [TrendBucket]()] {
                XCTAssertNotEqual(
                    ChartStyle.automatic.resolved(for: preset, buckets: buckets), .area,
                    "\(preset) with \(buckets.count) buckets")
            }
        }
    }

    func testEmptyBucketsFollowAutomaticMapping() {
        // Resolution never crashes and never picks Area; an empty bucket
        // list follows the same per-range Automatic mapping (Bars except
        // lifetime, which stays Line with points). The views render the
        // empty copy with no chart frame regardless of style.
        for preset in DatePreset.allCases {
            let resolved = ChartStyle.automatic.resolved(for: preset, buckets: [])
            if preset == .lifetime {
                XCTAssertEqual(resolved, .linePoints, "\(preset)")
            } else {
                XCTAssertEqual(resolved, .bars, "\(preset)")
            }
        }
    }

    // MARK: - Renderer selection: explicit picks

    func testExplicitSelectionsRenderTheRequestedMarksForTheSameSnapshot() {
        let records = [
            record("a", at: hoursAgo(1), input: 1000, output: 500),
            record("b", at: daysAgo(2), input: 2000, output: 1000),
        ]
        for preset in DatePreset.allCases {
            let dash = DashboardSnapshot.make(
                records: records, source: .all, preset: preset,
                now: now, snapshot: nil, calendar: calendar)
            XCTAssertEqual(ChartStyle.bars.resolved(for: preset, buckets: dash.trendBuckets), .bars, "\(preset)")
            XCTAssertEqual(ChartStyle.line.resolved(for: preset, buckets: dash.trendBuckets), .linePoints, "\(preset)")
            XCTAssertEqual(ChartStyle.area.resolved(for: preset, buckets: dash.trendBuckets), .area, "\(preset)")
        }
    }

    // MARK: - Empty and no-baseline states

    func testEmptyStoreKeepsEmptyBucketsAndNilComparisonInEveryStyle() {
        // Real contract for an empty 7D scope: zero-filled daily coverage
        // stays present, the bucket total is zero and matches the hero
        // total, and the comparison slot reports no baseline (never a
        // fabricated percent). Resolution only selects a renderer over the
        // stored buckets; it never mutates buckets or comparison.
        let dash = DashboardSnapshot.make(
            records: [], source: .all, preset: .last7Days,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertFalse(dash.trendBuckets.isEmpty, "zero-filled coverage stays present")
        XCTAssertEqual(dash.trendBuckets.count, 8, "7D rolling coverage is 8 daily buckets")
        XCTAssertTrue(dash.trendBuckets.allSatisfy { $0.totalTokens == 0 })
        XCTAssertTrue(dash.trendBuckets.allSatisfy { $0.requests == 0 })
        XCTAssertEqual(dash.trendBuckets.reduce(0) { $0 + $1.totalTokens }, 0)
        XCTAssertEqual(dash.stats.totalTokens, 0)
        XCTAssertNotNil(dash.comparison, "7D keeps the comparison slot with no baseline")
        XCTAssertEqual(dash.comparison?.hasBaseline, false)
        XCTAssertNil(dash.comparison?.direction)
        XCTAssertNil(dash.comparison?.percentChange)
        XCTAssertEqual(
            ChartStyle.automatic.resolved(for: .last7Days, buckets: dash.trendBuckets), .bars)
        XCTAssertEqual(
            ChartStyle.bars.resolved(for: .last7Days, buckets: dash.trendBuckets), .bars)
        XCTAssertEqual(
            ChartStyle.line.resolved(for: .last7Days, buckets: dash.trendBuckets), .linePoints)
        XCTAssertEqual(
            ChartStyle.area.resolved(for: .last7Days, buckets: dash.trendBuckets), .area)
        // View empty-copy boundary without a UI test: an empty lifetime or
        // best-month scope yields no buckets, which is exactly the
        // `buckets.isEmpty` condition behind the "No trend buckets" copy in
        // `AdaptiveTrendChart`; 7D above stays non-empty and renders
        // zero-height bars instead.
        let emptyLifetime = DashboardSnapshot.make(
            records: [], source: .all, preset: .lifetime,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertTrue(emptyLifetime.trendBuckets.isEmpty)
        XCTAssertEqual(emptyLifetime.stats.totalTokens, 0)
        XCTAssertNil(emptyLifetime.comparison)
        let emptyBest = DashboardSnapshot.make(
            records: [], source: .all, preset: .bestMonth,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertTrue(emptyBest.trendBuckets.isEmpty)
        XCTAssertNil(emptyBest.comparison)
    }

    func testNoBaselineComparisonHoldsNoDirectionAndNoPercentInEveryStyle() {
        let records = [record("now", at: hoursAgo(1), input: 100, output: 50)]
        let dash = DashboardSnapshot.make(
            records: records, source: .all, preset: .last30Days,
            now: now, snapshot: nil, calendar: calendar)
        let comparison = dash.comparison
        XCTAssertNotNil(comparison)
        XCTAssertEqual(comparison?.hasBaseline, false)
        XCTAssertNil(comparison?.direction)
        XCTAssertNil(comparison?.percentChange)
        // Style never invents a baseline: resolution over the same buckets
        // leaves the comparison value untouched.
        for style in ChartStyle.allCases {
            _ = style.resolved(for: .last30Days, buckets: dash.trendBuckets)
            XCTAssertEqual(dash.comparison?.hasBaseline, false, "\(style)")
            XCTAssertNil(dash.comparison?.direction, "\(style)")
            XCTAssertNil(dash.comparison?.percentChange, "\(style)")
        }
    }

    func testBestMonthAndLifetimeHaveNoComparisonInEveryStyle() {
        let records = [record("a", at: hoursAgo(1))]
        for preset in [DatePreset.bestMonth, DatePreset.lifetime] {
            let dash = DashboardSnapshot.make(
                records: records, source: .all, preset: preset,
                now: now, snapshot: nil, calendar: calendar)
            XCTAssertNil(dash.comparison, "\(preset)")
            for style in ChartStyle.allCases {
                // No comparison applies to these ranges, in any style.
                _ = style.resolved(for: preset, buckets: dash.trendBuckets)
                XCTAssertNil(dash.comparison, "\(preset) \(style)")
            }
        }
    }

    // MARK: - Trend and bucket behavior is style-invariant

    func testBucketSumsEqualHeroTotalInEveryStyle() {
        let records = [
            record("codex-recent", source: .codex, at: hoursAgo(1), input: 1000, output: 500),
            record("open-recent", source: .opencode, at: daysAgo(2), input: 2000, output: 1000),
            record("claude-old", source: .claude, at: daysAgo(45), input: 300, output: 200),
        ]
        let presets: [DatePreset] = [.today, .last24Hours, .last7Days, .last30Days, .lifetime]
        for preset in presets {
            let dash = DashboardSnapshot.make(
                records: records, source: .all, preset: preset,
                now: now, snapshot: nil, calendar: calendar)
            for style in ChartStyle.allCases {
                _ = style.resolved(for: preset, buckets: dash.trendBuckets)
                XCTAssertEqual(
                    dash.trendBuckets.reduce(0) { $0 + $1.totalTokens },
                    dash.stats.totalTokens, "\(preset) \(style)")
            }
        }
    }

    func testBucketCoverageIsUnchangedByStyle() {
        let records = [record("a", at: daysAgo(1), input: 100, output: 50)]
        let dash = DashboardSnapshot.make(
            records: records, source: .all, preset: .last30Days,
            now: now, snapshot: nil, calendar: calendar)
        // Full zero-filled coverage holds no matter which renderer reads it.
        for style in ChartStyle.allCases {
            _ = style.resolved(for: .last30Days, buckets: dash.trendBuckets)
            XCTAssertEqual(dash.trendBuckets.count, 31, "\(style)")
            XCTAssertEqual(dash.trendBuckets.first?.label, "2026-08-11", "\(style)")
            XCTAssertEqual(dash.trendBuckets.last?.label, "2026-09-10", "\(style)")
            XCTAssertEqual(
                dash.trendBuckets.filter { $0.requests == 0 }.count, 30, "\(style)")
        }
    }

    func testResolvedDisplayNames() {
        XCTAssertEqual(ResolvedTrendStyle.bars.displayName, "bars")
        XCTAssertEqual(ResolvedTrendStyle.linePoints.displayName, "line with points")
        XCTAssertEqual(ResolvedTrendStyle.area.displayName, "area")
    }
}
