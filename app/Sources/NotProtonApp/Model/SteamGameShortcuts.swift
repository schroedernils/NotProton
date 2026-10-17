import Foundation

/// Explicit, synchronous lifecycle API. Call on a serial worker, with the complete library
/// inventory (including temporarily unavailable volumes). Only creates or updates wrappers;
/// existing shortcuts are retained when games are unavailable or uninstalled.
enum SteamGameShortcuts {
    struct Game {
        let appID: String
        /// Canonical Steam name, e.g. appinfo common/name, never an executable filename.
        let name: String
        /// Original native ICNS, or original artwork converted by iconmaker.
        let iconURL: URL
    }

    struct Result: Sendable {
        var applications: [URL] = []
        var skippedAppIDs: [String] = []
    }

    enum Failure: Error {
        case invalidAppID(String), invalidName, invalidIcon, invalidManifest(URL)
        case unsafeDirectory(URL), collision(URL)
    }

    private struct Marker: Codable, Equatable {
        let owner: String
        let version: Int
        let appID: String
    }

    private static let owner = "com.notproton.NotProton.steam-shortcut"
    private static let markerPath = "Contents/Resources/notproton-shortcut.json"
    private static let files: Set<String> = [
        "Contents/Info.plist", "Contents/MacOS/launch", "Contents/Resources/game.icns",
        markerPath,
    ]
    private static let directories: Set<String> = ["Contents", "Contents/MacOS", "Contents/Resources"]

    static func bundleIdentifier(appID: String) throws -> String {
        try validate(appID)
        return "com.notproton.NotProton.steam-game.\(appID)"
    }

    private static func validate(_ id: String) throws {
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt32(id), number > 0, String(number) == id
        else { throw Failure.invalidAppID(id) }
    }

