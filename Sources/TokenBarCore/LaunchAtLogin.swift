import Foundation

/// Pure launch-at-login policy. No system calls, no paths, fully testable.
///
/// The App target owns the real `SMAppService` calls (see
/// `Sources/TokenBarApp/LaunchAtLoginController.swift`). This type only
/// decides bundled detection and user-facing copy so the rules stay pinned
/// by `LaunchAtLoginTests` and mirrored by `scripts/verify_logic.py`.
public enum LaunchAtLoginPolicy {
    /// True when running from a real `.app` bundle: a bundle identifier is
    /// present and the bundle path ends in `.app`. `swift run` has no app
    /// bundle, so registration must stay disabled there.
    public static func isBundled(bundleIdentifier: String?, bundlePathExtension: String?) -> Bool {
        guard let id = bundleIdentifier, !id.isEmpty else { return false }
        return bundlePathExtension == "app"
    }

    /// Short status line for the dashboard toggle. Never includes paths.
    public static func statusMessage(isBundled: Bool, isEnabled: Bool, isAvailable: Bool) -> String {
        if !isAvailable {
            return "Launch at login unavailable on this macOS version."
        }
        if !isBundled {
            return "Dev run (unbundled): launch at login needs TokenBar.app in Applications."
        }
        return isEnabled ? "Launch at login: on." : "Launch at login: off."
    }

    /// Helper text under the toggle. Never includes paths.
    public static func helpText(isBundled: Bool, isAvailable: Bool) -> String {
        if !isAvailable {
            return "Requires macOS 13 or later."
        }
        if !isBundled {
            return "Build the app with scripts/build-app.sh, move it to Applications, then toggle."
        }
        return "Starts TokenBar when you log in. Manage also in System Settings under Login Items."
    }
}
