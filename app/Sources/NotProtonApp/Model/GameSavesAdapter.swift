import Darwin
import Foundation

/// All disk work stays on this actor. Only Sendable presentation values cross to the UI.
actor GameSavesAdapter {
    struct Dependencies: Sendable {
        var resolvePrefix: @Sendable (WinePrefix) throws -> URL = { try GameProfileStore.resolveRoot(for: $0) }
        var sessionActive: @Sendable (WinePrefix) throws -> Bool = { PrefixStore.isInUse($0) }
        var home: URL = URL(fileURLWithPath: NSHomeDirectory())
    }

    struct Candidate: Identifiable, Sendable {
        let url: URL
        let title: String
        var id: URL { url }
    }

    struct Folder: Codable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let root: URL
        let relativePath: String
        let native: Bool
        var url: URL { root.appending(path: relativePath) }
        var location: GameSaveSnapshots.Location { .init(root: root, relativePath: relativePath) }
    }

    struct Snapshot: Identifiable, Sendable {
        let id: UUID
        let title: String
        let created: Date
        let folderID: UUID
    }

    struct State: Sendable {
        var candidates: [Candidate] = []
        var folders: [Folder] = []
        var selectedFolderID: UUID?
        var snapshots: [Snapshot] = []
    }

    private struct Configuration: Codable {
        var version = 1
        let owner: UUID
        let appID: String
        let prefixID: String
        var folders: [Folder] = []
        var selectedFolderID: UUID?
        var names: [String: String] = [:]
    }

    private let prefix: WinePrefix
    private let backupRoot: URL
    private let dependencies: Dependencies
    private let fm = FileManager.default

    init(prefix: WinePrefix, backupRoot: URL, dependencies: Dependencies = .init()) {
        self.prefix = prefix
        self.backupRoot = backupRoot
        self.dependencies = dependencies
    }

    func load() throws -> State {
        let resolved = try dependencies.resolvePrefix(prefix)
        let store = try makeStore(resolved: resolved)
        let config = try configuration { $0 }
        let candidates = try candidates(resolved: resolved)
        let snapshots = try store.snapshots(appID: prefix.appID).compactMap { manifest -> Snapshot? in
            guard let folder = config.folders.first(where: { $0.url.path == manifest.sourcePath }) else { return nil }
            return Snapshot(id: manifest.id, title: config.names[manifest.id.uuidString] ?? "Save snapshot",
                            created: manifest.created, folderID: folder.id)
        }
        return State(candidates: candidates, folders: config.folders,
                     selectedFolderID: config.selectedFolderID, snapshots: snapshots)
    }

    /// A prefix selection must be strictly below an existing candidate container. Native
    /// selection is manual and cannot be a home, common container, prefix, or backup directory.
    func addFolder(_ url: URL, candidateRoot: URL?) throws -> State {
        let resolved = try dependencies.resolvePrefix(prefix)
        _ = try makeStore(resolved: resolved)
        try safePath(url)
        let title = try checkedName(url.lastPathComponent)
        guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw refused("Choose a game save folder.")
        }
        let folder: Folder
        if let candidateRoot {
            guard try candidates(resolved: resolved).contains(where: { $0.url.path == candidateRoot.path }),
                  url.path.hasPrefix(candidateRoot.path + "/") else {
                throw refused("Choose a game-specific folder inside the selected save location.")
            }
            folder = Folder(id: UUID(), title: title, root: candidateRoot,
                            relativePath: String(url.path.dropFirst(candidateRoot.path.count + 1)), native: false)
        } else {
            try validateNative(url, resolved: resolved)
            folder = Folder(id: UUID(), title: title,
                            root: url.deletingLastPathComponent(), relativePath: url.lastPathComponent, native: true)
        }
        try validateFolder(folder, resolved: resolved)
        try configuration(write: true) { config in
            let saved = config.folders.first { $0.url.path == folder.url.path }
            if saved == nil {
                guard config.folders.count < 32 else { throw refused("This game already has 32 saved folders.") }
                config.folders.append(folder)
            }
            config.selectedFolderID = saved?.id ?? folder.id
        }
        return try load()
    }

    func selectFolder(_ id: UUID) throws -> State {
        _ = try makeStore(resolved: dependencies.resolvePrefix(prefix))
        try configuration(write: true) { config in
            guard config.folders.contains(where: { $0.id == id }) else { throw refused("Save folder is no longer configured.") }
            config.selectedFolderID = id
        }
        return try load()
    }

    func createSnapshot(folderID: UUID, name: String) throws -> State {
        let title = try checkedName(name)
        let resolved = try dependencies.resolvePrefix(prefix)
        let store = try makeStore(resolved: resolved)
        let folder = try selectedFolder(folderID)
        try validateFolder(folder, resolved: resolved)
        guard try !dependencies.sessionActive(prefix) else { throw refused("Quit the game before creating a snapshot.") }
        let snapshot = try store.snapshot(appID: prefix.appID, location: folder.location)
        do { try configuration(write: true) { $0.names[snapshot.id.uuidString] = title } }
        catch { throw refused("Snapshot created, but its name could not be saved. \(error.localizedDescription)") }
        return try load()
    }

    func restoreSnapshot(_ id: UUID, folderID: UUID) throws -> State {
        let resolved = try dependencies.resolvePrefix(prefix)
        let store = try makeStore(resolved: resolved)
        let folder = try selectedFolder(folderID)
        try validateFolder(folder, resolved: resolved)
        // The store independently checks game, source path, ownership and every file digest.
        let backup = try store.restore(appID: prefix.appID, id: id, location: folder.location)
        if let backup {
            do { try configuration(write: true) { $0.names[backup.id.uuidString] = "Before restore" } }
            catch { throw refused("Saves restored and a recovery snapshot preserved, but its name could not be saved. \(error.localizedDescription)") }
        }
        return try load()
    }

    func folderToOpen(_ id: UUID) throws -> URL {
        let resolved = try dependencies.resolvePrefix(prefix)
        _ = try makeStore(resolved: resolved)
        let folder = try selectedFolder(id)
        try validateFolder(folder, resolved: resolved)
        guard try GameSaveSnapshots.candidateSaveRoots(prefix: nil, nativePaths: [folder.url]).count == 1 else {
            throw refused("Save folder is missing or unsafe.")
        }
        return folder.url
    }

    private func makeStore(resolved: URL) throws -> GameSaveSnapshots {
        let dependencies = dependencies, prefix = prefix
        return try GameSaveSnapshots(root: backupRoot, sessionActive: { appID in
            guard appID == prefix.appID, try dependencies.resolvePrefix(prefix).path == resolved.path else {
                throw GameSaveSnapshots.Failure.refused("The shared prefix changed. Refresh before restoring saves.")
            }
            return try dependencies.sessionActive(prefix)
        })
    }

    private func candidates(resolved: URL) throws -> [Candidate] {
        try GameSaveSnapshots.candidateSaveRoots(prefix: resolved).map { url in
            let user = url.pathComponents.contains("crossover") ? "CrossOver user" : "Steam user"
            let name: String
            switch url.lastPathComponent {
            case "Documents": name = "Documents"
            case "Local": name = "Local app data"
            case "LocalLow": name = "LocalLow app data"
            default: name = "Roaming app data"
            }
            return Candidate(url: url, title: "\(name) · \(user)")
        }
    }

    private func selectedFolder(_ id: UUID) throws -> Folder {
        try configuration { config in
            guard let folder = config.folders.first(where: { $0.id == id }) else {
                throw refused("Choose a save folder first.")
            }
            return folder
        }
    }

    private func validateFolder(_ folder: Folder, resolved: URL) throws {
        try safePath(folder.root)
        try safePath(folder.url)
        guard !folder.relativePath.isEmpty,
              folder.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !folder.relativePath.contains("\\"), !overlaps(folder.url, backupRoot) else {
            throw refused("Unsafe save folder.")
        }
        if folder.native { try validateNative(folder.url, resolved: resolved) }
        else {
            guard try candidates(resolved: resolved).contains(where: { $0.url.path == folder.root.path }) else {
                throw refused("This save folder is outside the current prefix’s save locations. Choose its folder again.")
            }
        }
    }

    private func validateNative(_ url: URL, resolved: URL) throws {
        let broad = ["documents", "desktop", "downloads", "library", "application support", "appdata",
                     "local", "locallow", "roaming", "pfx", "drive_c", "users", "steamapps", "compatdata"]
        guard url.pathComponents.count >= 4,
              !isWithin(dependencies.home, url), !overlaps(url, resolved),
              !overlaps(url, backupRoot), !broad.contains(url.lastPathComponent.lowercased()) else {
            throw refused("Choose the native game’s own save folder, not a home, library, or shared container.")
        }
    }

    /// Uses the snapshot store's ownership UUID and lock. Never adopts or overwrites foreign,
    /// linked, oversized, incompatible, or other-library configuration files.
    private func configuration<T>(write: Bool = false, _ body: (inout Configuration) throws -> T) throws -> T {
        try safePath(backupRoot)
        let lock = backupRoot.appending(path: ".lock")
        let fd = Darwin.open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw refused("Cannot lock save-folder settings.") }
        defer { FileLock.release(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              flock(fd, LOCK_EX) == 0 else { throw refused("Cannot lock save-folder settings.") }
        let marker = backupRoot.appending(path: "owner.json")
        try smallRegularFile(marker, limit: 1024)
        let owner = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: marker))
        guard GameProfile.isNumericAppID(prefix.appID), prefix.appID.first != "0" else {
            throw refused("Invalid game appID.")
        }
        let game = backupRoot.appending(path: prefix.appID)
        try safePath(game)
        let file = game.appending(path: "save-folders.json")
        try safePath(file)
        var config: Configuration
        if fm.fileExists(atPath: file.path) {
            try smallRegularFile(file, limit: 64 * 1024)
            config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
            guard config.version == 1, config.owner == owner, config.appID == prefix.appID,
                  config.prefixID == prefix.id, config.folders.count <= 32,
                  Set(config.folders.map(\.id)).count == config.folders.count,
                  config.folders.allSatisfy({ (try? checkedName($0.title)) != nil }),
                  config.names.allSatisfy({ UUID(uuidString: $0.key) != nil && (try? checkedName($0.value)) != nil }),
                  config.selectedFolderID == nil || config.folders.contains(where: { $0.id == config.selectedFolderID }) else {
                throw refused("Save-folder settings have invalid ownership or contents.")
            }
        } else {
            config = Configuration(owner: owner, appID: prefix.appID, prefixID: prefix.id)
        }
        let result = try body(&config)
        if write {
            let data = try JSONEncoder().encode(config)
            guard data.count <= 64 * 1024 else { throw refused("Save-folder settings reached their size limit.") }
            try fm.createDirectory(at: game, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        return result
    }

    private func smallRegularFile(_ url: URL, limit: Int) throws {
        try safePath(url)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let bytes = attributes[.size] as? NSNumber, bytes.intValue <= limit else {
            throw refused("Save settings must be a small regular file.")
        }
    }

    private func safePath(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "", url.path.hasPrefix("/"),
              !url.path.contains("\0"), url.pathComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw refused("Unsafe save path.")
        }
        var ancestor = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst() {
            ancestor.append(path: part)
            do {
                let type = try fm.attributesOfItem(atPath: ancestor.path)[.type] as? FileAttributeType
                guard type == .typeDirectory || (ancestor.path == url.path && type == .typeRegular) else {
                    throw refused("Save paths must not contain symbolic links or special files.")
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        }
    }

    private func checkedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw refused("Use a name of 1–100 characters without control characters.")
        }
        return name
    }

    private func isWithin(_ child: URL, _ parent: URL) -> Bool {
        let c = child.path.precomposedStringWithCanonicalMapping.lowercased()
        let p = parent.path.precomposedStringWithCanonicalMapping.lowercased()
        return c == p || c.hasPrefix(p + "/")
    }

    private func overlaps(_ a: URL, _ b: URL) -> Bool { isWithin(a, b) || isWithin(b, a) }
    private func refused(_ reason: String) -> GameSaveSnapshots.Failure { .refused(reason) }
}
