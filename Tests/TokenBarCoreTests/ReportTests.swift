import Foundation
import XCTest
@testable import TokenBarCore

/// Pure formatter/report tests. Synthetic data only, no private logs.
final class ReportTests: XCTestCase {
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
        model: String = "gpt-5-mini", input: Int = 100, output: Int = 50,
        session: String = "s1", request: String = ""
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: source,
            timestamp: now.addingTimeInterval(-hoursAgo * 3600),
            model: model, inputTokens: input, outputTokens: output,
            cachedTokens: 0, reasoningTokens: 0,
            totalTokens: 0, sessionId: session,
            requestId: request.isEmpty ? id : request
        )
    }

    func testLifetimeSectionTotalsAndSplits() {
        let records = [
            record("a", source: .codex, hoursAgo: 1, input: 1000, output: 200),
            record("b", source: .opencode, hoursAgo: 2, input: 500, output: 100),
        ]
        let section = ReportFormatter.section(
            records: records, source: .all, preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(section.stats.totalTokens, 1800)
        XCTAssertEqual(section.stats.inputTokens, 1500)
        XCTAssertEqual(section.stats.outputTokens, 300)
        XCTAssertEqual(section.stats.requests, 2)
        XCTAssertEqual(section.stats.bySource.count, 2)
        let text = ReportFormatter.render(section: section)
        XCTAssertTrue(text.contains("Total tokens: 1800"))
        XCTAssertTrue(text.contains("Input tokens: 1500"))
        XCTAssertTrue(text.contains("Estimated cost:"))
        XCTAssertTrue(text.contains("estimate"))
        XCTAssertTrue(text.contains("codex"))
        XCTAssertTrue(text.contains("opencode"))
    }

    func testWarningSanitizerHidesRawPaths() {
        let raw = "Codex sessions not found at /Users/someone/.codex/sessions."
        let clean = ReportFormatter.sanitizeWarning(raw)
        XCTAssertFalse(clean.contains("/Users/someone"))
        XCTAssertFalse(clean.contains("/.codex/"))
        XCTAssertTrue(clean.contains("TOKENBAR_CODEX_ROOT"))

        let dbRaw = "OpenCode database not found at /Users/someone/.local/share/opencode/opencode.db."
        XCTAssertFalse(ReportFormatter.sanitizeWarning(dbRaw).contains("/Users/"))

        let generic = ReportFormatter.sanitizeWarning("Read failed at /tmp/secret/x.db today")
        XCTAssertFalse(generic.contains("/tmp/secret/x.db"))
        XCTAssertTrue(generic.contains("<path>"))
    }

    func testRenderNeverLeaksPathsAndLabelsEstimate() {
        let section = ReportFormatter.section(records: [], source: .all, preset: .lifetime, now: now, calendar: calendar)
        let text = ReportFormatter.render(
            section: section,
            warnings: ["Codex sessions not found at /Users/private/.codex/sessions."])
        XCTAssertFalse(text.contains("/Users/private"))
        XCTAssertTrue(text.contains("Estimated cost:"))
        XCTAssertTrue(text.contains("No usage records"))
    }

    func testBestMonthSectionCarriesMonthKey() {
        let formatter = ISO8601DateFormatter()
        func dated(_ id: String, _ iso: String, total: Int) -> NormalizedUsage {
            NormalizedUsage(
                id: id, source: .codex, timestamp: formatter.date(from: iso)!,
                model: "m", inputTokens: total, outputTokens: 0, cachedTokens: 0,
                reasoningTokens: 0, totalTokens: 0, sessionId: id, requestId: id)
        }
        let records = [
            dated("aug", "2026-08-05T10:00:00Z", total: 1000),
            dated("sep", "2026-09-05T10:00:00Z", total: 5000),
        ]
        let section = ReportFormatter.section(
            records: records, source: .all, preset: .bestMonth, now: now, calendar: calendar)
        XCTAssertEqual(section.bestMonthKey, "2026-09")
        XCTAssertEqual(section.stats.totalTokens, 5000)
        XCTAssertTrue(ReportFormatter.render(section: section).contains("2026-09"))
    }

    func testJSONEncodingIsDeterministicAndSanitized() throws {
        let records = [record("a", source: .codex, hoursAgo: 1)]
        let section = ReportFormatter.section(
            records: records, source: .all, preset: .lifetime, now: now, calendar: calendar)
        let first = try ReportFormatter.encodeJSON(
            sections: [section], warnings: ["Codex sessions not found at /Users/x/.codex/sessions."])
        let second = try ReportFormatter.encodeJSON(
            sections: [section], warnings: ["Codex sessions not found at /Users/x/.codex/sessions."])
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("/Users/x"))
        XCTAssertTrue(first.contains("estimatedCostUSD"))
        XCTAssertTrue(first.contains("totalTokens"))
    }
}
