import SwiftUI

struct OnboardingView: View {
    @Bindable var coordinator: OnboardingCoordinator
    @Environment(SystemStatus.self) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var c: OnboardingCoordinator { coordinator }
    private var complete: Bool { [.integrationSucceeded, .completed].contains(c.state) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                introduction.frame(width: 210)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Steam, with CrossOver.").font(
                                .system(size: 22, weight: .semibold)
                            )
                            .accessibilityAddTraits(.isHeader)
                            Text("Connect your macOS Steam client.").foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            requirement(
                                "Steam", url: SupportPaths.Steam.app, fallback: "gamecontroller",
                                detail: "macOS client", state: c.steam
                            ) { c.getSteam() }
                            Divider().padding(.leading, 42)
                            requirement(
                                "CrossOver",
                                url: c.source?.bundle ?? c.snapshot?.crossOver.first?.bundle,
                                fallback: "app.connected.to.app.below.fill",
                                detail: crossOverDetail,
                                state: c.crossOver
                            ) { c.getCrossOver() }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 10) { installation }
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        details
                    }
                    .padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }.frame(maxHeight: .infinity)
            Divider()
            footer.padding(.horizontal, 28).padding(.vertical, 18)
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) {
            _ in c.returnedToApp()
        }
    }

    private var introduction: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            NotProtonIcon().frame(width: 72, height: 72)
            Text("NotProton").font(.system(size: 20, weight: .semibold)).padding(.top, 16)
            Text("Windows games in your\nmacOS Steam library.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineSpacing(3).padding(.top, 8)
            VStack(alignment: .leading, spacing: 20) {
                feature(
                    "Game environments", detail: "Per-game Wine tools", symbol: "externaldrive",
                    color: .blue)
                feature(
                    "Local backups", detail: "Save and rebuild prefixes",
                    symbol: "externaldrive.badge.timemachine", color: .teal)
            }.padding(.top, 36)
            Spacer(minLength: 24)
        }.padding(.horizontal, 24).frame(maxHeight: .infinity)
    }

    private func feature(_ title: String, detail: String, symbol: String, color: Color) -> some View
    {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var crossOverDetail: String {
        if let source = c.source {
            return "Version \(source.releaseVersion ?? "unknown") · activated"
        }
        if let source = c.snapshot?.crossOver.first {
            return "Version \(source.releaseVersion ?? "unknown")"
        }
        return c.crossOver == .ready ? "Installed runtime" : "Activated copy required"
    }

    private func requirement(
        _ name: String, url: URL?, fallback: String, detail: String,
        state: OnboardingCoordinator.Requirement, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            if let url {
                InstalledAppIcon(url: url, fallback: fallback).frame(width: 28, height: 28)
            } else {
                Image(systemName: fallback).font(.title2).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                if case .attention(let reason) = state {
                    Text(reason).font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            switch state {
            case .checking:
                ProgressView().controlSize(.small).accessibilityLabel("Checking \(name)")
            case .ready:
                Label("Ready", systemImage: "checkmark").foregroundStyle(.green).font(
                    .system(size: 12))
            case .attention: Button("Get \(name)", action: action).buttonStyle(.bordered)
            }
        }.padding(.vertical, 12)
    }

    @ViewBuilder private var installation: some View {
        switch c.state {
        case .checkingRequirements, .requirementsReady, .requirementsAttention:
            VStack(alignment: .leading, spacing: 10) {
                Text(c.isVerified ? "Check installed components" : "Install the Steam integration")
                    .fontWeight(.semibold)
                Text(
                    c.isVerified
                        ? "Recheck the integration and CrossOver runtime."
                        : "Adds CrossOver compatibility tools for Windows games."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if c.state == .requirementsAttention {
                    Button("Choose CrossOver…") { c.chooseCrossOver() }.buttonStyle(.bordered)
                } else {
                    Text(
                        c.isVerified
                            ? "Your existing installation will be checked again."
                            : "Quit running games first. Steam may close during installation."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        case .permissionRequired, .permissionReady:
            HStack(alignment: .top, spacing: 12) {
                NotProtonIcon().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 10) {
                    if c.permission == .ready {
                        Label("App Management access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).fontWeight(.medium)
                        Text("Continue to install the integration.").foregroundStyle(.secondary)
                    } else {
                        Text("Allow NotProton to modify Steam").fontWeight(.semibold)
                        Text(
                            "In System Settings → Privacy & Security → App Management, enable NotProton. Then return here."
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            Text("Missing from the list? Add NotProton with +.").font(
                                .system(size: 12)
                            )
                            .foregroundStyle(.secondary)
                            Button("Check again") { c.returnedToApp() }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        case .integrationReady, .integrating, .integrationFailed:
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    c.state == .integrationFailed
                        ? "Installation needs attention" : "Installing NotProton"
                )
                .fontWeight(.semibold)
                if c.state == .integrationFailed {
                    installRow(failedStage, stage: c.integrationStage)
                    Button("Check requirements again") { c.checkRequirements() }.buttonStyle(
                        .bordered)
                } else {
                    installRow("Check apps and write access", stage: .preparing)
                    installRow(
                        status.activity ?? "Install Steam integration and runtime",
                        stage: .installing)
                    installRow("Verify installed components", stage: .verifying)
                }
            }
        case .integrationSucceeded, .completed:
            VStack(alignment: .leading, spacing: 10) {
                Label("Installation verified", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).fontWeight(.semibold)
                Text("Steam → Game properties → Compatibility").fontWeight(.medium)
                Text(
                    "Choose a CrossOver tool for Windows games. Leave compatibility off for native macOS games."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let error = c.error {
            Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private var failedStage: String {
        switch c.integrationStage {
        case .preparing: "Check apps and write access"
        case .installing: "Install Steam integration and runtime"
        case .verifying, .complete: "Verify installed components"
        }
    }

    private func installRow(_ title: String, stage: OnboardingCoordinator.IntegrationStage)
        -> some View
    {
        let done = c.integrationStage.rawValue > stage.rawValue
        let active = c.state == .integrating && c.integrationStage == stage
        return HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else if active {
                    ProgressView().controlSize(.mini)
                } else if c.state == .integrationFailed && c.integrationStage == stage {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: "minus").foregroundStyle(.tertiary)
                }
            }.frame(width: 14)
            Text(title).foregroundStyle(done || active ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).accessibilityElement(children: .combine)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: done)
    }

    private var details: some View {
        DisclosureGroup("Details", isExpanded: $coordinator.detailsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                datum("Supported versions", SupportedRunners.versionList)
                datum("Steam", SupportPaths.Steam.app.path(percentEncoded: false))
                if let source = c.source {
                    datum("CrossOver", source.bundle.path(percentEncoded: false))
                    if case .supported(let build) = source.support {
                        datum(
                            "Runtime profile",
                            "\(build.releaseVersion) · build \(build.bundleVersion)")
                    }
                }
                datum("Runtime storage", SupportPaths.support.path(percentEncoded: false))
                if let snapshot = c.snapshot {
                    datum(
                        "Integration",
                        SetupGuide(snapshot).integrationReady ? "Verified" : "Not installed")
                    datum("Components", snapshot.payload.isComplete ? "Verified" : "Not complete")
                    if !snapshot.payload.missing.isEmpty {
                        datum(
                            "Missing files",
                            snapshot.payload.missing.map {
                                URL(filePath: $0.path).lastPathComponent
                            }.joined(
                                separator: ", "))
                    }
                }
                Text(
                    "Installation prepares a local CrossOver runtime. App Management access is checked by writing a temporary file inside Steam; Accessibility access is not required."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .blocked(let reason) = c.permission {
                    Text(reason).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.font(.system(size: 12)).padding(.top, 8)
        }.disclosureGroupStyle(WholeRowDisclosureStyle()).foregroundStyle(.secondary)
    }

    private func datum(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).foregroundStyle(.secondary).frame(width: 126, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11, design: .monospaced))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if complete {
                Button("Settings") { c.finish(settings: true) }.buttonStyle(.bordered)
            } else if !c.isBusy {
                Button("Not now") { c.finish(settings: false) }.buttonStyle(.bordered)
            }
            Spacer()
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        switch c.state {
        case .checkingRequirements: busy("Checking apps…")
        case .requirementsReady:
            primary(c.isVerified ? "Verify installation" : "Install in Steam") {
                c.continueAfterRequirements()
            }
        case .requirementsAttention: primary("Check again") { c.checkRequirements() }
        case .permissionRequired: primary("Open System Settings") { c.openSystemSettings() }
        case .permissionReady: primary("Continue") { c.continueAfterPermission() }
        case .integrationReady: busy("Preparing…")
        case .integrating: busy("Installing…")
        case .integrationFailed: primary("Try again") { c.startIntegration() }
        case .integrationSucceeded, .completed:
            if c.isOpeningSteam {
                busy("Opening Steam…")
            } else {
                primary("Open Steam") { c.openSteam() }
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: "return").font(.system(size: 11)).opacity(0.7)
                    .accessibilityHidden(true)
            }
        }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .disabled(!status.isIdle && !complete)
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
