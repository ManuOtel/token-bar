import Foundation
import XCTest
@testable import TokenBarCore

/// M13 Source Health and Coverage: pure health derivation over the
/// already-loaded records plus sanitized warnings/counters.
///
/// Synthetic data only, no file reads except the health fixture, no
/// network, no subprocess. Covers: six-state precedence, the allow-listed
/// sanitized warning decision table, unknown-warning notice-only behavior,
/// cross-source rows regardless of chip, Best `bestMonthKey`
/// contributions, lifetime-vs-range last-observed maxima, OpenCode origin
/// groups (exact sanitized labels, unmerged customs, sole-origin naming,
/// provider-level skipped counts), sync freshness states, and the
/// empty-store path plus `DashboardSnapshot` threading.
final class SourceHealthTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_789_041_600) // 2026-09-10T12:00:00Z
    }

    private func usage(
        _ id: String, source: UsageSource, hoursAgo: Double,
        origin: String = "local", input: Int = 100, output: Int = 50
    ) -> NormalizedUsage {
        NormalizedUsage(
            id: id, source: source,
            timestamp: now.addingTimeInterval(-hoursAgo * 3600),
            model: "synth-model", inputTokens: input, outputTokens: output,
            cachedTokens: 0, reasoningTokens: 0,
            totalTokens: 0, sessionId: id, requestId: id, origin: origin)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func row(_ report: SourceHealthReport, titled title: String) -> SourceHealthRow? {
        report.rows.first { $0.title == title }
    }

    private func syncConfig(enabled: Bool = true) -> OpenCodeSyncConfig {
        OpenCodeSyncConfig(
            enabled: enabled, hostAlias: "testhost",
            remotePath: "/path/to/opencode.db",
            pollIntervalSeconds: 3600, timeoutSeconds: 60)
    }

    // MARK: - Six states and precedence

    func testCoveredWhenInRangeWithoutIssues() {
        let report = SourceHealth.derive(
            records: [usage("a", source: .codex, hoursAgo: 1)],
            preset: .last24Hours, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Codex")?.state, .covered)
        XCTAssertEqual(row(report, titled: "Codex")?.rangeRecords, 1)
        XCTAssertNil(report.compactHint)
    }

    func testZeroInRangeWithLifetimeRecord() {
        let report = SourceHealth.derive(
            records: [usage("a", source: .claude, hoursAgo: 30 * 24)],
            preset: .last7Days, now: now, calendar: calendar)
        let claude = row(report, titled: "Claude")
        XCTAssertEqual(claude?.state, .zeroInRange)
        XCTAssertEqual(claude?.rangeRecords, 0)
        XCTAssertNotNil(claude?.lastObserved)
        XCTAssertNil(report.compactHint)
    }

    func testMissingWithWarningAndNoRecords() {
        let report = SourceHealth.derive(
            records: [],
            warnings: ["Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT)."],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Codex")?.state, .missing)
        XCTAssertNil(row(report, titled: "Codex")?.lastObserved)
        XCTAssertEqual(report.compactHint, "1 source needs attention - see Details")
    }

    func testUnreadableTakesPrecedenceOverMissingWithNoRecords() {
        let report = SourceHealth.derive(
            records: [],
            warnings: [
                "OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB).",
                "OpenCode database unreadable; others still load.",
            ],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "OpenCode - local")?.state, .unreadable)
    }

    func testPartialWhenIssueCoexistsWithUsableRecords() {
        let report = SourceHealth.derive(
            records: [usage("a", source: .codex, hoursAgo: 1)],
            warnings: ["Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT)."],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Codex")?.state, .partial)
        XCTAssertEqual(report.providersNeedingAttention, 1)
    }

    func testSkippedCounterDegradesToPartial() {
        let report = SourceHealth.derive(
            records: [usage("a", source: .claude, hoursAgo: 1)],
            skippedClaudeLines: 3,
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Claude")?.state, .partial)
    }

    func testSkippedCounterAloneYieldsPartialWithNoRecords() {
        let report = SourceHealth.derive(
            records: [], skippedCodexLines: 2,
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Codex")?.state, .partial)
    }

    func testNoUsageObservedWithoutRecordsOrIssues() {
        let report = SourceHealth.derive(
            records: [], preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Codex")?.state, .noUsageObserved)
        XCTAssertEqual(row(report, titled: "Claude")?.state, .noUsageObserved)
        XCTAssertEqual(row(report, titled: "OpenCode - local")?.state, .noUsageObserved)
        XCTAssertNil(report.compactHint)
    }

    // MARK: - Decision table over sanitized warnings only

    func testDecisionTableCategories() {
        let cases: [(warning: String, title: String, expected: SourceHealthState)] = [
            ("Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT).", "Codex", .missing),
            ("Claude sessions not found (checked default location or TOKENBAR_CLAUDE_ROOT).", "Claude", .missing),
            ("OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB).", "OpenCode - local", .missing),
            ("OpenCode database unreadable; others still load.", "OpenCode - local", .unreadable),
            ("OpenCode database present but SQLite module unavailable in this build.", "OpenCode - local", .unreadable),
            ("OpenCode extra database not found (checked TOKENBAR_OPENCODE_DB_EXTRA).", "Remote inputs", .missing),
            ("OpenCode extra database skipped: SQLite module unavailable in this build.", "Remote inputs", .unreadable),
            ("OpenCode extra database unreadable; others still load.", "Remote inputs", .unreadable),
            ("OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON).", "Remote inputs", .missing),
            ("OpenCode snapshot unreadable; others still load.", "Remote inputs", .unreadable),
            ("OpenCode remote sync cache unreadable; others still load.", "Remote inputs", .unreadable),
        ]
        for item in cases {
            let report = SourceHealth.derive(
                records: [], warnings: [item.warning],
                preset: .lifetime, now: now, calendar: calendar)
            XCTAssertEqual(
                row(report, titled: item.title)?.state, item.expected,
                "warning: \(item.warning)")
        }
    }

    func testExtraFieldsNoticeNeverAltersState() {
        let report = SourceHealth.derive(
            records: [usage("a", source: .opencode, hoursAgo: 1, origin: "local")],
            warnings: ["OpenCode snapshot contained extra non-token fields (ignored)."],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "OpenCode - local")?.state, .covered)
        XCTAssertNil(row(report, titled: "Remote inputs"))
        XCTAssertNil(report.compactHint)
    }

    func testUnknownWarningStaysNoticeOnly() {
        let report = SourceHealth.derive(
            records: [usage("a", source: .codex, hoursAgo: 1)],
            warnings: ["Something unexpected happened on the way to the dashboard."],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Codex")?.state, .covered)
        XCTAssertNil(report.compactHint)
    }

    func testRawStorePathsAreSanitizedBeforeMatching() {
        // Raw Store strings carry absolute paths; derivation sanitizes
        // first, so the mapped group matches the sanitized category while
        // arbitrary prose never maps.
        let report = SourceHealth.derive(
            records: [],
            warnings: ["Codex sessions not found at /tmp/synth/codex-sessions."],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Codex")?.state, .missing)
        let clean = ReportFormatter.sanitizeWarnings(["Codex sessions not found at /tmp/synth/codex-sessions."])
        XCTAssertFalse(clean.joined().contains("/tmp/synth"))
    }

    func testLocalWarningNeverTouchesRemoteRow() {
        let report = SourceHealth.derive(
            records: [],
            warnings: ["OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB)."],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertNil(row(report, titled: "Remote inputs"))
        XCTAssertEqual(report.providersNeedingAttention, 1)
    }

    // MARK: - Cross-source rows and range semantics

    func testRowsRenderRegardlessOfSourceChip() {
        // Derivation takes no source filter: a Codex-only load still
        // yields Codex, OpenCode, and Claude rows.
        let report = SourceHealth.derive(
            records: [usage("a", source: .codex, hoursAgo: 1)],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertNotNil(row(report, titled: "Codex"))
        XCTAssertNotNil(row(report, titled: "Claude"))
        XCTAssertTrue(report.rows.contains { $0.provider == .opencode && !$0.isRemoteInputs })
        XCTAssertEqual(report.rows.first?.title, "Codex")
        XCTAssertEqual(report.rows.last?.title, "Claude")
    }

    func testLastObservedIsLifetimeMaximumIndependentOfRange() {
        let old = usage("old", source: .codex, hoursAgo: 30 * 24)
        let recent = usage("new", source: .codex, hoursAgo: 1)
        let report = SourceHealth.derive(
            records: [old, recent],
            preset: .last24Hours, now: now, calendar: calendar)
        let codex = row(report, titled: "Codex")
        XCTAssertEqual(codex?.lastObserved, recent.timestamp)
        XCTAssertEqual(codex?.rangeRecords, 1)
        XCTAssertEqual(codex?.state, .covered)
    }

    func testBestUsesWinningMonthKey() {
        var aug1 = usage("aug1", source: .codex, hoursAgo: 0)
        aug1.timestamp = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 10))!
        var aug2 = usage("aug2", source: .codex, hoursAgo: 0)
        aug2.timestamp = calendar.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 10))!
        var big = usage("big", source: .claude, hoursAgo: 0, input: 5000, output: 2000)
        big.timestamp = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 10))!
        let records = [aug1, aug2, big]
        let lifetime = Aggregator.filter(records, source: .all, preset: .lifetime, now: now, calendar: calendar)
        let best = Aggregator.bestMonth(lifetime, calendar: calendar)
        XCTAssertEqual(best?.monthKey, "2026-09")
        let report = SourceHealth.derive(
            records: records, preset: .bestMonth, bestMonthKey: best?.monthKey,
            now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "Codex")?.rangeRecords, 0)
        XCTAssertEqual(row(report, titled: "Claude")?.rangeRecords, 1)
        XCTAssertEqual(row(report, titled: "Claude")?.state, .covered)
        XCTAssertEqual(row(report, titled: "Codex")?.state, .zeroInRange)
        // Nil key means zero contributions everywhere.
        let nilKey = SourceHealth.derive(
            records: records, preset: .bestMonth, bestMonthKey: nil,
            now: now, calendar: calendar)
        XCTAssertEqual(row(nilKey, titled: "Claude")?.rangeRecords, 0)
    }

    // MARK: - OpenCode origin groups

    func testDistinctCustomLabelsNeverMerge() {
        let records = [
            usage("l", source: .opencode, hoursAgo: 1, origin: "local", input: 100, output: 50),
            usage("r", source: .opencode, hoursAgo: 2, origin: "remote", input: 200, output: 100),
            usage("o", source: .opencode, hoursAgo: 3, origin: "office", input: 400, output: 100),
            usage("p", source: .opencode, hoursAgo: 4, origin: "laptop", input: 40, output: 10),
        ]
        let report = SourceHealth.derive(
            records: records, preset: .lifetime, now: now, calendar: calendar)
        let origins = report.rows.filter { $0.provider == .opencode && !$0.isRemoteInputs }
        XCTAssertEqual(origins.map(\.origin), ["office", "remote", "local", "laptop"])
        XCTAssertEqual(origins.map(\.title), ["OpenCode - office", "OpenCode - remote", "OpenCode - local", "OpenCode - laptop"])
        // Sole origins are still named explicitly (see single-origin test).
    }

    func testSoleOriginNamedExplicitly() {
        let report = SourceHealth.derive(
            records: [usage("l", source: .opencode, hoursAgo: 1, origin: "local")],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "OpenCode - local")?.state, .covered)
    }

    func testUnsafeAndOverlongLabelsFallBackToRemote() {
        let long = String(repeating: "x", count: 65)
        let records = [
            usage("u", source: .opencode, hoursAgo: 1, origin: "evil; rm -rf ~"),
            usage("o", source: .opencode, hoursAgo: 2, origin: long),
        ]
        let report = SourceHealth.derive(
            records: records, preset: .lifetime, now: now, calendar: calendar)
        let origins = report.rows.filter { $0.provider == .opencode && !$0.isRemoteInputs }
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins.first?.origin, "remote")
        XCTAssertEqual(origins.first?.state, .covered)
    }

    func testProviderSkippedCountDegradesOriginsWithoutAttribution() {
        let records = [
            usage("l", source: .opencode, hoursAgo: 1, origin: "local"),
            usage("r", source: .opencode, hoursAgo: 2, origin: "remote"),
        ]
        let report = SourceHealth.derive(
            records: records, skippedOpenCodeRows: 4,
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "OpenCode - local")?.state, .partial)
        XCTAssertEqual(row(report, titled: "OpenCode - remote")?.state, .partial)
        XCTAssertNil(row(report, titled: "Remote inputs"))
        XCTAssertEqual(report.providersNeedingAttention, 1)
    }

    func testLocalIssueMapsOnlyToLocalRow() {
        let records = [
            usage("l", source: .opencode, hoursAgo: 1, origin: "local"),
            usage("r", source: .opencode, hoursAgo: 2, origin: "remote"),
        ]
        let report = SourceHealth.derive(
            records: records,
            warnings: ["OpenCode database unreadable; others still load."],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(row(report, titled: "OpenCode - local")?.state, .partial)
        XCTAssertEqual(row(report, titled: "OpenCode - remote")?.state, .covered)
    }

    func testEmptyOpenCodeRendersSingleLocalPlaceholder() {
        let report = SourceHealth.derive(
            records: [], preset: .lifetime, now: now, calendar: calendar)
        let origins = report.rows.filter { $0.provider == .opencode && !$0.isRemoteInputs }
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins.first?.title, "OpenCode - local")
    }

    func testHealthFixtureOriginsStayUnmerged() throws {
        let url = repoRoot.appendingPathComponent("Fixtures/synthetic-source-health-snapshot.json")
        let loaded = try OpenCodeStore.loadSnapshot(at: url.path)
        XCTAssertEqual(loaded.records.count, 6)
        let report = SourceHealth.derive(
            records: loaded.records, preset: .lifetime, now: now, calendar: calendar)
        let titles = Set(report.rows.map(\.title))
        XCTAssertTrue(titles.contains("OpenCode - local"))
        XCTAssertTrue(titles.contains("OpenCode - office"))
        XCTAssertTrue(titles.contains("OpenCode - laptop"))
        XCTAssertTrue(titles.contains("OpenCode - homeserver"))
        // The unsafe label sanitizes to the shared remote fallback and
        // merges with the default remote row, never a guessed custom label.
        XCTAssertTrue(titles.contains("OpenCode - remote"))
        XCTAssertFalse(titles.contains(where: { $0.contains("evil") }))
    }

    // MARK: - Sync freshness on the generic remote row only

    func testSyncDisabledWithNoCacheStaysSilent() {
        let report = SourceHealth.derive(
            records: [usage("a", source: .codex, hoursAgo: 1)],
            preset: .lifetime, now: now, calendar: calendar,
            syncConfig: syncConfig(enabled: false),
            syncStatus: OpenCodeSyncStatus())
        XCTAssertNil(row(report, titled: "Remote inputs"))
        XCTAssertNil(report.compactHint)
    }

    func testNeverSyncedIsDistinctFromStale() {
        let report = SourceHealth.derive(
            records: [], preset: .lifetime, now: now, calendar: calendar,
            syncConfig: syncConfig(),
            syncStatus: OpenCodeSyncStatus())
        let remote = row(report, titled: "Remote inputs")
        XCTAssertNotNil(remote)
        XCTAssertEqual(remote?.sync?.freshness, .neverSynced)
        XCTAssertNotEqual(remote?.sync?.freshness, .stale)
        XCTAssertEqual(report.compactHint, "1 source needs attention - see Details")
    }

    func testStaleAfterIntervalPlusTimeout() {
        let status = OpenCodeSyncStatus(
            lastSuccessAt: now.addingTimeInterval(-7200), lastAttemptAt: now)
        let report = SourceHealth.derive(
            records: [], preset: .lifetime, now: now, calendar: calendar,
            syncConfig: syncConfig(), syncStatus: status)
        XCTAssertEqual(row(report, titled: "Remote inputs")?.sync?.freshness, .stale)
    }

    func testFreshSyncNeedsNoAttention() {
        let status = OpenCodeSyncStatus(
            lastSuccessAt: now.addingTimeInterval(-600), lastAttemptAt: now)
        let report = SourceHealth.derive(
            records: [], preset: .lifetime, now: now, calendar: calendar,
            syncConfig: syncConfig(), syncStatus: status)
        XCTAssertEqual(row(report, titled: "Remote inputs")?.sync?.freshness, .fresh)
        XCTAssertNil(report.compactHint)
    }

    func testFailedKeptCacheIsDistinctError() {
        let status = OpenCodeSyncStatus(
            lastSuccessAt: now.addingTimeInterval(-600),
            lastAttemptAt: now,
            lastError: "Remote pull failed; last good pull kept.")
        let report = SourceHealth.derive(
            records: [], preset: .lifetime, now: now, calendar: calendar,
            syncConfig: syncConfig(), syncStatus: status)
        let remote = row(report, titled: "Remote inputs")
        let freshness = remote?.sync?.freshness
        XCTAssertNotNil(freshness)
        if let freshness, case .failedKeptCache(let message) = freshness {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("expected failedKeptCache, got \(String(describing: freshness))")
        }
        XCTAssertEqual(report.compactHint, "1 source needs attention - see Details")
    }

    func testFailedKeptCacheWinsOverStaleWindow() {
        let status = OpenCodeSyncStatus(
            lastSuccessAt: now.addingTimeInterval(-7200),
            lastAttemptAt: now,
            lastError: "Remote pull failed; last good pull kept.")
        let report = SourceHealth.derive(
            records: [], preset: .lifetime, now: now, calendar: calendar,
            syncConfig: syncConfig(), syncStatus: status)
        let remote = row(report, titled: "Remote inputs")
        let freshness = remote?.sync?.freshness
        XCTAssertNotNil(freshness)
        if let freshness, case .failedKeptCache(let message) = freshness {
            XCTAssertEqual(message, "Remote pull failed; last good pull kept.")
        } else {
            XCTFail("expected failedKeptCache, got \(String(describing: freshness))")
        }
        XCTAssertEqual(report.compactHint, "1 source needs attention - see Details")
    }

    func testSyncFreshnessNeverUnderCustomOrigin() {
        let records = [usage("o", source: .opencode, hoursAgo: 1, origin: "office")]
        let status = OpenCodeSyncStatus(
            lastSuccessAt: now.addingTimeInterval(-7200), lastAttemptAt: now)
        let report = SourceHealth.derive(
            records: records, preset: .lifetime, now: now, calendar: calendar,
            syncConfig: syncConfig(), syncStatus: status)
        XCTAssertNil(row(report, titled: "OpenCode - office")?.sync)
        XCTAssertEqual(row(report, titled: "Remote inputs")?.sync?.freshness, .stale)
    }

    // MARK: - Compact hint counts unique providers once

    func testHintCountsProvidersOnce() {
        let report = SourceHealth.derive(
            records: [],
            warnings: [
                "Codex sessions not found (checked default location or TOKENBAR_CODEX_ROOT).",
                "Claude sessions not found (checked default location or TOKENBAR_CLAUDE_ROOT).",
            ],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(report.providersNeedingAttention, 2)
        XCTAssertEqual(report.compactHint, "2 sources need attention - see Details")
    }

    func testLocalPlusRemoteCountOnceUnderOpenCode() {
        let report = SourceHealth.derive(
            records: [],
            warnings: [
                "OpenCode database not found (checked default location or TOKENBAR_OPENCODE_DB).",
                "OpenCode usage snapshot not found (checked TOKENBAR_OPENCODE_USAGE_JSON).",
            ],
            preset: .lifetime, now: now, calendar: calendar)
        XCTAssertEqual(report.providersNeedingAttention, 1)
        XCTAssertEqual(report.compactHint, "1 source needs attention - see Details")
    }

    // MARK: - Snapshot threading

    func testSnapshotThreadsHealthWithNoExtraScans() {
        let records = [usage("a", source: .codex, hoursAgo: 1)]
        let dash = DashboardSnapshot.make(
            records: records, source: .all, preset: .last24Hours, now: now,
            snapshot: nil, calendar: calendar,
            warnings: ["Claude sessions not found (checked default location or TOKENBAR_CLAUDE_ROOT)."])
        XCTAssertEqual(dash.health.rows.first?.title, "Codex")
        XCTAssertEqual(dash.health.rows.last?.title, "Claude")
        // Token math unchanged: health is additive only.
        XCTAssertEqual(dash.stats.totalTokens, 150)
        XCTAssertEqual(dash.health.providersNeedingAttention, 1)
    }

    func testSnapshotBestThreadsMonthKeyIntoHealth() {
        var inBest = usage("b", source: .codex, hoursAgo: 0, input: 1000, output: 500)
        inBest.timestamp = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 10))!
        var outside = usage("o", source: .codex, hoursAgo: 0, input: 100, output: 50)
        outside.timestamp = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 10))!
        let records = [inBest, outside]
        let dash = DashboardSnapshot.make(
            records: records, source: .all, preset: .bestMonth, now: now,
            snapshot: nil, calendar: calendar)
        XCTAssertEqual(dash.bestMonthKey, "2026-09")
        let codex = dash.health.rows.first { $0.title == "Codex" }
        XCTAssertEqual(codex?.rangeRecords, 1)
        XCTAssertEqual(codex?.rangeTokens, 1500)
        XCTAssertEqual(codex?.lastObserved, inBest.timestamp)
    }
}
