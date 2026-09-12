import Foundation
import TokenBarCore

/// Observable wrapper around `PricingService` for the menu-bar popover.
///
/// - Startup is offline: the last cached catalog loads from disk, no network.
/// - Refresh is strictly user-initiated (the "Update pricing" button) and
///   runs in a cancellable `Task` so the popover never blocks; starting a
///   second refresh cancels the first. Published state always hops back to
///   the main actor, so usage loading (and the UI thread) never blocks.
/// - Usage loading is independent: pricing success, failure, or cancellation
///   never touches the usage `report`, it only changes the cost basis and
///   the status line.
final class PricingController: ObservableObject {
    @Published private(set) var snapshot: CatalogSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusLine: String = "Pricing: static estimates."
    @Published private(set) var lastError: String?

    private let service: PricingService
    private var refreshTask: Task<Void, Never>?

    init(service: PricingService = PricingService()) {
        self.service = service
        if let cached = service.loadCachedCatalog() {
            snapshot = cached
            statusLine = Self.line(for: cached, error: nil)
        }
    }

    /// User-initiated bounded refresh. Cancels any in-flight refresh first.
    /// Called from button actions (main thread); the fetch runs off-main
    /// and published updates hop back via `MainActor.run`.
    func refresh() {
        refreshTask?.cancel()
        isRefreshing = true
        lastError = nil
        refreshTask = Task {
            let result = await service.refresh()
            await MainActor.run {
                guard !Task.isCancelled else {
                    isRefreshing = false
                    return
                }
                if let fresh = result.snapshot {
                    snapshot = fresh
                }
                lastError = result.error
                statusLine = Self.line(for: result.snapshot ?? snapshot, error: result.error)
                isRefreshing = false
            }
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private static func line(for snapshot: CatalogSnapshot?, error: String?) -> String {
        "Pricing: " + ReportFormatter.pricingNote(snapshot: snapshot, error: error)
    }
}
