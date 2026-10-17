import SwiftUI

struct SettingsView: View {
    @Environment(SystemStatus.self) private var status
    @Binding var showGuide: Bool
    private var ready: Bool { status.snapshot.map { SetupGuide($0).isReady } ?? false }
    @Environment(SteamIntegrationLifecycle.self) private var integration
    private var health: SteamIntegrationHealthModel { integration.health }
    @AppStorage("checkSteamIntegration") private var checksEnabled = true
    @AppStorage("syncGameShortcuts") private var syncShortcuts = false

    var body: some View {
        ManagementForm {
            if OnboardingCoordinator.canOfferSetup(snapshot: status.snapshot) {
                ManagementSection("Setup") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Install NotProton").font(.system(size: 13, weight: .medium))
                            Text("Check requirements and install the Steam integration.").font(
                                .system(size: 12)
                            ).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open setup") { showGuide = true }.buttonStyle(.bordered).disabled(
                            !status.isIdle)
                    }
                }
            }
            ManagementSection("Installation") {
                Toggle("Check integration after Steam updates", isOn: $checksEnabled)
                SteamIntegrationHealthView(snapshot: health.snapshot, isBusy: health.isBusy,
                    error: health.error, onCheck: { Task { await health.refresh() } },
                    onRecoverIntegration: { Task { await health.recoverIntegration() } },
                    onUpdateNotProton: { AppUpdater().check() },
                    onSetupIntegration: { showGuide = true })
                setting(
                    "Steam integration",
                    value: status.snapshot == nil ? "Not checked" : ready ? "Verified" : "Not ready"
                )
                setting(
                    "CrossOver",
                    value: status.snapshot?.crossOver.first(where: \.isUsable)?.releaseVersion
                        ?? "Not detected")
            }
            ManagementSection("Game shortcuts") {
                Toggle("Keep game shortcuts up to date", isOn: $syncShortcuts)
                Text("Use your installed games from Finder and Spotlight. Existing shortcuts are kept when a game is removed.")
                    .foregroundStyle(.secondary)
                Button("Update game shortcuts") { Task { await integration.refreshShortcuts() } }
                    .buttonStyle(.bordered).disabled(integration.shortcutsBusy)
                if let result = integration.shortcutResult {
                    Text("Updated \(result.applications.count) game shortcuts.").font(.caption)
                    if !result.skippedAppIDs.isEmpty {
                        Text("Skipped \(result.skippedAppIDs.count) games whose name or artwork is unavailable. Existing shortcuts were kept.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = integration.shortcutsError { Text(error).font(.caption) }
            }
            ManagementSection("About") {
                HStack(spacing: 12) {
                    NotProtonIcon().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NotProton").fontWeight(.semibold)
                        Text("Version \(AppVersion.bundled)").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                Link(
                    "View project on GitHub",
                    destination: URL(string: "https://github.com/NotProtonNot/NotProton")!)
            }
        }.font(.system(size: 13))
    }

    private func setting(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
