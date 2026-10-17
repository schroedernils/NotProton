import AppKit
import Combine
import Foundation
import Observation

/// Retain once at app scope. Call start() once after app launch; Settings should
/// use this health instance and remove its duplicate lifecycle/defaults observers.
@MainActor @Observable
final class SteamIntegrationLifecycle {
    let health: SteamIntegrationHealthModel
    private(set) var shortcutsBusy = false
    private(set) var shortcutsError: String?
    private(set) var shortcutResult: SteamGameShortcutSync.Result?
    @ObservationIgnored private let shortcuts: SteamGameShortcutSync
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    private var checksEnabled = true
    private var shortcutsEnabled = false

    init(health: SteamIntegrationHealthModel, shortcuts: SteamGameShortcutSync = SteamGameShortcutSync(),
         defaults: UserDefaults = .standard) {
        self.health = health
        self.shortcuts = shortcuts
        self.defaults = defaults
    }

    func start() async {
        guard observations.isEmpty else { return }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshAutomatically() }
            }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .filter { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return false }
                return app.executableURL?.lastPathComponent == "steam_osx"
                    || app.bundleIdentifier == "com.valvesoftware.steam"
            }.sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshAutomatically() }
            }.store(in: &observations)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.onSettingsChanged() }
            }.store(in: &observations)
        await refreshAutomatically()
    }

    private func refreshAutomatically() async {
        readSettings()
        if checksEnabled { await health.refresh() }
        if shortcutsEnabled { await refreshShortcuts() }
    }

    func onSettingsChanged() async {
        let oldChecks = checksEnabled, oldShortcuts = shortcutsEnabled
        readSettings()
        if checksEnabled && !oldChecks { await health.refresh() }
        if shortcutsEnabled && !oldShortcuts { await refreshShortcuts() }
    }

    /// Also available for an explicit Settings button, regardless of auto-sync.
    func refreshShortcuts() async {
        guard !shortcutsBusy else { return }
        shortcutsBusy = true
        shortcutsError = nil
        defer { shortcutsBusy = false }
        do { shortcutResult = try await shortcuts.sync() }
        catch { shortcutsError = error.localizedDescription }
    }

    private func readSettings() {
        checksEnabled = defaults.object(forKey: "checkSteamIntegration") as? Bool ?? true
        shortcutsEnabled = defaults.object(forKey: "syncGameShortcuts") as? Bool ?? false
    }
}
