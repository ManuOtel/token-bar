import Foundation
import SwiftUI
import TokenBarCore
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Minimal seam around the system login-item API so the controller stays
/// testable and degrades gracefully when unbundled (`swift run`).
protocol LoginItemStoring {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

/// Production store backed by `SMAppService.mainApp` on macOS 13+.
/// Falls back to "unavailable" on older systems.
struct SystemLoginItemStore: LoginItemStoring {
    var isRegistered: Bool {
#if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
#endif
        return false
    }

    func register() throws {
#if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.register()
            return
        }
#endif
        throw LoginItemError.unavailable
    }

    func unregister() throws {
#if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.unregister()
            return
        }
#endif
        throw LoginItemError.unavailable
    }
}

enum LoginItemError: Error, LocalizedError {
    case unavailable
    case needsBundledApp
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Launch at login unavailable on this macOS version."
        case .needsBundledApp:
            return "Dev run (unbundled): launch at login needs TokenBar.app in Applications."
        case .underlying(let message):
            // Sanitized: never surface raw system paths.
            return ReportFormatter.sanitizeWarning(message)
        }
    }
}

/// Observable controller for the dashboard Toggle.
///
/// - When running via `swift run` (no `.app` bundle) the toggle is disabled
///   and shows dev-run copy; no system call is attempted.
/// - When bundled, toggling calls `SMAppService.mainApp` register/unregister
///   and surfaces a sanitized error on failure.
final class LaunchAtLoginController: ObservableObject {
    @Published var isEnabled = false
    @Published var errorMessage: String?

    let isBundled: Bool
    let isAvailable: Bool
    private let store: LoginItemStoring

    var statusMessage: String {
        LaunchAtLoginPolicy.statusMessage(
            isBundled: isBundled, isEnabled: isEnabled, isAvailable: isAvailable)
    }

    var helpText: String {
        LaunchAtLoginPolicy.helpText(isBundled: isBundled, isAvailable: isAvailable)
    }

    init(
        store: LoginItemStoring = SystemLoginItemStore(),
        bundle: Bundle = .main
    ) {
        self.store = store
        self.isBundled = LaunchAtLoginPolicy.isBundled(
            bundleIdentifier: bundle.bundleIdentifier,
            bundlePathExtension: bundle.bundleURL.pathExtension)
#if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            self.isAvailable = true
        } else {
            self.isAvailable = false
        }
#else
        self.isAvailable = false
#endif
        refresh()
    }

    /// Test/design-preview init with explicit flags.
    init(bundled: Bool, available: Bool, store: LoginItemStoring) {
        self.isBundled = bundled
        self.isAvailable = available
        self.store = store
        refresh()
    }

    func refresh() {
        guard isBundled, isAvailable else {
            isEnabled = false
            return
        }
        isEnabled = store.isRegistered
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        guard isAvailable else {
            isEnabled = false
            errorMessage = LoginItemError.unavailable.errorDescription
            return
        }
        guard isBundled else {
            isEnabled = false
            errorMessage = LoginItemError.needsBundledApp.errorDescription
            return
        }
        do {
            if enabled {
                try store.register()
            } else {
                try store.unregister()
            }
            isEnabled = store.isRegistered
        } catch let error as LoginItemError {
            isEnabled = store.isRegistered
            errorMessage = error.errorDescription
        } catch {
            isEnabled = store.isRegistered
            errorMessage = ReportFormatter.sanitizeWarning(error.localizedDescription)
        }
    }
}
