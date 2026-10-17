import SwiftUI

/// Parent owns lifecycle tasks, authorization, and the existing update UI.
struct SteamIntegrationHealthView: View {
    let snapshot: SteamIntegrationHealth.Snapshot?
    let isBusy: Bool
    var error: String? = nil
    let onCheck: () -> Void
    let onRecoverIntegration: () -> Void
    let onUpdateNotProton: () -> Void
    let onSetupIntegration: () -> Void

    var body: some View {
        GroupBox("Steam integration") {
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot {
                    Text(title(snapshot.status)).font(.headline)
                    Text(purpose(snapshot.status))
                    switch snapshot.action {
                    case .recoverIntegration: Button("Recover integration", action: onRecoverIntegration)
                    case .updateNotProton: Button("Update NotProton", action: onUpdateNotProton)
                    case .setupIntegration: Button("Set up Steam", action: onSetupIntegration)
                    case .none: Button("Check again", action: onCheck)
                    }
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snapshot.detail)
                            if let layout = snapshot.layout { Text("Verified layout: \(layout)") }
                            Text("Steam build from exact disk hashes: \(snapshot.verifiedDiskBuild ?? "Unknown")")
                            if let client = snapshot.clientPath { Text(client.path).font(.caption).textSelection(.enabled) }
                            Text("Verified deployed dylib version: \(snapshot.verifiedDeployedVersion ?? "Unknown")")
                            Text("Deployed NotProton record: \(snapshot.recordedDeploymentVersion ?? "Unknown")")
                            if let hash = snapshot.deployedDylibSHA256 {
                                Text("Deployed dylib SHA-256: \(hash)").font(.caption).textSelection(.enabled)
                            }
                            if let build = snapshot.lastLaunchedBuild {
                                Text("Last logged Steam build: \(build.value)")
                                Text(build.context).font(.caption).textSelection(.enabled)
                            } else { Text("Last logged Steam build: Unknown") }
                            if let loaded = snapshot.lastLoadedDylib {
                                Text("Last logged dylib version: \(loaded.value)")
                                Text(loaded.context).font(.caption).textSelection(.enabled)
                            } else { Text("Last logged dylib version: Unknown") }
                            if let version = snapshot.currentProcessDylibVersion, let executable = snapshot.currentProcessPath {
                                Text("Current Steam process logged dylib version: \(version)")
                                Text(executable.path).font(.caption).textSelection(.enabled)
                            } else { Text("Current process dylib version: Unknown").font(.caption) }
                            Text("Last-log entries are historical. Current-process evidence requires a matching executable path, PID and launch time; loaded image hashes are not verified.").font(.caption)
                            ForEach(Array(snapshot.differences.enumerated()), id: \.offset) { _, difference in
                                Text(difference).font(.caption)
                            }
                        }.font(.caption).textSelection(.enabled)
                    }
                } else {
                    Text("Steam integration has not been checked.")
                    Button("Check Steam integration", action: onCheck)
                }
                if isBusy { ProgressView() }
                if let error {
                    Text("Recovery could not finish. Please try again.").foregroundStyle(.red)
                    DisclosureGroup("Details") { Text(error).font(.caption).textSelection(.enabled) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.bordered).disabled(isBusy)
    }

    private func purpose(_ status: SteamIntegrationHealth.Status) -> String {
        switch status {
        case .steamMissing: "Choose your Steam app to connect it to NotProton."
        case .needsSetup: "Set up the connection so you can use NotProton with Steam again."
        case .unknownLayout: "This Steam update has not been checked with this version of NotProton."
        case .current: "The files that connect Steam to NotProton are ready."
        case .recoveryNeeded: "Restore the connection to Steam. Quit Steam first; your current files will be backed up."
        case .unavailable: "Check again to see whether the connection needs attention."
        }
    }

    private func title(_ status: SteamIntegrationHealth.Status) -> String {
        switch status {
        case .steamMissing: "Steam not found"
        case .unknownLayout: "A NotProton update may be needed"
        case .needsSetup: "Reconnect Steam"
        case .current: "Integration files are current"
        case .recoveryNeeded: "Integration needs attention"
        case .unavailable: "Integration could not be checked"
        }
    }
}
