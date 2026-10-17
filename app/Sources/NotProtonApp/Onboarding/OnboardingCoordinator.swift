import AppKit
import Observation

@MainActor
struct OnboardingOperations {
    var refresh: () async -> StatusSnapshot?
    var access: () -> SteamWriteAccess.State
    var integrate: (CrossOverInstall?) async -> Void
    var failure: () -> String?
    var openSettings: () -> Void
    var chooseCrossOver: () async -> Void
    var openURL: (URL) -> Void
    var launchSteam: () async throws -> Void
}

@MainActor
func liveOperations(status: SystemStatus) -> OnboardingOperations {
    let access = SteamWriteAccess()
    return OnboardingOperations(
        refresh: {
            await status.refresh()
            return status.snapshot
        },
        access: {
            access.check()
            return access.state
        },
        integrate: { source in
            guard let snapshot = status.snapshot else { return }
            if !SetupGuide(snapshot).integrationReady { await status.requestInstall(from: source) }
            guard status.failure == nil, status.pendingConfirmation == nil else { return }
            if let snapshot = status.snapshot, !SetupGuide(snapshot).runtimeReady {
                if snapshot.runner.builds.isEmpty { await status.requestCompatibilityTool(from: source) }
                if status.failure == nil, let snapshot = status.snapshot,
                    !snapshot.payload.missing(origin: .valve).isEmpty
                {
                    await status.fetchValveBinaries()
                }
            }
        },
        failure: {
            status.failure
                ?? (status.pendingConfirmation == nil ? nil : "Activate CrossOver, then try again.")
        },
        openSettings: { if let pane = Remedy.appManagement.settingsPane { Remedy.openSettings(pane) } },
        chooseCrossOver: { await status.addCrossOver() },
        openURL: { NSWorkspace.shared.open($0) },
        launchSteam: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: SupportPaths.Steam.app, configuration: .init()) {
                    _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        })
}

@MainActor
@Observable
final class OnboardingCoordinator {
    enum State: String, CaseIterable {
        case checkingRequirements, requirementsReady, requirementsAttention
        case permissionReady, permissionRequired, integrationReady, integrating
        case integrationSucceeded, integrationFailed, completed
    }
    enum IntegrationStage: Int { case preparing, installing, verifying, complete }
    enum Requirement: Equatable {
        case checking, ready
        case attention(String)
    }
    private(set) var state: State = .checkingRequirements
    private(set) var integrationStage: IntegrationStage = .preparing
    private(set) var snapshot: StatusSnapshot?
    private(set) var steam: Requirement = .checking
    private(set) var crossOver: Requirement = .checking
    private(set) var permission: SteamWriteAccess.State = .unchecked
    private(set) var includesPermissionStep = false
    private var permissionStepPresented = false
    private(set) var error: String?
    private(set) var isOpeningSteam = false
    var detailsExpanded = false
    var onClose: (_ settings: Bool) -> Void = { _ in }
    @ObservationIgnored private let operations: OnboardingOperations
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var integrationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    static let presentedKey = "onboarding.v3.presented"
    // Migration from the previous first-launch flow. Maintenance never resets these preferences.
    static let introSeenKey = "onboarding.v2.introSeen"
    static let completedKey = "onboarding.v2.completed"

    init(
        snapshot: StatusSnapshot?, operations: OnboardingOperations,
        defaults: UserDefaults = .standard
    ) {
        self.snapshot = snapshot
        self.operations = operations
        self.defaults = defaults
        if let snapshot, snapshot.steam != .steamMissing {
            permission = operations.access()
            includesPermissionStep = permission != .ready
        }
    }
    var source: CrossOverInstall? {
        let available =
            snapshot?.crossOver.filter { $0.isUsable && snapshot?.crossOverLicense[$0.id]?.licensed == true }
            ?? []
        return available.first
    }
    var isBusy: Bool { state == .integrating }
    var isVerified: Bool { snapshot.map { SetupGuide($0).isReady } ?? false }
    static func shouldOpen(snapshot: StatusSnapshot?, defaults: UserDefaults) -> Bool {
        guard snapshot != nil else { return false }
        return !defaults.bool(forKey: presentedKey)
            && !defaults.bool(forKey: completedKey)
            && !defaults.bool(forKey: introSeenKey)
    }
    /// Installation state controls the manual entry point, not first-launch history.
    static func canOfferSetup(snapshot: StatusSnapshot?) -> Bool {
        guard let snapshot else { return false }
        switch snapshot.steam {
        case .steamMissing, .notInstalled: return true
        default: return false
        }
    }
    func start() {
        defaults.set(true, forKey: Self.presentedKey)
        checkRequirements()
    }

    var canGoBack: Bool {
        state == .permissionRequired
    }

    func goBack() {
        guard canGoBack else { return }
        checkTask?.cancel()
        generation += 1
        error = nil
        checkRequirements()
    }

