import SwiftUI
import UniformTypeIdentifiers

/// Parent integration: WindowsGameImportView() in a sheet or navigation destination.
/// An alternate Steam root can be passed by Settings. This view never starts or stops Steam.
struct WindowsGameImportView: View {
    var steamRoot: URL = SupportPaths.Steam.userData
    @State private var executable: URL?
    @State private var name = ""
    @State private var account = ""
    @State private var tool = ""
    @State private var accounts: [String] = []
    @State private var tools: [InstalledTool] = []
    @State private var choosingFile = false
    @State private var saving = false
    @State private var message: String?
    @State private var failed = false
    @State private var recoveryBackup: URL?
    @State private var reviewingRecovery = false
    @State private var savedBackup: URL?

    var body: some View {
        Form {
            Text("Add a Windows game")
                .font(.title2.bold())
            Text("Choose a game already on your Mac. Your game files and saves stay where they are. Quit Steam and any games before adding it.")
                .foregroundStyle(.secondary)
            HStack {
                Text(executable?.lastPathComponent ?? "No game selected")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Game…") { choosingFile = true }
                    .buttonStyle(.bordered)
            }
            TextField("Game name", text: $name)
            Picker("Steam account", selection: $account) {
                Text("Choose an account").tag("")
                ForEach(accounts, id: \.self) { Text("Steam account \($0)").tag($0) }
            }
            Picker("Run with", selection: $tool) {
                Text("Choose a compatibility tool").tag("")
                ForEach(tools) { Text($0.display).tag($0.name) }
            }
            if tools.isEmpty {
                Text("Set up a compatibility tool in Settings first.")
                    .foregroundStyle(.secondary)
            }
            Button(saving ? "Saving…" : "Add to Steam") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(saving || executable == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tool.isEmpty || account.isEmpty)
            Button("Restore an interrupted import…") { chooseRecovery() }.disabled(account.isEmpty)
            if let message {
                Text(message)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel(message)
            }
            if let savedBackup {
                DisclosureGroup("Details") {
                    Text("Your original Steam settings are backed up here:")
                    Text(savedBackup.path).font(.caption).textSelection(.enabled)
                    Button("Show backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedBackup]) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .frame(minWidth: 420)
        .disabled(saving)
        .onAppear {
            accounts = WindowsGameImport.accounts(steamRoot: steamRoot)
            if accounts.count == 1 { account = accounts[0] }
            tools = CompatToolList.installed().filter { $0.name == "notproton" || $0.name.hasPrefix("notproton-") }
            if tools.count == 1 { tool = tools[0].name }
        }
        .confirmationDialog("Restore the interrupted import?", isPresented: $reviewingRecovery, titleVisibility: .visible) {
            Button("Restore library settings", role: .destructive) { restoreImport() }
            Button("Cancel", role: .cancel) { recoveryBackup = nil }
        } message: {
            Text("Steam must stay closed. Only files still matching the interrupted import can be restored; the backup is kept.")
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data]) { result in
            if case .success(let url) = result {
                executable = url
                name = url.deletingPathExtension().lastPathComponent
                message = nil
            }
        }
    }

    private func chooseRecovery() {
        let panel = NSOpenPanel()
        panel.title = "Choose the interrupted import backup"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = steamRoot.appending(path: "config")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            recoveryBackup = url
            reviewingRecovery = true
        }
    }

    private func restoreImport() {
        guard let backup = recoveryBackup else { return }
        let root = steamRoot, selectedAccount = account
        saving = true; message = nil
        Task {
            defer { saving = false; recoveryBackup = nil }
            do {
                try await Task.detached {
                    try WindowsGameImport.restoreInterruptedImport(backup: backup, steamRoot: root, accountID: selectedAccount)
                }.value
                failed = false
                savedBackup = backup
                message = "The interrupted import was restored. Its backup was kept."
            } catch {
                failed = true
                message = (error as? WindowsGameImport.Failure)?.errorDescription ?? "The import could not be restored. Keep the backup and try again."
            }
        }
    }

    private func save() {
        guard let executable else { return }
        let request = WindowsGameImport.Request(executable: executable, name: name, toolName: tool)
        let root = steamRoot, selectedAccount = account
        saving = true; message = nil
        Task {
            do {
                let result = try await Task.detached {
                    let scoped = executable.startAccessingSecurityScopedResource()
                    defer { if scoped { executable.stopAccessingSecurityScopedResource() } }
                    return try WindowsGameImport.save(request, steamRoot: root, accountID: selectedAccount)
                }.value
                failed = false
                savedBackup = result.backup
                message = result.updated
                    ? "Your Steam entry was updated. Open Steam to check your library and try the game."
                    : "The game entry was saved. Open Steam to check your library and try the game."
            } catch {
                failed = true
                message = (error as? WindowsGameImport.Failure)?.errorDescription ?? "The game could not be added. Try again."
            }
            saving = false
        }
    }
}
