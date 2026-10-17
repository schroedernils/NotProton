import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class GameSavesViewModel {
    private(set) var state = GameSavesAdapter.State()
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var message: String?
    private let adapter: GameSavesAdapter
    private let opener: (URL) -> Bool

    init(prefix: WinePrefix, backupRoot: URL,
         dependencies: GameSavesAdapter.Dependencies = .init(),
         opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        adapter = GameSavesAdapter(prefix: prefix, backupRoot: backupRoot, dependencies: dependencies)
        self.opener = opener
    }

    enum Action {
        case refresh
        case addFolder(URL, candidateRoot: URL?)
        case selectFolder(UUID)
        case create(folderID: UUID, name: String)
        case restore(snapshotID: UUID, folderID: UUID)
        case openFolder(UUID)
    }

    func perform(_ action: Action) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        message = nil
        defer { isBusy = false }
        do {
            switch action {
            case .refresh: state = try await adapter.load()
            case .addFolder(let url, let root): state = try await adapter.addFolder(url, candidateRoot: root)
            case .selectFolder(let id): state = try await adapter.selectFolder(id)
            case .create(let id, let name):
                state = try await adapter.createSnapshot(folderID: id, name: name)
                message = "Snapshot created. Earlier snapshots are preserved."
            case .restore(let id, let folder):
                state = try await adapter.restoreSnapshot(id, folderID: folder)
                message = "Saves restored. Any previous saves were preserved in a Before restore snapshot."
            case .openFolder(let id):
                let url = try await adapter.folderToOpen(id)
                guard opener(url) else { throw GameSaveSnapshots.Failure.refused("The save folder could not be opened.") }
            }
        } catch {
            self.error = error.localizedDescription
            // A snapshot may already be safely published even when saving its display name fails.
            if let fresh = try? await adapter.load() { state = fresh }
        }
    }
}

/// The parent presents this view and owns its button/sheet. No environment model is required.
@MainActor
struct GameSavesView: View {
    private let prefix: WinePrefix
    @State private var model: GameSavesViewModel
    @State private var candidateRoot: URL?
    @State private var snapshotName = "Save snapshot"
    @State private var pendingRestore: GameSavesAdapter.Snapshot?
    @State private var showRestoreConfirmation = false
    @State private var pickerError: String?

    init(prefix: WinePrefix,
         backupRoot: URL = SupportPaths.applicationSupport.appending(path: "saves"),
         dependencies: GameSavesAdapter.Dependencies = .init(),
         opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.prefix = prefix
        _model = State(initialValue: GameSavesViewModel(
            prefix: prefix, backupRoot: backupRoot, dependencies: dependencies, opener: opener))
    }

    private var selectedFolder: GameSavesAdapter.Folder? {
        model.state.folders.first { $0.id == model.state.selectedFolderID }
    }

    private var snapshots: [GameSavesAdapter.Snapshot] {
        model.state.snapshots.filter { $0.folderID == model.state.selectedFolderID }
    }

    var body: some View {
        Form {
            Section {
                Text(prefix.title).font(.title2.bold())
                Text("Save-folder snapshots preserve the game-specific folder you select and keep earlier snapshots. Prefix backups preserve a Windows environment; full-game backups preserve installed game files.")
                    .foregroundStyle(.secondary)
                Text("Save locations are checked in both Steam and CrossOver user folders. This does not determine whether Steam Cloud has synced your saves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Save folders") {
                if !model.state.candidates.isEmpty {
                    Picker("Look in", selection: $candidateRoot) {
                        ForEach(model.state.candidates) { candidate in
                            Text(candidate.title).tag(Optional(candidate.url))
                        }
                    }
                    Button("Choose game folder…", systemImage: "folder.badge.plus") {
                        chooseFolder(native: false)
                    }
                    .disabled(candidateRoot == nil)
                } else {
                    Text("No safe Documents or app-data locations were found in the Steam or CrossOver user folders. This does not mean your saves are missing; you can manually choose a native game save folder.")
                        .foregroundStyle(.secondary)
                }
                Button("Choose native game folder…", systemImage: "folder") { chooseFolder(native: true) }
                if !model.state.folders.isEmpty {
                    Picker("Save folder", selection: Binding(
                        get: { model.state.selectedFolderID },
                        set: { id in if let id { run(.selectFolder(id)) } }
                    )) {
                        ForEach(model.state.folders) { folder in
                            Text(folder.title + (folder.native ? " · Native" : " · Windows"))
                                .tag(Optional(folder.id))
                        }
                    }
                }
                if let folder = selectedFolder {
                    Button("Open save folder", systemImage: "folder") { run(.openFolder(folder.id)) }
                    DisclosureGroup("Folder path") {
                        Text(folder.url.path).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if let folder = selectedFolder {
                Section("Create a snapshot") {
                    TextField("Snapshot name", text: $snapshotName)
                    Button("Create snapshot", systemImage: "camera") {
                        run(.create(folderID: folder.id, name: snapshotName))
                    }
                    .disabled(snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Snapshots") {
                    if snapshots.isEmpty {
                        Text("No snapshots for this folder yet.").foregroundStyle(.secondary)
                    }
                    ForEach(snapshots) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.title)
                                Text(snapshot.created.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore…") {
                                pendingRestore = snapshot
                                showRestoreConfirmation = true
                            }
                        }
                    }
                }
            }
            Section {
                if model.isBusy { ProgressView("Working with save files…") }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                if let error = pickerError ?? model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Button("Refresh", systemImage: "arrow.clockwise") { run(.refresh) }
            }
        }
        .formStyle(.grouped)
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
        .frame(minWidth: 460, minHeight: 460)
        .confirmationDialog("Restore this snapshot?", isPresented: $showRestoreConfirmation, titleVisibility: .visible) {
            if let snapshot = pendingRestore {
                Button("Restore “\(snapshot.title)”", role: .destructive) {
                    run(.restore(snapshotID: snapshot.id, folderID: snapshot.folderID))
                    pendingRestore = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("The selected folder will be replaced. Current saves will first be preserved in a separate Before restore snapshot. Quit the game before restoring.")
        }
        .task { await model.perform(.refresh); updateCandidate() }
        .onChange(of: model.state.candidates.map(\.url)) { _, _ in updateCandidate() }
    }

    private func updateCandidate() {
        if !model.state.candidates.contains(where: { $0.url == candidateRoot }) {
            candidateRoot = model.state.candidates.first?.url
        }
    }

    private func run(_ action: GameSavesViewModel.Action) {
        pickerError = nil
        Task { await model.perform(action) }
    }

    private func chooseFolder(native: Bool) {
        let root = native ? nil : candidateRoot
        guard native || root != nil else { return }
        let panel = NSOpenPanel()
        panel.title = native ? "Choose the native game’s save folder" : "Choose the game’s save folder"
        panel.message = "Select the game’s own folder, not Documents, AppData, or your home folder. Symbolic links are not supported."
        panel.prompt = "Use save folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.directoryURL = root
        panel.begin { response in
            if response == .OK, let url = panel.url { run(.addFolder(url, candidateRoot: root)) }
        }
    }
}
