import SwiftUI

struct GameSupportView: View {
    let prefix: WinePrefix
    @State private var diagnostics: GameLaunchDiagnostics?
    @State private var page = 0

    var body: some View {
        VStack {
            Picker("Game support", selection: $page) {
                Text("Launch help").tag(0)
                Text("Saved games").tag(1)
            }.pickerStyle(.segmented).padding()
            if page == 1 {
                GameSavesView(prefix: prefix, backupRoot: SupportPaths.support.appending(path: "save-snapshots"))
            } else if let diagnostics {
                ScrollView {
                    GameLaunchDiagnosticsView(diagnostics: diagnostics, performAction: perform)
                }
                Button("Refresh") { refresh() }.buttonStyle(.bordered).padding()
            } else { ProgressView().padding() }
        }
        .frame(minWidth: 600, minHeight: 480)
        .task { refresh() }
    }

    private func refresh() {
        let log = PrefixLog.launch.url(for: prefix)
        diagnostics = GameLaunchDiagnostics.load(appID: prefix.appID, logURL: log,
                                                 wineLogURL: PrefixLog.wine.url(for: prefix))
    }

    private func perform(_ action: GameLaunchDiagnostics.Action) async throws {
        switch action {
        case .revealLog(let url):
            if let log = PrefixLog.allCases.first(where: { $0.url(for: prefix) == url }) {
                PrefixTools.open(log, for: prefix)
            }
        case .reviewEnvironmentRepair(let url):
            guard NSWorkspace.shared.open(url) else {
                throw StepFailure(step: "Review environment repair", detail: "NotProton could not open the repair request.")
            }
        case .installRuntime(let verb):
            guard !PrefixStore.isInUse(prefix) else { throw ProfileError.inUse("Quit the game before installing components.") }
            _ = try await PrefixTools.winetricks([verb], in: prefix)
        case .retry:
            guard !PrefixStore.isInUse(prefix) else { throw ProfileError.inUse("Close the running game before trying again.") }
            guard GameLaunchDiagnostics.repairURL(appID: prefix.appID) != nil,
                  let url = URL(string: "steam://rungameid/\(prefix.appID)"),
                  NSWorkspace.shared.open(url) else {
                throw StepFailure(step: "Retry launch", detail: "Steam could not accept the launch request.")
            }
        }
        refresh()
    }
}
