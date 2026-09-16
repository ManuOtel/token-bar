import Foundation
import XCTest
@testable import TokenBarCore

/// Slice 2 (single-pass dashboard): one explicit `now` drives the selected
/// stats, chip totals, best-month key, and menu total.
///
/// These tests pin value preservation, not timing: the snapshot must agree
/// with the legacy per-render `Aggregator.filter` + `aggregate` + reduce
/// math for every preset/source, chips must reconcile with the all-source
/// scope, best-month key/stats must agree, and a pricing snapshot change
/// must recompute derived costs. Hermetic, no network, no local data.
final class DashboardSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_789_041_600) // 2026-09-10T12:00:00Z
    }

    private func record(
        _ id: String, source: UsageSource, hoursAgo: Double,
        model: String = "gpt-5-mini", input: Int = 100, output: Int = 50
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: source,
            timestamp: now.addingTimeInterval(-hoursAgo * 3600),
            model: model, inputTokens: input, outputTokens: output,
            cachedTokens: 0, reasoningTokens: 0,
            totalTokens: 0, sessionId: id, requestId: id)
    }

    private func snapshot(entries: [CatalogEntry], fresh: Bool = true) -> CatalogSnapshot {
        CatalogSnapshot(
            catalog: PricingCatalog(
                sourceURL: OpenRouterCatalog.defaultURLString,
                fetchedAt: now,
                entries: entries),
            isFresh: fresh)
    }

    private var mixedRecords: [NormalizedUsage] {
        [
            record("codex-recent", source: .codex, hoursAgo: 1, input: 1000, output: 500),
            record("opencode-recent", source: .opencode, hoursAgo: 2, input: 2000, output: 1000),
            record("claude-recent", source: .claude, hoursAgo: 3, input: 300, output: 200),
            record("codex-old", source: .codex, hoursAgo: 8 * 24, input: 400, output: 100),
            record("opencode-old", source: .opencode, hoursAgo: 40 * 24, input: 700, output: 300),
        ]
    }

    // MARK: - Selected stats and menu total agree (window presets)

    func testSelectedStatsAndMenuTotalAgree() {
        let presets: [DatePreset] = [.today, .last24Hours, .last7Days, .last30Days, .lifetime]
        let sources: [SourceFilter] = [.all, .codex, .opencode, .claude]
        for preset in presets {
            for source in sources {
                let dash = DashboardSnapshot.make(
                    records: mixedRecords, source: source, preset: preset,
                    now: now, snapshot: nil, calendar: calendar)
                // Legacy math, computed independently of the snapshot.
                let scoped = Aggregator.filter(
                    mixedRecords, source: source, preset: preset, now: now, calendar: calendar)
                let expected = Aggregator.aggregate(scoped, snapshot: nil, calendar: calendar)
                XCTAssertEqual(dash.stats.totalTokens, expected.totalTokens, "\(preset) \(source)")
                XCTAssertEqual(dash.stats.requests, expected.requests, "\(preset) \(source)")
                XCTAssertEqual(dash.stats.estimatedCostUSD, expected.estimatedCostUSD, accuracy: 0.0001, "\(preset) \(source)")
                XCTAssertEqual(dash.scopedCount, scoped.count, "\(preset) \(source)")
                XCTAssertEqual(dash.scopedCount, dash.stats.requests, "\(preset) \(source)")
                // Menu title basis is the selected total for window presets.
                XCTAssertEqual(dash.menuTotalTokens, dash.stats.totalTokens, "\(preset) \(source)")
                XCTAssertEqual(
                    dash.menuTotalTokens, scoped.reduce(0) { $0 + $1.totalTokens }, "\(preset) \(source)")
                XCTAssertNil(dash.bestMonthKey, "\(preset) \(source)")
            }
        }
    }

    // MARK: - Source chip totals reconcile with the all-source scope

    func testSourceChipsReconcileWithAllSource() {
        let presets: [DatePreset] = [.today, .last24Hours, .last7Days, .last30Days, .lifetime, .bestMonth]
        for preset in presets {
            let dash = DashboardSnapshot.make(
                records: mixedRecords, source: .all, preset: preset,
                now: now, snapshot: nil, calendar: calendar)
            XCTAssertEqual(
                dash.sourceTotals.map(\.filter),
                [.all, .codex, .opencode, .claude], "\(preset)")
            // Each chip matches an independent filter + reduce for that
            // source and preset (the legacy chip math, minus the sort).
            for chip in dash.sourceTotals {
                let rows = Aggregator.filter(
                    mixedRecords, source: chip.filter, preset: preset, now: now, calendar: calendar)
                XCTAssertEqual(chip.tokens, rows.reduce(0) { $0 + $1.totalTokens }, "\(preset) \(chip.filter)")
                XCTAssertEqual(chip.requests, rows.count, "\(preset) \(chip.filter)")
            }
            // All-source chip is the sum of the three source chips.
            let byFilter = Dictionary(uniqueKeysWithValues: dash.sourceTotals.map { ($0.filter, $0) })
            let summedTokens = byFilter[.codex]!.tokens + byFilter[.opencode]!.tokens + byFilter[.claude]!.tokens
            let summedRequests = byFilter[.codex]!.requests + byFilter[.opencode]!.requests + byFilter[.claude]!.requests
            XCTAssertEqual(byFilter[.all]!.tokens, summedTokens, "\(preset)")
            XCTAssertEqual(byFilter[.all]!.requests, summedRequests, "\(preset)")
        }
    }

    // MARK: - Best-month key/stats agree, menu keeps the lifetime title

    func testBestMonthKeyStatsAgree() {
        let formatter = ISO8601DateFormatter()
        func dated(_ id: String, _ iso: String, total: Int, source: UsageSource = .codex) -> NormalizedUsage {
            NormalizedUsage(
                id: id, source: source, timestamp: formatter.date(from: iso)!,
                model: "gpt-5-mini", inputTokens: total, outputTokens: 0,
                cachedTokens: 0, reasoningTokens: 0,
                totalTokens: 0, sessionId: id, requestId: id)
        }
        let records = [
            dated("aug-1", "2026-08-05T10:00:00Z", total: 1000),
            dated("aug-2", "2026-08-06T10:00:00Z", total: 500, source: .opencode),
            dated("sep-1", "2026-09-05T10:00:00Z", total: 5000),
        ]
        let dash = DashboardSnapshot.make(
            records: records, source: .all, preset: .bestMonth,
            now: now, snapshot: nil, calendar: calendar)
        let lifetime = Aggregator.filter(
            records, source: .all, preset: .lifetime, now: now, calendar: calendar)
        let best = Aggregator.bestMonth(lifetime, snapshot: nil, calendar: calendar)!
        XCTAssertEqual(dash.bestMonthKey, "2026-09")
        XCTAssertEqual(dash.bestMonthKey, best.monthKey)
        XCTAssertEqual(dash.stats.totalTokens, best.stats.totalTokens)
        XCTAssertEqual(dash.stats.requests, best.stats.requests)
        XCTAssertEqual(dash.stats.estimatedCostUSD, best.stats.estimatedCostUSD, accuracy: 0.0001)
        // Legacy UI semantics preserved: the menu title shows the lifetime
        // total while the dashboard shows the winning month.
        XCTAssertEqual(dash.scopedCount, lifetime.count)
        XCTAssertEqual(dash.menuTotalTokens, lifetime.reduce(0) { $0 + $1.totalTokens })
        XCTAssertEqual(dash.menuTotalTokens, 6500)
        XCTAssertEqual(dash.stats.totalTokens, 5000)
    }

    func testBestMonthEmptyScopeHasNoKey() {
        let dash = DashboardSnapshot.make(
            records: [], source: .all, preset: .bestMonth,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertNil(dash.bestMonthKey)
        XCTAssertEqual(dash.stats.requests, 0)
        XCTAssertEqual(dash.scopedCount, 0)
        XCTAssertEqual(dash.menuTotalTokens, 0)
        XCTAssertTrue(dash.sourceTotals.allSatisfy { $0.tokens == 0 && $0.requests == 0 })
    }

    // MARK: - Pricing snapshot change recomputes derived costs

    func testPricingSnapshotChangeRecomputesCost() {
        let records = [
            record("a", source: .codex, hoursAgo: 1, model: "openai/gpt-4o", input: 1_000_000, output: 0),
            record("b", source: .opencode, hoursAgo: 2, model: "openai/gpt-4o", input: 1_000_000, output: 0),
        ]
        let offline = DashboardSnapshot.make(
            records: records, source: .all, preset: .lifetime,
            now: now, snapshot: nil, calendar: calendar)
        let catalogRate = CatalogEntry(
            model: "openai/gpt-4o", inputPerMTok: 42.0, outputPerMTok: 84.0, cachedPerMTok: 21.0)
        let priced = DashboardSnapshot.make(
            records: records, source: .all, preset: .lifetime,
            now: now, snapshot: snapshot(entries: [catalogRate]), calendar: calendar)
        // Token totals are pricing-independent; costs follow the snapshot.
        XCTAssertEqual(priced.stats.totalTokens, offline.stats.totalTokens)
        XCTAssertNotEqual(priced.stats.estimatedCostUSD, offline.stats.estimatedCostUSD)
        let expected = Aggregator.aggregate(
            records, snapshot: snapshot(entries: [catalogRate]), calendar: calendar)
        XCTAssertEqual(priced.stats.estimatedCostUSD, expected.estimatedCostUSD, accuracy: 0.0000001)
        // A different catalog rate recomputes again (no stale cost).
        let cheaper = DashboardSnapshot.make(
            records: records, source: .all, preset: .lifetime,
            now: now,
            snapshot: snapshot(entries: [
                CatalogEntry(
                    model: "openai/gpt-4o", inputPerMTok: 1.0, outputPerMTok: 1.0, cachedPerMTok: 1.0),
            ]),
            calendar: calendar)
        XCTAssertNotEqual(cheaper.stats.estimatedCostUSD, priced.stats.estimatedCostUSD)
        XCTAssertEqual(cheaper.menuTotalTokens, priced.menuTotalTokens)
    }

    // MARK: - Menu title shares the compact count contract

    func testMenuTitleUsesSharedCompactFormat() {
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 0), "0")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 999), "999")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 1000), "1k")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 1500), "1.5k")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 999_949), "999.9k")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 999_950), "1M")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 999_999), "1M")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 1_000_000), "1M")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 2_345_678), "2.3M")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 999_949_999), "999.9M")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 999_950_000), "1B")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 1_000_000_000), "1B")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 2_416_100_000), "2.4B")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 2_000_000_000), "2B")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 999_949_999_999), "999.9B")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 999_950_000_000), "1T")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 1_000_000_000_000), "1T")
        XCTAssertEqual(DashboardSnapshot.menuTitle(forTotal: 1_500_000_000_000), "1.5T")
    }

    func testMenuTitleMatchesSharedCompactFormatter() {
        let samples = [
            0, 1, -1, 999, 1000, 1500, 999_949, 999_950, 1_000_000,
            2_345_678, 999_949_999, 999_950_000, 1_000_000_000,
            2_416_100_000, 999_949_999_999, 999_950_000_000,
            1_500_000_000_000, -1500, Int.max, Int.min,
        ]
        for total in samples {
            XCTAssertEqual(
                DashboardSnapshot.menuTitle(forTotal: total),
                TokenCountFormat.compact(total),
                "menu title must equal the shared compact count for \(total)")
        }
    }

    // MARK: - Today-zero Codex with lifetime history is a range effect

    func testTodayZeroCodexWithLifetimeHistoryIsRangeEffect() {
        // Triage guard for "Codex shows 0 while OpenCode has usage" on the
        // narrow calendar-day window (formerly the app default): Codex
        // history from 8 days ago parses
        // fine but lives outside the calendar-day window, while an OpenCode
        // record from 1 hour ago is inside it. Lifetime must show both.
        // Synthetic records only, no local data.
        let records = [
            record("codex-8d", source: .codex, hoursAgo: 8 * 24, input: 1200, output: 340),
            record("opencode-1h", source: .opencode, hoursAgo: 1, input: 2000, output: 1000),
        ]
        // Ingestion is intact: the Codex row survives the lifetime filter.
        let lifetimeCodex = Aggregator.filter(
            records, source: .codex, preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(lifetimeCodex.map(\.id), ["codex-8d"])
        // ... but the calendar-day window correctly excludes it.
        let todayCodex = Aggregator.filter(
            records, source: .codex, preset: .today, now: now, calendar: calendar)
        XCTAssertTrue(todayCodex.isEmpty)
        // Chip totals tell the same story the dashboard shows.
        let todayDash = DashboardSnapshot.make(
            records: records, source: .all, preset: .today,
            now: now, snapshot: nil, calendar: calendar)
        let todayChips = Dictionary(
            uniqueKeysWithValues: todayDash.sourceTotals.map { ($0.filter, $0) })
        XCTAssertEqual(todayChips[.codex]?.requests, 0)
        XCTAssertEqual(todayChips[.codex]?.tokens, 0)
        XCTAssertEqual(todayChips[.opencode]?.requests, 1)
        XCTAssertGreaterThan(todayChips[.opencode]?.tokens ?? 0, 0)
        let lifetimeDash = DashboardSnapshot.make(
            records: records, source: .all, preset: .lifetime,
            now: now, snapshot: nil, calendar: calendar)
        let lifetimeChips = Dictionary(
            uniqueKeysWithValues: lifetimeDash.sourceTotals.map { ($0.filter, $0) })
        XCTAssertEqual(lifetimeChips[.codex]?.requests, 1)
        XCTAssertGreaterThan(lifetimeChips[.codex]?.tokens ?? 0, 0)
        XCTAssertEqual(lifetimeChips[.opencode]?.requests, 1)
        // The Codex-scoped Today selection is empty while Lifetime is not,
        // so the empty-state "try another range" guidance applies.
        let codexToday = DashboardSnapshot.make(
            records: records, source: .codex, preset: .today,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(codexToday.scopedCount, 0)
        let codexLifetime = DashboardSnapshot.make(
            records: records, source: .codex, preset: .lifetime,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(codexLifetime.scopedCount, 1)
    }

    // MARK: - Initial range defaults to the rolling last 7 days

    func testDefaultPresetIsRollingLast7Days() {
        // A usage tracker that opens on the narrow calendar-day window reads
        // as empty most mornings; the initial dashboard range is the rolling
        // last 7 days. Range chips and token/source math are unchanged.
        XCTAssertEqual(DashboardSnapshot.defaultPreset, .last7Days)
    }

    func testDefaultRangeShowsRecentWeekMissedByToday() {
        // Synthetic only: a record from 2 days ago sits outside the calendar
        // day but inside the default 7D window, so the new default shows it.
        // An 8-day-old record stays outside 7D (30D catches it), pinning that
        // the empty-state widening suggestion still matters.
        let records = [
            record("codex-2d", source: .codex, hoursAgo: 2 * 24, input: 1200, output: 340),
            record("codex-8d", source: .codex, hoursAgo: 8 * 24, input: 1200, output: 340),
        ]
        let today = DashboardSnapshot.make(
            records: records, source: .codex, preset: .today,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(today.scopedCount, 0)
        let week = DashboardSnapshot.make(
            records: records, source: .codex, preset: DashboardSnapshot.defaultPreset,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(week.scopedCount, 1)
        XCTAssertEqual(week.stats.requests, 1)
        let month = DashboardSnapshot.make(
            records: records, source: .codex, preset: .last30Days,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(month.scopedCount, 2)
    }

    // MARK: - Empty-range guidance offers the most useful wider range

    func testSuggestedWiderPresetMapping() {
        // Narrow windows widen to 30D first; 30D and Best widen to lifetime;
        // lifetime has no wider range. Source-agnostic, no per-source logic.
        XCTAssertEqual(DashboardSnapshot.suggestedWiderPreset(for: .today), .last30Days)
        XCTAssertEqual(DashboardSnapshot.suggestedWiderPreset(for: .last24Hours), .last30Days)
        XCTAssertEqual(DashboardSnapshot.suggestedWiderPreset(for: .last7Days), .last30Days)
        XCTAssertEqual(DashboardSnapshot.suggestedWiderPreset(for: .last30Days), .lifetime)
        XCTAssertEqual(DashboardSnapshot.suggestedWiderPreset(for: .bestMonth), .lifetime)
        XCTAssertNil(DashboardSnapshot.suggestedWiderPreset(for: .lifetime))
    }

    func testEmptyNarrowScopeSuggestsWiderRangeWithHistory() {
        // The verified confusion shape: Codex history from 8 days ago is
        // empty under Today, and the guidance must point at 30D (which holds
        // the record), not back at Today. Synthetic records only.
        let records = [
            record("codex-8d", source: .codex, hoursAgo: 8 * 24, input: 1200, output: 340),
        ]
        let today = DashboardSnapshot.make(
            records: records, source: .codex, preset: .today,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(today.scopedCount, 0)
        XCTAssertEqual(DashboardSnapshot.suggestedWiderPreset(for: .today), .last30Days)
        let wider = DashboardSnapshot.make(
            records: records, source: .codex,
            preset: DashboardSnapshot.suggestedWiderPreset(for: .today)!,
            now: now, snapshot: nil, calendar: calendar)
        XCTAssertEqual(wider.scopedCount, 1)
    }
}
