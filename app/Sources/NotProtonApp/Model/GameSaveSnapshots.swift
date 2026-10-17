import Darwin
import Foundation

/// One explicitly known game folder per snapshot. Candidate containers are only for browsing;
/// callers must supply the game's relative folder. No home scan or game-folder guessing occurs.
struct GameSaveSnapshots {
    struct Location {
        let root: URL
        let relativePath: String
    }

    struct Manifest: Codable, Equatable {
        let version: Int
        let owner: UUID
        let id: UUID
        let appID: String
        let created: Date
        let sourcePath: String
        let entries: [Entry]
    }

    struct Entry: Codable, Equatable {
        let path: String
        let directory: Bool
        let digest: String?
    }

    enum Failure: Error, LocalizedError {
        case refused(String)
        var errorDescription: String? {
            switch self { case .refused(let reason): return reason }
        }
    }

    let root: URL
    private let owner: UUID
    private let sessionActive: (String) throws -> Bool
    private let fm = FileManager.default

    /// The dedicated store must be empty or already owned. Session lookup failures fail closed.
    init(root: URL, sessionActive: @escaping (String) throws -> Bool) throws {
        self.root = root
        self.sessionActive = sessionActive
        try Self.checkPath(root)
        guard root.pathComponents.count > 2 else { throw Failure.refused("Unsafe snapshot store.") }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appending(path: "owner.json")
        let fd = Darwin.open(root.appending(path: ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.refused("Cannot lock snapshot store.") }
        defer { FileLock.release(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.refused("Cannot lock snapshot store.") }
        try Self.checkPath(marker)
        if fm.fileExists(atPath: marker.path) {
            owner = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: marker))
        } else {
            guard try fm.contentsOfDirectory(atPath: root.path).allSatisfy({ $0 == ".lock" }) else {
                throw Failure.refused("Refusing to claim a nonempty snapshot store.")
            }
            let id = UUID()
            try JSONEncoder().encode(id).write(to: marker, options: .atomic)
            owner = id
        }
    }

