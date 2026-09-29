import Foundation
import XCTest
@testable import TokenBarCore

/// Persisted dashboard selection (Source + Range): simple UserDefaults
/// strings only, restored across restarts.
///
/// Pins first-run defaults, unknown/missing fallback, round-trip of every
/// valid value, key stability (renaming would orphan selections), and that
/// defaults track the existing dashboard contracts (source order head and
/// default preset). Chart style persistence stays pinned in
/// `ChartStyleTests`. All values synthetic; no file access, no network.
final class DashboardSelectionTests: XCTestCase {
    func testDefaultsPreserveExistingFirstRunBehavior() {
        XCTAssertEqual(DashboardSelection.defaultSource, .all)
        XCTAssertEqual(DashboardSelection.defaultPreset, .last7Days)
        XCTAssertEqual(DashboardSelection.defaultPreset, DashboardSnapshot.defaultPreset)
    }

    func testDefaultSourceMatchesSourceOrderHead() {
        XCTAssertEqual(DashboardSelection.defaultSource, DashboardSnapshot.sourceOrder.first)
        XCTAssertEqual(DashboardSnapshot.sourceOrder, [.all, .codex, .opencode, .claude])
    }

    func testMissingValuesFallBackToDefaults() {
        XCTAssertEqual(DashboardSelection.source(storedRawValue: nil), .all)
        XCTAssertEqual(DashboardSelection.preset(storedRawValue: nil), DashboardSnapshot.defaultPreset)
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        for raw in ["heatmap", "ALL", "", "all ", "last-7-days", "lifetime\n", "unknown"] {
            XCTAssertEqual(DashboardSelection.source(storedRawValue: raw), .all, "source raw: \(raw)")
        }
        for raw in ["heatmap", "LAST7DAYS", "", "last7Days ", "7d", "unknown"] {
            XCTAssertEqual(
                DashboardSelection.preset(storedRawValue: raw),
                DashboardSnapshot.defaultPreset, "preset raw: \(raw)")
        }
    }

    func testStoredValuesRoundTrip() {
        for filter in SourceFilter.allCases {
            XCTAssertEqual(DashboardSelection.source(storedRawValue: filter.rawValue), filter, "\(filter)")
        }
        for preset in DatePreset.allCases {
            XCTAssertEqual(DashboardSelection.preset(storedRawValue: preset.rawValue), preset, "\(preset)")
        }
        XCTAssertEqual(Set(SourceFilter.allCases.map(\.rawValue)), ["all", "codex", "opencode", "claude"])
        XCTAssertEqual(
            Set(DatePreset.allCases.map(\.rawValue)),
            ["today", "last24Hours", "last7Days", "last30Days", "bestMonth", "lifetime"])
    }

    func testStorageKeysAreStable() {
        // Single user-default key per selection; renaming either would
        // orphan persisted Source/Range picks.
        XCTAssertEqual(DashboardSelection.sourceStorageKey, "selectedSource")
        XCTAssertEqual(DashboardSelection.presetStorageKey, "selectedPreset")
        XCTAssertNotEqual(DashboardSelection.sourceStorageKey, DashboardSelection.presetStorageKey)
        XCTAssertNotEqual(DashboardSelection.sourceStorageKey, ChartStyle.storageKey)
        XCTAssertNotEqual(DashboardSelection.presetStorageKey, ChartStyle.storageKey)
    }

    func testResetReturnsToDefaults() {
        // Model a stored non-default value, then an explicit reset to the
        // default raw value; the result must read back as the default.
        for filter in SourceFilter.allCases where filter != .all {
            XCTAssertEqual(DashboardSelection.source(storedRawValue: filter.rawValue), filter)
            XCTAssertEqual(
                DashboardSelection.source(storedRawValue: DashboardSelection.defaultSource.rawValue), .all)
        }
        for preset in DatePreset.allCases where preset != DashboardSnapshot.defaultPreset {
            XCTAssertEqual(DashboardSelection.preset(storedRawValue: preset.rawValue), preset)
            XCTAssertEqual(
                DashboardSelection.preset(storedRawValue: DashboardSelection.defaultPreset.rawValue),
                DashboardSnapshot.defaultPreset)
        }
    }
}
