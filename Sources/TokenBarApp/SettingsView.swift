import SwiftUI
import TokenBarCore

/// Focused settings surface for the menu-bar popover.
///
/// Holds the controls that used to sit at the bottom of the main
/// dashboard: Launch at login, the pricing refresh, and the opt-in
/// remote sync. The main popover stays a compact usage dashboard; this
/// view opens from the gear button in the dashboard header. Sized
/// deliberately small (~300pt) so it reads as a secondary surface, not a
/// second dashboard.
struct SettingsView: View {
    @ObservedObject var loginItem: LaunchAtLoginController
    @ObservedObject var pricing: PricingController
    @ObservedObject var sync: OpenCodeSyncController
    var onSyncNow: () -> Void
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
                // Header action: system glass on macOS 26+, bordered before.
                // Form buttons below stay bordered; glass is a functional
                // layer for header actions only here. See LiquidGlass.swift.
                .liquidGlassHeaderButton()
                .help("Close settings")
                .accessibilityLabel("Close settings")
            }
            loginGroup
            Divider()
            pricingGroup
            Divider()
            syncGroup
        }
        .padding(14)
        .frame(width: 300)
        .preferredColorScheme(.dark)
        // Edited values save on submit, and once more on close: focus loss
        // without Return must not silently drop the host alias or path.
        .onDisappear { sync.saveConfig() }
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

    // MARK: - Remote sync (opt-in SSH pull, off by default)

    private var syncGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("REMOTE SYNC")
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            Toggle(
                "Remote sync",
                isOn: Binding(
                    get: { sync.config.enabled },
                    set: { sync.config.enabled = $0; sync.saveConfig() }
                )
            )
            .accessibilityLabel("Remote sync")
            if sync.config.enabled {
                TextField(
                    "SSH host alias",
                    text: textBinding(\.hostAlias),
                    prompt: Text("SSH host alias (e.g. myserver)")
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { sync.saveConfig() }
                .help("Non-secret SSH host alias from your own ssh config. No passwords or keys are stored.")
                .accessibilityLabel("SSH host alias")
                TextField(
                    "Remote snapshot path",
                    text: textBinding(\.remotePath),
                    prompt: Text("Remote snapshot path")
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { sync.saveConfig() }
                .help("Path of the pre-generated token-only snapshot on the remote host. Leave empty when using a remote exporter command.")
                .accessibilityLabel("Remote snapshot path")
                TextField(
                    "Remote exporter command (optional)",
                    text: textBinding(\.remoteCommand),
                    prompt: Text("Remote exporter command (optional)")
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { sync.saveConfig() }
                .help("Trusted read-only exporter command you wrote yourself. It runs through the remote sshd shell with your remote privileges; local argv safety does not sanitize remote execution. Leave empty to copy the snapshot path instead.")
                .accessibilityLabel("Remote exporter command, optional")
                TextField(
                    "Origin label (optional)",
                    text: textBinding(\.originLabel),
                    prompt: Text("Origin label (optional, e.g. myserver)")
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { sync.saveConfig() }
                .help("Label for rows from this host (letters, digits, ., _, -; max 64). Every origin/host/hostname/label/machine field is scanned: the first explicit distinct label wins (an explicit host beats a default origin); records with no explicit label, or the default remote label in any case, are stored under this label. Legacy homeserver labels are preserved. Blank derives it from the SSH host alias, else remote (note: user@host aliases are valid for SSH but fall back to remote as a label; set an explicit label to keep that name).")
                .accessibilityLabel("Origin label, optional")
                Stepper(
                    "Every \(sync.config.pollIntervalSeconds / 60) min",
                    value: intervalMinutes, in: 5...1440, step: 5
                )
                .font(.caption)
                .help("Background sync interval, 5 minutes to 24 hours")
                .accessibilityLabel("Background sync interval in minutes")
                HStack(spacing: 8) {
                    if sync.isSyncing {
                        ProgressView().scaleEffect(0.7)
                        Text("Syncing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Cancel", action: sync.cancel)
                            .buttonStyle(.bordered)
                            .help("Cancel the in-flight sync")
                    } else {
                        Button("Sync Now") {
                            sync.saveConfig()
                            onSyncNow()
                        }
                        .buttonStyle(.bordered)
                        .help("Pull the remote snapshot now over SSH, then reload usage")
                    }
                    Spacer()
                }
            }
            Text(sync.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func textBinding(_ keyPath: WritableKeyPath<OpenCodeSyncConfig, String>) -> Binding<String> {
        Binding(
            get: { sync.config[keyPath: keyPath] },
            set: { sync.config[keyPath: keyPath] = $0 }
        )
    }

    private var intervalMinutes: Binding<Int> {
        Binding(
            get: { max(5, sync.config.pollIntervalSeconds / 60) },
            set: {
                sync.config.pollIntervalSeconds = min(max($0, 5), 1440) * 60
                sync.saveConfig()
            }
        )
    }
}