    func checkRequirements() {
        guard !isBusy else { return }
        checkTask?.cancel()
        generation += 1
        let token = generation
        steam = .checking
        crossOver = .checking
        error = nil
        transition(.checkingRequirements)
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await operations.refresh()
            guard !Task.isCancelled, token == generation else { return }
            snapshot = result
            guard let result else {
                steam = .attention("Could not check Steam")
                crossOver = .attention("Could not check CrossOver")
                transition(.requirementsAttention)
                return
            }
            steam = result.steam == .steamMissing ? .attention("Not installed") : .ready
            if steam == .ready {
                permission = operations.access()
                if !permissionStepPresented { includesPermissionStep = permission != .ready }
            }
            let runtimeReady = SetupGuide(result).runtimeReady
            crossOver =
                source != nil || runtimeReady
                ? .ready
                : .attention(
                    result.crossOver.isEmpty ? "Not installed" : "Choose a supported, activated version")
            guard steam == .ready, crossOver == .ready else {
                transition(.requirementsAttention)
                return
            }
            transition(.requirementsReady)
        }
    }
    func continueAfterRequirements() {
        guard state == .requirementsReady, steam == .ready, crossOver == .ready else { return }
        checkPermission()
    }
    private func checkPermission() {
        permission = operations.access()
        if !permissionStepPresented { includesPermissionStep = permission != .ready }
        if includesPermissionStep { permissionStepPresented = true }
        // A grant is reviewed explicitly when this session needed permission.
        // Already authorized users have no permission page or progress mark.
        if permission != .ready {
            transition(.permissionRequired)
        } else if includesPermissionStep {
            transition(.permissionReady)
        } else {
            beginIntegrationAfterChecks()
        }
    }
    private func beginIntegrationAfterChecks() {
        transition(.integrationReady)
        startIntegration()
    }
    func continueAfterPermission() {
        guard state == .permissionReady else { return }
        // Permission may have been revoked while the user reviewed the result.
        permission = operations.access()
        if permission == .ready { beginIntegrationAfterChecks() } else { transition(.permissionRequired) }
    }
    func openSystemSettings() {
        guard state == .permissionRequired else { return }
        operations.openSettings()
        returnedToApp()
    }
    func returnedToApp() {
        switch state {
        case .requirementsAttention: checkRequirements()
        case .permissionRequired, .permissionReady: checkPermission()
        default: break
        }
    }
    func chooseCrossOver() {
        guard !isBusy else { return }
        Task {
            await operations.chooseCrossOver()
            checkRequirements()
        }
    }
    func getSteam() { operations.openURL(URL(string: "https://store.steampowered.com/about/")!) }
    func getCrossOver() { operations.openURL(URL(string: "https://www.codeweavers.com/crossover")!) }

    func startIntegration() {
        guard integrationTask == nil, state == .integrationReady || state == .integrationFailed else {
            return
        }
        // Revalidate before modifying Steam, including after a long Settings visit.
        checkTask?.cancel()
        generation += 1
        integrationStage = .preparing
        transition(.integrating)
        error = nil
        integrationTask = Task { [weak self] in
            guard let self else { return }
            defer { integrationTask = nil }
            snapshot = await operations.refresh()
            guard steamRequirementIsReady else {
                error = "Steam or CrossOver changed. Check your apps again."
                transition(.integrationFailed)
                return
            }
            permission = operations.access()
            guard permission == .ready else {
                includesPermissionStep = true
                permissionStepPresented = true
                transition(.permissionRequired)
                return
            }
            guard !Task.isCancelled else { return }
            integrationStage = .installing
            // An existing setup is checked in full without reinstalling it.
            if !isVerified { await operations.integrate(source) }
            if let failure = operations.failure() {
                error = failure
                transition(.integrationFailed)
                return
            }
            guard !Task.isCancelled else { return }
            integrationStage = .verifying
            snapshot = await operations.refresh()
            guard isVerified else {
                error = "Setup could not be verified. Check the details and try again."
                transition(.integrationFailed)
                return
            }
            guard !Task.isCancelled else { return }
            integrationStage = .complete
            defaults.set(true, forKey: Self.completedKey)
            transition(.integrationSucceeded)
        }
    }
    private var steamRequirementIsReady: Bool {
        guard let snapshot, snapshot.steam != .steamMissing,
            !snapshot.installContent.blocksInstallation
        else { return false }
        return source != nil || !snapshot.runner.builds.isEmpty
    }
    func openSteam() {
        guard state == .integrationSucceeded, isVerified, !isOpeningSteam else { return }
        isOpeningSteam = true
        Task {
            defer { isOpeningSteam = false }
            do {
                try await operations.launchSteam()
                finish(settings: false)
            } catch { self.error = error.localizedDescription }
        }
    }
    func finish(settings: Bool) {
        guard !isBusy else { return }
        if state == .integrationSucceeded, isVerified {
            defaults.set(true, forKey: Self.completedKey)
            transition(.completed)
        }
        suspend()
        onClose(settings)
    }
    func waitForPendingOperations() async {
        await checkTask?.value
        await integrationTask?.value
    }
    func suspend() {
        checkTask?.cancel()
        generation += 1
    }
    private func transition(_ next: State) {
        state = next
        AccessibilityNotification.Announcement(next.accessibilityTitle).post()
    }

}

extension OnboardingCoordinator.State {
    var accessibilityTitle: String {
        switch self {
        case .checkingRequirements, .requirementsReady, .requirementsAttention: "Checking your Mac"
        case .permissionRequired: "One permission needed"
        case .permissionReady: "Permission verified"
        case .integrationReady, .integrating, .integrationFailed: "Set up Steam"
        case .integrationSucceeded: "Integration complete"
        case .completed: "You're ready to play"
        }
    }
}
