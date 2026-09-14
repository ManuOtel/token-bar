import Foundation

/// Shared compact token-count formatter for menu-bar and dashboard display.
///
/// Single unit threshold source so the menu title, source chips/rows, ring
/// legends, model bars, and any other compact count read identically for the
/// same value. Full counts, tooltips, and accessibility values stay exact and
/// are unaffected.
///
/// Contract (locale-independent, `en_US_POSIX` decimal point):
/// - Magnitude below 1,000 renders as the raw integer (`"999"`, `"-42"`).
/// - Otherwise one decimal with trailing `.0` trimmed: `k` (>= 1k),
///   `M` (>= 1M), `B` (>= 1B), `T` (>= 1T, largest unit).
/// - Rounding promotes across boundaries so output never reads `1000.0k`,
///   `1000.0M`, or `1000.0B`: `999_950` renders as `"1M"`, `999_950_000` as
///   `"1B"`, `999_950_000_000` as `"1T"`.
/// - Negative values keep their sign (`-1500` -> `"-1.5k"`). Zero is `"0"`.
/// - Very large `Int` values stay in `T` (for example `Int.max` renders as
///   `"9223372T"`); scaling uses `Double` division only, so no `Int`
///   arithmetic can overflow (`abs(Int.min)` is never computed).
public enum TokenCountFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")

    public static func compact(_ value: Int) -> String {
        let scaled = Double(value)
        if scaled.magnitude < 1_000 {
            return "\(value)"
        }
        var divisor = 1_000.0
        var suffix = "k"
        if scaled.magnitude >= 1_000_000_000_000 {
            divisor = 1_000_000_000_000
            suffix = "T"
        } else if scaled.magnitude >= 1_000_000_000 {
            divisor = 1_000_000_000
            suffix = "B"
        } else if scaled.magnitude >= 1_000_000 {
            divisor = 1_000_000
            suffix = "M"
        }
        // Promote when one-decimal rounding would hit 1000.0 in the current
        // unit (for example 999_950 -> 1M, never 1000.0k). At most three hops.
        for _ in 0..<3 {
            let candidate = scaled / divisor
            let rounded = (candidate * 10).rounded() / 10
            if rounded.magnitude >= 1_000, suffix != "T" {
                switch suffix {
                case "k":
                    divisor = 1_000_000
                    suffix = "M"
                case "M":
                    divisor = 1_000_000_000
                    suffix = "B"
                case "B":
                    divisor = 1_000_000_000_000
                    suffix = "T"
                default:
                    break
                }
                continue
            }
            return format(candidate: candidate, suffix: suffix)
        }
        return format(candidate: scaled / divisor, suffix: suffix)
    }

    private static func format(candidate: Double, suffix: String) -> String {
        let text = String(format: "%.1f%@", locale: posix, candidate, suffix)
        return text.replacingOccurrences(of: ".0" + suffix, with: suffix)
    }
}
