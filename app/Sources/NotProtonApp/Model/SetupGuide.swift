import Foundation

struct SetupGuide {
    let requirementsReady: Bool
    let integrationReady: Bool
    let runtimeReady: Bool

    var isReady: Bool { requirementsReady && integrationReady && runtimeReady }

    init(_ snapshot: StatusSnapshot) {
        let hasRuntime = !snapshot.runner.builds.isEmpty
        let hasSource = snapshot.crossOver.contains {
            $0.isUsable && snapshot.crossOverLicense[$0.id]?.licensed == true
        }
        requirementsReady = snapshot.steam != .steamMissing && (hasRuntime || hasSource)
        if case .installed = snapshot.steam {
            integrationReady = snapshot.payload.isSteamComplete && snapshot.installContent == .current
        } else {
            integrationReady = false
        }
        runtimeReady = hasRuntime && snapshot.payload.isComplete
    }
}
