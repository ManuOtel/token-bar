import XCTest
@testable import TokenBarCore

final class DashboardInsightsTests: XCTestCase {
    private func stats(input: Int, output: Int, cached: Int, reasoning: Int, total: Int) -> AggregatedStats {
        AggregatedStats(
            totalTokens: total, inputTokens: input, outputTokens: output,
            cachedTokens: cached, reasoningTokens: reasoning,
            requests: 2, sessions: 1, estimatedCostUSD: 0,
            lastUpdated: nil, byModel: [], bySource: [], byOrigin: [], dailyTrend: []
        )
    }

    func testEmptyScopeYieldsZeroShares() {
        let comp = DashboardInsights.composition(for: .empty)
        XCTAssertEqual(comp.inputShare, 0)
        XCTAssertEqual(comp.outputShare, 0)
        XCTAssertEqual(comp.cachedShareOfInput, 0)
        XCTAssertEqual(comp.reasoningShareOfOutput, 0)
        XCTAssertTrue(DashboardInsights.shares(for: [], totalTokens: 0).isEmpty)
        XCTAssertTrue(DashboardInsights.trendFractions(for: []).isEmpty)
    }

    func testCompositionSplitsTotalAndLabelsSubsets() {
        // 600 input + 400 output = 1000 total; cached 150 is 25% of input,
        // reasoning 100 is 25% of output. Visuals must split the ring into
        // input/output only and read cached/reasoning as subsets.
        let comp = DashboardInsights.composition(for: stats(input: 600, output: 400, cached: 150, reasoning: 100, total: 1000))
        XCTAssertEqual(comp.inputShare, 0.6, accuracy: 1e-9)
        XCTAssertEqual(comp.outputShare, 0.4, accuracy: 1e-9)
        XCTAssertEqual(comp.cachedShareOfInput, 0.25, accuracy: 1e-9)
        XCTAssertEqual(comp.reasoningShareOfOutput, 0.25, accuracy: 1e-9)
        XCTAssertEqual(comp.inputShare + comp.outputShare, 1.0, accuracy: 1e-9)
    }

    func testCompositionClampsAgainstBadTotals() {
        let comp = DashboardInsights.composition(for: stats(input: 0, output: 0, cached: 5, reasoning: 5, total: 0))
        XCTAssertEqual(comp.inputShare, 0)
        XCTAssertEqual(comp.outputShare, 0)
        // Zero input/output denominators never produce NaN.
        XCTAssertEqual(comp.cachedShareOfInput, 0)
        XCTAssertEqual(comp.reasoningShareOfOutput, 0)
    }

    func testSharesNormalizeAndPreserveOrder() {
        let entries = [
            BreakdownEntry(key: "opencode", totalTokens: 700, requests: 7, estimatedCostUSD: 0),
            BreakdownEntry(key: "codex", totalTokens: 300, requests: 3, estimatedCostUSD: 0),
        ]
        let out = DashboardInsights.shares(for: entries, totalTokens: 1000)
        XCTAssertEqual(out.map(\.key), ["opencode", "codex"])
        XCTAssertEqual(out[0].share, 0.7, accuracy: 1e-9)
        XCTAssertEqual(out[1].share, 0.3, accuracy: 1e-9)
        XCTAssertEqual(out.reduce(0) { $0 + $1.share }, 1.0, accuracy: 1e-9)
    }

    func testTrendFractionsScaleToPeakWithHairlineFloor() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let buckets = [
            DailyBucket(dayStart: day, dayLabel: "2026-09-10", totalTokens: 0, requests: 0),
            DailyBucket(dayStart: day, dayLabel: "2026-09-11", totalTokens: 50, requests: 1),
            DailyBucket(dayStart: day, dayLabel: "2026-09-12", totalTokens: 1000, requests: 4),
        ]
        let fractions = DashboardInsights.trendFractions(for: buckets)
        XCTAssertEqual(fractions[0], 0)
        XCTAssertEqual(fractions[2], 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(fractions[1], 0)
        XCTAssertLessThan(fractions[1], fractions[2])
    }

    func testTopModelsRespectsLimit() {
        var stats = AggregatedStats.empty
        stats.byModel = (1...7).map { BreakdownEntry(key: "m\($0)", totalTokens: 100 - $0, requests: 1, estimatedCostUSD: 0) }
        XCTAssertEqual(DashboardInsights.topModels(in: stats, limit: 3).count, 3)
        XCTAssertEqual(DashboardInsights.topModels(in: stats, limit: 0).count, 0)
        XCTAssertEqual(DashboardInsights.topModels(in: stats).count, 5)
    }
}
