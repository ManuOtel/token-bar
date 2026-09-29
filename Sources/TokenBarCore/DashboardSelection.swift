import Foundation

/// Persisted dashboard selection: the user's most recently selected Source
/// and Range, restored across app restarts.
///
/// Simple UI selection strings in UserDefaults only (read through
/// `AppStorage` in `TokenBarApp`, applied at launch before first render).
/// Persists raw enum values only; never usage records, logs, paths,
/// prompts, or snapshots. No file access, no network, no subprocess; the
/// only writes are the two user-default strings below, one per user change.
///
/// Defaults preserve the existing first-run behavior: Source All (first in
/// `DashboardSnapshot.sourceOrder`) and `DashboardSnapshot.defaultPreset`
/// (rolling last 7 days). A missing or unknown stored string reads back as
/// the default, never a fabricated selection. Reset is explicit only (the
/// caller writes the default raw value); there is no silent migration.
public enum DashboardSelection {
    /// User-default key backing the selected source filter.
    public static let sourceStorageKey = "selectedSource"

    /// User-default key backing the selected range preset.
    public static let presetStorageKey = "selectedPreset"

    /// First-run source selection, and the fallback for missing/unknown
    /// stored values. Matches the first entry of
    /// `DashboardSnapshot.sourceOrder`.
    public static let defaultSource: SourceFilter = .all

    /// First-run range selection, and the fallback for missing/unknown
    /// stored values. Mirrors `DashboardSnapshot.defaultPreset` so the two
    /// can never drift apart.
    public static var defaultPreset: DatePreset { DashboardSnapshot.defaultPreset }

    /// Safe fallback for the persisted source: a missing or unknown string
    /// reads as All, never a fabricated filter.
    public static func source(storedRawValue: String?) -> SourceFilter {
        guard let raw = storedRawValue, let filter = SourceFilter(rawValue: raw) else {
            return defaultSource
        }
        return filter
    }

    /// Safe fallback for the persisted range: a missing or unknown string
    /// reads as the dashboard default preset, never a fabricated range.
    public static func preset(storedRawValue: String?) -> DatePreset {
        guard let raw = storedRawValue, let preset = DatePreset(rawValue: raw) else {
            return defaultPreset
        }
        return preset
    }
}
