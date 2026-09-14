import SwiftUI

/// Focused settings surface for the menu-bar popover.
///
/// Holds the two controls that used to sit at the bottom of the main
/// dashboard: Launch at login and the pricing refresh. The main popover
/// stays a compact usage dashboard; this view opens from the gear button
/// in the dashboard header. Sized deliberately small (~300pt) so it reads
/// as a secondary surface, not a second dashboard.
struct SettingsView: View {
    @ObservedObject var loginItem: LaunchAtLoginController
    @ObservedObject var pricing: PricingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: { dismiss() }) {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.body)
                }
                .buttonStyle(.bordered)
                .help("Close settings")
                .accessibilityLabel("Close settings")
            }
            loginGroup
            Divider()
            pricingGroup
        }
        .padding(14)
        .frame(width: 300)
        .preferredColorScheme(.dark)
    }

    // MARK: - Launch at login (behavior unchanged, moved only)

    private var loginGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GENERAL")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )
            )
            .disabled(!loginItem.isBundled || !loginItem.isAvailable)
            .accessibilityLabel("Launch at login")
            Text(loginItem.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(loginItem.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let error = loginItem.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pricing (behavior unchanged, moved only)

    private var pricingGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PRICING")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                if pricing.isRefreshing {
                    ProgressView().scaleEffect(0.7)
                    Text("Updating pricing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Cancel", action: pricing.cancel)
                        .buttonStyle(.bordered)
                        .help("Cancel the in-flight pricing refresh")
                } else {
                    Button("Update pricing", action: pricing.refresh)
                        .buttonStyle(.bordered)
                        .help("Fetch the public model pricing catalog now (GET only, no usage data sent)")
                }
                Spacer()
            }
            Text(pricing.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let error = pricing.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            // Single canonical cost disclaimer. The main dashboard no longer
            // carries its own footer copy, so this line appears exactly once.
            Text("Costs are estimates, not a bill.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
