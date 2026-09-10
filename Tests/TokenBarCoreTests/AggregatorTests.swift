import Foundation
import XCTest
@testable import TokenBarCore

final class AggregatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        // 2026-09-10T12:00:00Z fixed clock.
        Date(timeIntervalSince1970: 1_789_041_600)
    }

    private func record(
        _ id: String, source: UsageSource, hoursAgo: Double,
        model: String = "gpt-5-mini", input: Int = 100, output: Int = 50,
        session: String = "", request: String = ""
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: source,
            timestamp: now.addingTimeInterval(-hoursAgo * 3600),
            model: model, inputTokens: input, outputTokens: output,
            cachedTokens: 0, reasoningTokens: 0,
            totalTokens: 0, sessionId: session.isEmpty ? id : session,
            requestId: request.isEmpty ? id : request
        )
    }

    func testSourceFilter() {
        let records = [
            record("a", source: .codex, hoursAgo: 1),
            record("b", source: .opencode, hoursAgo: 1),
        ]
        XCTAssertEqual(Aggregator.filter(records, source: .codex, preset: .lifetime, now: now, calendar: calendar).count, 1)
        XCTAssertEqual(Aggregator.filter(records, source: .opencode, preset: .lifetime, now: now, calendar: calendar).count, 1)
        XCTAssertEqual(Aggregator.filter(records, source: .all, preset: .lifetime, now: now, calendar: calendar).count, 2)
    }

    func testTodayIsCalendarDayNotRolling() {
        // 11h ago = same calendar day (01:00Z), 13h ago = previous day (23:00Z prior day).
        let sameDay = record("same", source: .codex, hoursAgo: 11)
        let priorDay = record("prior", source: .codex, hoursAgo: 13)
        let filtered = Aggregator.filter([sameDay, priorDay], source: .all, preset: .today, now: now, calendar: calendar)
        XCTAssertEqual(filtered.map(\.id), ["same"])
    }

    func testLast24HoursIsRolling() {
        let inside = record("in", source: .codex, hoursAgo: 23)
        let outside = record("out", source: .codex, hoursAgo: 25)
        let filtered = Aggregator.filter([inside, outside], source: .all, preset: .last24Hours, now: now, calendar: calendar)
        XCTAssertEqual(filtered.map(\.id), ["in"])
    }

    func testLast7And30DaysRolling() {
        let d6 = record("d6", source: .codex, hoursAgo: 6 * 24)
        let d8 = record("d8", source: .codex, hoursAgo: 8 * 24)
        let d29 = record("d29", source: .codex, hoursAgo: 29 * 24)
        let d31 = record("d31", source: .codex, hoursAgo: 31 * 24)
        let seven = Aggregator.filter([d6, d8], source: .all, preset: .last7Days, now: now, calendar: calendar)
        XCTAssertEqual(seven.map(\.id), ["d6"])
        let thirty = Aggregator.filter([d29, d31], source: .all, preset: .last30Days, now: now, calendar: calendar)
        XCTAssertEqual(thirty.map(\.id), ["d29"])
    }

    func testDateBoundaryInclusive() {
        let edge = record("edge", source: .codex, hoursAgo: 24) // exactly now-24h
        let filtered = Aggregator.filter([edge], source: .all, preset: .last24Hours, now: now, calendar: calendar)
        XCTAssertEqual(filtered.count, 1)
        let future = NormalizedUsage(
            id: "future", source: .codex, timestamp: now.addingTimeInterval(3600),
            model: "m", inputTokens: 10, outputTokens: 5, cachedTokens: 0,
            reasoningTokens: 0, totalTokens: 0, sessionId: "s", requestId: "r"
        )
        XCTAssertTrue(Aggregator.filter([future], source: .all, preset: .last24Hours, now: now, calendar: calendar).isEmpty)
    }

    func testBestMonthPicksMaxAndBreaksTiesEarliest() {
        func dated(_ id: String, _ iso: String, total: Int) -> NormalizedUsage {
            let formatter = ISO8601DateFormatter()
            return NormalizedUsage(
                id: id, source: .codex, timestamp: formatter.date(from: iso)!,
                model: "m", inputTokens: total, outputTokens: 0, cachedTokens: 0,
                reasoningTokens: 0, totalTokens: 0, sessionId: id, requestId: id
            )
        }
        let records = [
            dated("aug", "2026-08-05T10:00:00Z", total: 1000),
            dated("sep", "2026-09-05T10:00:00Z", total: 5000),
            dated("jul", "2026-07-05T10:00:00Z", total: 200),
        ]
        XCTAssertEqual(Aggregator.bestMonth(records, calendar: calendar)?.monthKey, "2026-09")

        let tied = [
            dated("aug", "2026-08-05T10:00:00Z", total: 1000),
            dated("sep", "2026-09-05T10:00:00Z", total: 1000),
        ]
        XCTAssertEqual(Aggregator.bestMonth(tied, calendar: calendar)?.monthKey, "2026-08")
        XCTAssertNil(Aggregator.bestMonth([], calendar: calendar))
    }

    func testAggregationTotalsSessionsCostAndBreakdowns() {
        let records = [
            record("a", source: .codex, hoursAgo: 1, model: "gpt-4o-mini", input: 1_000_000, output: 0, session: "s1", request: "r1"),
            record("b", source: .opencode, hoursAgo: 2, model: "gpt-4o-mini", input: 0, output: 1_000_000, session: "s1", request: "r2"),
            record("c", source: .opencode, hoursAgo: 3, model: "mystery-model", input: 100, output: 50, session: "s2", request: "r3"),
        ]
        let stats = Aggregator.aggregate(records, calendar: calendar)
        XCTAssertEqual(stats.requests, 3)
        XCTAssertEqual(stats.sessions, 2) // s1 shared
        XCTAssertEqual(stats.inputTokens, 1_000_100)
        XCTAssertEqual(stats.outputTokens, 1_000_050)
        XCTAssertEqual(stats.totalTokens, 2_000_150)
        // gpt-4o-mini: 1M input @0.15 + 1M output @0.60 = 0.75; mystery uses fallback.
        XCTAssertEqual(stats.estimatedCostUSD, 0.75 + Pricing.cost(model: "mystery-model", inputTokens: 100, outputTokens: 50, cachedTokens: 0), accuracy: 0.0001)
        XCTAssertEqual(stats.bySource.count, 2)
        XCTAssertEqual(stats.byModel.first?.key, "gpt-4o-mini")
        XCTAssertNotNil(stats.lastUpdated)
        XCTAssertFalse(stats.dailyTrend.isEmpty)
    }

    func testCachedSubsetNeverDoubleCounted() {
        let priced = Pricing.cost(model: "gpt-4o", inputTokens: 1000, outputTokens: 0, cachedTokens: 1000)
        // All input cached => only cached rate applies.
        XCTAssertEqual(priced, 1000.0 / 1_000_000.0 * 1.25, accuracy: 0.000001)
        let rec = NormalizedUsage(
            id: "x", source: .codex, timestamp: now, model: "gpt-4o",
            inputTokens: 1000, outputTokens: 500, cachedTokens: 1000,
            reasoningTokens: 500, totalTokens: 0, sessionId: "s", requestId: "r"
        )
        XCTAssertEqual(rec.totalTokens, 1500) // reasoning not added on top
    }

    func testDedupeKeepsEarliestAndDropsDuplicateRequestIds() {
        let first = record("first", source: .codex, hoursAgo: 5, session: "s", request: "dup")
        let second = record("second", source: .codex, hoursAgo: 1, session: "s", request: "dup")
        let other = record("other", source: .opencode, hoursAgo: 1, session: "s", request: "dup") // other source: kept
        let deduped = TokenBarStore.dedupe([second, first, other])
        XCTAssertEqual(deduped.count, 2)
        XCTAssertTrue(deduped.contains(where: { $0.id == "first" }))
        XCTAssertTrue(deduped.contains(where: { $0.id == "other" }))
    }

    func testEmptyAggregation() {
        let stats = Aggregator.aggregate([], calendar: calendar)
        XCTAssertEqual(stats.requests, 0)
        XCTAssertNil(stats.lastUpdated)
        XCTAssertTrue(stats.dailyTrend.isEmpty)
    }
}