    /// Returns existing safe containers only, without following Wine's host-Documents symlinks.
    static func candidateSaveRoots(prefix: URL?, nativePaths: [URL] = []) throws -> [URL] {
        var candidates = nativePaths
        if let prefix {
            try checkPath(prefix)
            for user in ["steamuser", "crossover"] {
                for folder in ["Documents", "AppData/Local", "AppData/LocalLow", "AppData/Roaming"] {
                    candidates.append(prefix.appending(path: "drive_c/users/\(user)/\(folder)"))
                }
            }
        }
        var seen = Set<String>()
        return candidates.filter { url in
            guard (try? checkPath(url)) != nil,
                  (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
                    == .typeDirectory else { return false }
            return seen.insert(url.path).inserted
        }
    }

    func snapshot(appID: String, location: Location) throws -> Manifest {
        try locked { try capture(appID: appID, source: resolve(location)) }
    }

    func snapshots(appID: String) throws -> [Manifest] {
        try locked { try ownedSnapshots(appID: appID) }
    }

    /// The destination must explicitly match the recorded save directory and game. Returns the
    /// pre-restore backup, if a current directory existed. Restore never trusts manifest paths.
    @discardableResult
    func restore(appID: String, id: UUID, location: Location) throws -> Manifest? {
        try locked {
            try requireIdle(appID)
            let destination = try resolve(location)
            let manifest = try validate(appID: appID, id: id)
            guard manifest.sourcePath == destination.path else {
                throw Failure.refused("Snapshot belongs to a different save directory.")
            }
            let parent = destination.deletingLastPathComponent()
            try Self.checkPath(parent)
            guard fm.fileExists(atPath: parent.path) else {
                throw Failure.refused("Save parent directory is missing.")
            }
            let staged = parent.appending(path: ".save-stage-\(UUID().uuidString)")
            let parked = parent.appending(path: ".save-recovery-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: snapshotURL(appID, id).appending(path: "data"), to: staged)
            guard try inventory(staged) == manifest.entries else {
                throw Failure.refused("Staged save validation failed.")
            }
            let backup = fm.fileExists(atPath: destination.path)
                ? try capture(appID: appID, source: destination) : nil
            try requireIdle(appID)
            try Self.checkPath(destination)
            if let backup, try inventory(destination) != backup.entries {
                throw Failure.refused("Current saves changed during backup.")
            }
            if backup != nil { try fm.moveItem(at: destination, to: parked) }
            do {
                try fm.moveItem(at: staged, to: destination)
            } catch {
                // Never delete current data on a failed installation. If rollback itself fails,
                // the untouched parked directory and published backup remain available.
                if backup != nil {
                    do { try fm.moveItem(at: parked, to: destination) }
                    catch {
                        throw Failure.refused("Restore failed; recovery data remains at \(parked.path).")
                    }
                }
                throw error
            }
            if backup != nil { try fm.removeItem(at: parked) }
            return backup
        }
    }

    private func requireIdle(_ appID: String) throws {
        guard try !sessionActive(appID) else { throw Failure.refused("Cannot restore while the game session is active.") }
    }

    private func resolve(_ location: Location) throws -> URL {
        try Self.checkRelative(location.relativePath)
        try Self.checkPath(location.root)
        let url = location.root.appending(path: location.relativePath)
        try Self.checkPath(url)
        guard !Self.overlaps(url, root) else { throw Failure.refused("Save directory overlaps the snapshot store.") }
        return url
    }

    private func capture(appID: String, source: URL) throws -> Manifest {
        try Self.checkAppID(appID)
        let before = try inventory(source)
        let game = root.appending(path: appID)
        try Self.checkPath(game)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        let id = UUID()
        let staging = game.appending(path: ".pending-\(id.uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let data = staging.appending(path: "data")
        try fm.copyItem(at: source, to: data)
        guard try inventory(data) == before, try inventory(source) == before else {
            throw Failure.refused("Saves changed during snapshot creation.")
        }
        let manifest = Manifest(version: 1, owner: owner, id: id, appID: appID,
                                created: Date(), sourcePath: source.path, entries: before)
        try JSONEncoder().encode(manifest).write(to: staging.appending(path: "manifest.json"), options: .atomic)
        try fm.moveItem(at: staging, to: snapshotURL(appID, id))
        return manifest
    }

    private func validate(appID: String, id: UUID) throws -> Manifest {
        try Self.checkAppID(appID)
        let directory = snapshotURL(appID, id)
        try Self.checkPath(directory)
        let file = directory.appending(path: "manifest.json")
        try Self.checkPath(file)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
        guard manifest.version == 1, manifest.owner == owner, manifest.appID == appID,
              manifest.id == id,
              Set(try fm.contentsOfDirectory(atPath: directory.path)) == ["data", "manifest.json"],
              try inventory(directory.appending(path: "data")) == manifest.entries else {
            throw Failure.refused("Snapshot ownership or contents are invalid.")
        }
        return manifest
    }

    private func ownedSnapshots(appID: String) throws -> [Manifest] {
        try Self.checkAppID(appID)
        let directory = root.appending(path: appID)
        try Self.checkPath(directory)
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: directory.path).compactMap { name in
            guard let id = UUID(uuidString: name), name == id.uuidString else { return nil }
            return try? validate(appID: appID, id: id)
        }.sorted {
            $0.created == $1.created ? $0.id.uuidString > $1.id.uuidString : $0.created > $1.created
        }
    }

    private func snapshotURL(_ appID: String, _ id: UUID) -> URL {
        root.appending(path: appID).appending(path: id.uuidString)
    }

    private func inventory(_ directory: URL) throws -> [Entry] {
        try Self.checkPath(directory)
        guard try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.refused("Save path is not a directory.")
        }
        var entries: [Entry] = []
        func walk(_ folder: URL, relative: String) throws {
            for name in try fm.contentsOfDirectory(atPath: folder.path) {
                let path = relative.isEmpty ? name : relative + "/" + name
                try Self.checkRelative(path)
                let url = folder.appending(path: name)
                let attributes = try fm.attributesOfItem(atPath: url.path)
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular,
                      type != .typeRegular || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                    throw Failure.refused("Save data contains a link or unsupported file: \(path)")
                }
                entries.append(Entry(path: path, directory: type == .typeDirectory,
                                     digest: type == .typeRegular ? try Digest.sha256(of: url) : nil))
                if type == .typeDirectory { try walk(url, relative: path) }
            }
        }
        try walk(directory, relative: "")
        return entries.sorted { $0.path < $1.path }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try Self.checkPath(root)
        let fd = Darwin.open(root.appending(path: ".lock").path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.refused("Cannot lock snapshot store.") }
        defer { FileLock.release(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.refused("Cannot lock snapshot store.") }
        let marker = root.appending(path: "owner.json")
        try Self.checkPath(marker)
        guard try JSONDecoder().decode(UUID.self, from: Data(contentsOf: marker)) == owner else {
            throw Failure.refused("Snapshot store ownership changed.")
        }
        return try body()
    }

    private static func checkAppID(_ appID: String) throws {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }),
              appID.first != "0" else { throw Failure.refused("Invalid game appID.") }
    }

    private static func checkRelative(_ path: String) throws {
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure.refused("Unsafe relative save path.")
        }
    }

    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        // Be conservative on case-sensitive volumes too: APFS commonly aliases case and
        // canonical Unicode spellings, which must not permit copying the store into itself.
        let left = a.path.precomposedStringWithCanonicalMapping.lowercased()
        let right = b.path.precomposedStringWithCanonicalMapping.lowercased()
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    /// Check every existing ancestor, including dangling links. Missing leaf directories are OK.
    /// Callers should canonicalize trusted OS aliases (e.g. /tmp) before constructing locations.
    private static func checkPath(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "", url.path.hasPrefix("/"),
              url.pathComponents.allSatisfy({ $0 != "." && $0 != ".." }),
              !url.path.contains("\0") else {
            throw Failure.refused("Unsafe save path.")
        }
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            current.append(path: component)
            do {
                let type = try FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else {
                    throw Failure.refused("Links and special files are not allowed: \(current.path)")
                }
                if current.path != url.path && type != .typeDirectory {
                    throw Failure.refused("Save ancestor is not a directory.")
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return
            }
        }
    }
}
