import SwiftUI

struct SettingsView: View {
    @Environment(SystemStatus.self) private var status
    @Binding var showGuide: Bool
    private var ready: Bool { status.snapshot.map { SetupGuide($0).isReady } ?? false }

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
                setting(
                    "Steam integration",
                    value: status.snapshot == nil ? "Not checked" : ready ? "Verified" : "Not ready"
                )
                setting(
                    "CrossOver",
                    value: status.snapshot?.crossOver.first(where: \.isUsable)?.releaseVersion
                        ?? "Not detected")
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
