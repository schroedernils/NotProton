// Self-explanatory

import SwiftUI

struct NotProtonApp: App {

    @State private var status = SystemStatus()
    @State private var prefixes = PrefixesModel()
    @State private var pane: Pane = .status
    @State private var prefixRebuildReview: WinePrefix?
    private let updater = AppUpdater()

    init() {
        OnboardingWindowController.shared.captureLaunchDisplay()
        AppLog.start()
    }

    var body: some Scene {
        Window("NotProton", id: "main") {
            RootView(pane: $pane)
                .environment(status)
                .environment(prefixes)
                .frame(minWidth: 720, minHeight: 460)
                .onChange(of: pane) { prefixes.forgetOutcome() }
                .onChange(of: status.snapshot?.installedRunners.map(\.id)) {
                    if prefixes.hasLoaded { Task { await prefixes.load() } }
                }
                .onOpenURL(perform: handleOpenURL)
                .confirmationDialog(
                    "Choose a compatibility tool for \(prefixRebuildReview?.title ?? "this game")",
                    isPresented: isChoosingRebuildTool,
                    titleVisibility: .visible
                ) {
                    if let prefix = prefixRebuildReview {
                        ForEach(prefixes.tools) { tool in
                            Button(tool.display) {
                                prefixRebuildReview = nil
                                prefixes.pendingConfirmation = .rebuild([prefix], tool)
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) { prefixRebuildReview = nil }
                } message: {
                    Text("Choose the installed tool to use. NotProton will ask before rebuilding and offers to keep a backup.")
                }
        }
        .defaultSize(width: 900, height: 760)
        .commands { menus }
    }

    @CommandsBuilder
    private var menus: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.check() }
        }

        CommandGroup(after: .sidebar) {
            Button("Status") { pane = .status }
                .keyboardShortcut("1", modifiers: .command)
            Button("Game environments") { pane = .prefixes }
                .keyboardShortcut("2", modifiers: .command)
            Button("Backups") { pane = .backups }
                .keyboardShortcut("3", modifiers: .command)
            Button("Help") { pane = .help }
                .keyboardShortcut("4", modifiers: .command)

            Divider()

            Button("Refresh") {
                Task {
                    switch pane {
                    case .status, .help, .settings: await status.refresh()
                    case .prefixes, .backups: await prefixes.load()
                    }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(pane == .status || pane == .help || pane == .settings ? !status.isIdle : prefixes.isLoading)

            Divider()
        }

        CommandMenu("Setup") {
            Button("Install") { Task { await status.requestInstall() } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!status.canInstall)

            Button("Set Up Compatibility Tool") { Task { await status.requestCompatibilityTool() } }
                .disabled(!status.canInstall || status.setupSource == nil)

            Button("Fetch Valve Binaries") { Task { await status.fetchValveBinaries() } }
                .disabled(!status.canInstall)

            Divider()

            updateBlockCommand

            Button("Repair Steam") { status.pendingConfirmation = .replaceSteam }
                .disabled(!status.isIdle)

            Divider()

            Button("Reveal Log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppLog.file])
            }
        }

        prefixMenu
    }

    @CommandsBuilder
    private var prefixMenu: some Commands {
        CommandMenu("Prefix") {
            Button("Run Program…") {
                if let prefix = prefixTarget { prefixes.chooseExecutable(for: prefix) }
            }
            .disabled(prefixTarget == nil)

            Divider()

            ForEach(WineTool.allCases, id: \.self) { tool in
                Button(tool.label) {
                    if let prefix = prefixes.selectedPrefix { prefixes.open(tool, for: prefix) }
                }
                .disabled(prefixTarget == nil)
            }

            Divider()

            Button("Reveal in Finder") {
                if let prefix = prefixes.selectedPrefix { prefixes.reveal(prefix) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(prefixes.selectedPrefix == nil)

            Divider()

            Button(PrefixPrompt.backUpButton(selectionTargets)) {
                if !selectionTargets.isEmpty {
                    prefixes.pendingConfirmation = .backUp(selectionTargets)
                }
            }
            .disabled(selectionTargets.isEmpty)

            if prefixes.tools.count > 1 {
                Menu(PrefixPrompt.rebuildButton(selectionTargets)) {
                    ForEach(prefixes.tools) { tool in
                        Button(tool.display) {
                            prefixes.pendingConfirmation = .rebuild(selectionTargets, tool)
                        }
                    }
                }
                .disabled(selectionTargets.isEmpty)
            } else {
                Button(PrefixPrompt.rebuildButton(selectionTargets)) {
                    if let tool = prefixes.tools.first, !selectionTargets.isEmpty {
                        prefixes.pendingConfirmation = .rebuild(selectionTargets, tool)
                    }
                }
                .disabled(selectionTargets.isEmpty || prefixes.tools.isEmpty)
            }

            Button(PrefixPrompt.deleteButton(selectionTargets)) {
                if !selectionTargets.isEmpty {
                    prefixes.pendingConfirmation = .delete(selectionTargets)
                }
            }
            .disabled(selectionTargets.isEmpty)
        }
    }

    private var prefixTarget: WinePrefix? {
        prefixes.isBusy ? nil : prefixes.selectedPrefix
    }

    private var selectionTargets: [WinePrefix] {
        prefixes.isBusy ? [] : prefixes.selectedPrefixes
    }

    private var isChoosingRebuildTool: Binding<Bool> {
        Binding(
            get: { prefixRebuildReview != nil },
            set: { if !$0 { prefixRebuildReview = nil } }
        )
    }

    private func handleOpenURL(_ url: URL) {
        guard let request = PrefixRebuildRequest.parse(url) else { return }
        pane = .prefixes
        prefixRebuildReview = nil
        prefixes.pendingConfirmation = nil
        Task {
            await prefixes.load()
            guard let prefix = prefixes.reviewRebuild(forAppID: request.appID) else { return }
            if prefixes.tools.count == 1, let tool = prefixes.tools.first {
                prefixes.pendingConfirmation = .rebuild([prefix], tool)
            } else {
                prefixRebuildReview = prefix
            }
        }
    }

    @ViewBuilder
    private var updateBlockCommand: some View {
        if status.snapshot?.updateBlocked == true {
            Button("Allow Client Updates") { Task { await status.setUpdateBlock(false) } }
                .disabled(!status.isIdle)
        } else {
            Button("Block Client Updates") { status.pendingConfirmation = .blockUpdates }
                .disabled(!status.isIdle || status.snapshot == nil)
        }
    }
}