    /// `libraryRoots` are Steam library roots, each containing steamapps. All manifests
    /// must be readable and valid before any wrapper is written. Manifest
    /// presence retains a game during updates; compatdata/save directories are never read.
    /// `metadata` resolves canonical name and original icon for each installed AppID.
    static func sync(
        libraryRoots: [URL], directory: URL,
        metadata: (String, String, URL?) throws -> Game,
        onMetadataFailure: (String, Error) throws -> Void = { _, _ in },
        beforePublish: () throws -> Void = {},
        register: (URL) throws -> Void
    ) throws -> Result {
        let fm = FileManager.default
        var installed: [String: (name: String, directory: URL?)] = [:]
        for root in libraryRoots {
            let steamapps = root.appendingPathComponent("steamapps", isDirectory: true)
            for manifest in try fm.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)
                .sorted(by: { $0.path < $1.path })
            where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                let id = String(manifest.deletingPathExtension().lastPathComponent.dropFirst(12))
                try validate(id)
                let values = try manifestValues(String(contentsOf: manifest, encoding: .utf8))
                guard values["appid"] == id, let name = values["name"], !name.isEmpty else {
                    throw Failure.invalidManifest(manifest)
                }
                guard installed[id] == nil else { throw Failure.invalidManifest(manifest) }
                var installation: URL?
                if let folder = values["installdir"] {
                    guard !folder.isEmpty, folder != ".", folder != "..", !folder.contains("/"),
                          !folder.contains("\\"),
                          !folder.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    else { throw Failure.invalidManifest(manifest) }
                    let common = steamapps.appendingPathComponent("common").resolvingSymlinksInPath()
                    let candidate = common.appendingPathComponent(folder).resolvingSymlinksInPath()
                    guard common.deletingLastPathComponent() == steamapps.resolvingSymlinksInPath(),
                          candidate.deletingLastPathComponent() == common else { throw Failure.invalidManifest(manifest) }
                    installation = candidate
                }
                installed[id] = (name, installation)
            }
        }
        var games: [Game] = []
        var skipped: [String] = []
        for id in installed.keys.sorted() {
            do {
                let entry = installed[id]!
                let game = try metadata(id, entry.name, entry.directory)
                guard game.appID == id else { throw Failure.invalidAppID(game.appID) }
                _ = try prepare(game)
                games.append(game)
            } catch {
                try onMetadataFailure(id, error)
                skipped.append(id)
            }
        }
        try beforePublish()
        var result = try sync(games: games, directory: directory, register: register)
        result.skippedAppIDs = (result.skippedAppIDs + skipped).sorted()
        return result
    }

    /// Lower-level API for an already validated, complete installation snapshot.
    /// Existing wrappers are retained, including for empty snapshots.
    static func sync(games: [Game], directory: URL,
                     register: (URL) throws -> Void) throws -> Result {
        let fm = FileManager.default
        // Preflight everything before mutation, including icon/name changes.
        var ids = Set<String>()
        var skipped: [String] = []
        let prepared = try games.compactMap { game -> (Game, Data, String)? in
            try validate(game.appID)
            guard ids.insert(game.appID).inserted else { throw Failure.invalidAppID(game.appID) }
            _ = try filename(game.name)
            do { return try prepare(game) }
            catch { skipped.append(game.appID); return nil }
        }
        guard directory.isFileURL,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw Failure.unsafeDirectory(directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure.unsafeDirectory(directory)
        }
        var result = Result()
        result.skippedAppIDs = skipped.sorted()
        for (game, icon, stem) in prepared.sorted(by: { $0.0.appID < $1.0.appID }) {
            var target = directory.appendingPathComponent(stem + ".app", isDirectory: true)
            if exists(target), ownership(target)?.appID != game.appID {
                target = directory.appendingPathComponent("\(stem) (\(game.appID)).app", isDirectory: true)
            }
            guard !exists(target) || ownership(target)?.appID == game.appID else {
                throw Failure.collision(target)
            }
            let stage = directory.appendingPathComponent(".shortcut-\(UUID().uuidString)")
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: stage) }
            for subdirectory in directories {
                try fm.createDirectory(at: stage.appendingPathComponent(subdirectory), withIntermediateDirectories: true)
            }
            let plist: [String: Any] = [
                "CFBundleIdentifier": try bundleIdentifier(appID: game.appID),
                "CFBundleName": game.name, "CFBundleDisplayName": game.name,
                "CFBundleExecutable": "launch", "CFBundleIconFile": "game.icns",
                "CFBundlePackageType": "APPL", "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleVersion": "1", "LSApplicationCategoryType": "public.app-category.games",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: stage.appendingPathComponent("Contents/Info.plist"))
            // Only the validated canonical decimal ID enters shell code. No names, paths,
            // environment lookups, or caller arguments can become shell syntax/options.
            let script = "#!/bin/sh\nexec /usr/bin/open \"steam://rungameid/\(game.appID)\"\n"
            let executable = stage.appendingPathComponent("Contents/MacOS/launch")
            try Data(script.utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try icon.write(to: stage.appendingPathComponent("Contents/Resources/game.icns"))
            let marker = Marker(owner: owner, version: 1, appID: game.appID)
            try JSONEncoder().encode(marker).write(to: stage.appendingPathComponent(markerPath))
            if exists(target) {
                // Recheck immediately before replacing; preserve the previous bundle if
                // publishing fails. Callers must serialize syncs for this directory.
                guard ownership(target) == marker else { throw Failure.collision(target) }
                let backup = directory.appendingPathComponent(".shortcut-backup-\(UUID().uuidString)")
                try fm.moveItem(at: target, to: backup)
                do { try fm.moveItem(at: stage, to: target) }
                catch {
                    try fm.moveItem(at: backup, to: target)
                    throw error
                }
                try fm.removeItem(at: backup)
            } else {
                try fm.moveItem(at: stage, to: target)
            }
            try register(target)
            result.applications.append(target)
        }
        return result
    }

    private static func prepare(_ game: Game) throws -> (Game, Data, String) {
        let stem = try filename(game.name)
        guard game.iconURL.isFileURL else { throw Failure.invalidIcon }
        let icon = try Data(contentsOf: game.iconURL)
        guard icon.count >= 8, icon.prefix(4) == Data("icns".utf8),
              icon.prefix(8).suffix(4).reduce(UInt64(0), { ($0 << 8) | UInt64($1) }) == UInt64(icon.count)
        else { throw Failure.invalidIcon }
        return (game, icon, stem)
    }

    private static func exists(_ url: URL) -> Bool {
        // Includes dangling symlinks, which must never be replaced.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Marker alone is insufficient: refuse links, extra files (including saves), or
    /// inconsistent bundle identity. Enumerate only the explicitly supplied directory.
    private static func ownership(_ url: URL) -> Marker? {
        let fm = FileManager.default
        guard url.pathExtension == "app",
              (try? fm.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory
        else { return nil }
        var found = Set<String>()
        var pending = [""]
        while let parent = pending.popLast() {
            let folder = parent.isEmpty ? url : url.appendingPathComponent(parent)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
            for name in names {
                let relative = parent.isEmpty ? name : parent + "/" + name
                let child = url.appendingPathComponent(relative)
                let type = (try? fm.attributesOfItem(atPath: child.path)[.type]) as? FileAttributeType
                guard (files.contains(relative) && type == .typeRegular) ||
                        (directories.contains(relative) && type == .typeDirectory) else { return nil }
                found.insert(relative)
                if type == .typeDirectory { pending.append(relative) }
            }
        }
        guard found == files.union(directories),
              let data = try? Data(contentsOf: url.appendingPathComponent(markerPath)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.owner == owner, marker.version == 1,
              let identifier = try? bundleIdentifier(appID: marker.appID),
              let plistData = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == identifier,
              plist["CFBundleExecutable"] as? String == "launch"
        else { return nil }
        return marker
    }

    private static func filename(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.invalidName }
        let safe = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Bound filesystem byte length; the canonical display name remains intact.
        var stem = ""
        for character in safe {
            guard stem.utf8.count + String(character).utf8.count <= 180 else { break }
            stem.append(character)
        }
        guard !stem.isEmpty, stem != ".", stem != "..", !stem.hasPrefix(".") else {
            throw Failure.invalidName
        }
        return stem
    }

    /// Minimal strict text KeyValues parser: quoted strings, braces, // comments and
    /// escaped quotes/backslashes. Only direct AppState fields count; nested spoofing
    /// and duplicate keys fail closed instead of authorizing deletion.
    private static func manifestValues(_ text: String) throws -> [String: String] {
        let invalid = Failure.invalidManifest(URL(fileURLWithPath: "appmanifest.acf"))
        let chars = Array(text)
        var index = 0
        func token() throws -> String? {
            while index < chars.count {
                if chars[index].isWhitespace { index += 1; continue }
                if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                    while index < chars.count && chars[index] != "\n" { index += 1 }
                    continue
                }
                break
            }
            guard index < chars.count else { return nil }
            let first = chars[index]
            index += 1
            if first == "{" || first == "}" { return String(first) }
            guard first == "\"" else { throw invalid }
            var value = ""
            while index < chars.count {
                let ch = chars[index]
                index += 1
                if ch == "\"" { return "\"" + value }
                if ch == "\\" {
                    guard index < chars.count else { throw invalid }
                    let escaped = chars[index]
                    index += 1
                    guard escaped == "\\" || escaped == "\"" else { throw invalid }
                    value.append(escaped)
                } else { value.append(ch) }
            }
            throw invalid
        }
        func section(depth: Int) throws -> [String: String] {
            guard depth < 32 else { throw invalid }
            var values: [String: String] = [:]
            var keys = Set<String>()
            while let key = try token() {
                if key == "}" { return values }
                guard key.hasPrefix("\""), keys.insert(key).inserted, let value = try token() else { throw invalid }
                if value == "{" { _ = try section(depth: depth + 1) }
                else {
                    guard value.hasPrefix("\"") else { throw invalid }
                    values[String(key.dropFirst())] = String(value.dropFirst())
                }
            }
            throw invalid
        }
        guard try token() == "\"AppState", try token() == "{" else { throw invalid }
        let values = try section(depth: 0)
        guard try token() == nil else { throw invalid }
        return values
    }
}
