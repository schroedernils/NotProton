import Foundation

enum GameGraphics: String, CaseIterable, Sendable, Identifiable {
    case `default` = "default"
    case d3dmetal
    case dxvk
    case dxmt

    var id: String { rawValue }
    var title: String {
        switch self {
        case .default: "Automatic"
        case .d3dmetal: "D3DMetal"
        case .dxvk: "DXVK"
        case .dxmt: "DXMT"
        }
    }

    // Runtime contract key consumed by compat_run.sh.
    var runtimeBackend: String? { self == .default ? nil : rawValue }
}

enum ProfileSwitch: String, CaseIterable, Sendable, Identifiable {
    case `default` = "default"
    case off = "0"
    case on = "1"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .default: "Use Steam default"
        case .off: "Off"
        case .on: "On"
        }
    }
}

enum OverlayDPIScaling: String, CaseIterable, Sendable, Identifiable {
    case `default` = "default"
    case disabled
    var id: String { rawValue }
    var title: String { self == .default ? "Use Steam default" : "Disable overlay DPI scaling" }
}

enum FullscreenDisplayCapture: String, CaseIterable, Sendable, Identifiable {
    case `default` = "default"
    case released

    var id: String { rawValue }
    var title: String {
        self == .default ? "Use Wine default" : "Release displays in fullscreen"
    }
}

struct GameProfile: Sendable, Equatable {
    var graphics: GameGraphics = .default
    var msync: ProfileSwitch = .default
    var retina: ProfileSwitch = .default
    var hideLauncherTile: ProfileSwitch = .default
    var overlayDPI: OverlayDPIScaling = .default
    var fullscreenDisplayCapture: FullscreenDisplayCapture = .default
    var gameMode: ProfileSwitch = .default
    var prefixOwner: String?
    var launchTarget: String?
    var launchCwd: String?

    static let schema = 1
    static let filename = "notproton-profile"
    static let keys = [
        "graphics", "msync", "retina", "hide_launcher_tile", "overlay_dpi",
        "fullscreen_display_capture", "game_mode", "prefix_owner",
        "launch_target", "launch_cwd", "schema",
    ]

    var isEmpty: Bool {
        graphics == .default && msync == .default && retina == .default
            && hideLauncherTile == .default && overlayDPI == .default
            && fullscreenDisplayCapture == .default && gameMode == .default && prefixOwner == nil
            && launchTarget == nil && launchCwd == nil
    }

    func encoded() -> Data {
        let values: [(String, String)] = [
            ("graphics", graphics.rawValue),
            ("msync", msync.rawValue),
            ("retina", retina.rawValue),
            ("hide_launcher_tile", hideLauncherTile.rawValue),
            ("overlay_dpi", overlayDPI.rawValue),
            ("fullscreen_display_capture", fullscreenDisplayCapture.rawValue),
            ("game_mode", gameMode.rawValue),
            ("prefix_owner", prefixOwner ?? ""),
            ("launch_target", launchTarget ?? ""),
            ("launch_cwd", launchCwd ?? ""),
            ("schema", String(Self.schema)),
        ]
        return Data(values.map { "\($0.0)\t\($0.1)\n" }.joined().utf8)
    }

    static func decode(_ data: Data) throws -> GameProfile {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProfileError.malformed("Profile is not valid UTF-8.")
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw ProfileError.malformed("Expected key and value separated by a tab.") }
            let key = String(fields[0]), value = String(fields[1])
            guard Self.keys.contains(key), values[key] == nil else {
                throw ProfileError.malformed("Unknown or duplicate profile key: \(key).")
            }
            guard !value.contains("\r") else { throw ProfileError.malformed("Carriage returns are not allowed.") }
            values[key] = value
        }
        guard values["schema"] == String(Self.schema) else {
            throw ProfileError.malformed("Unsupported profile schema.")
        }
        guard let graphics = values["graphics"].flatMap(GameGraphics.init(rawValue:)),
              let msync = values["msync"].flatMap(ProfileSwitch.init(rawValue:)),
              let retina = values["retina"].flatMap(ProfileSwitch.init(rawValue:)),
              let hideTile = values["hide_launcher_tile"].flatMap(ProfileSwitch.init(rawValue:)),
              let overlayDPI = values["overlay_dpi"].flatMap(OverlayDPIScaling.init(rawValue:))
        else { throw ProfileError.malformed("Profile contains an invalid setting.") }
        let fullscreenDisplayCapture = values["fullscreen_display_capture"]
            .flatMap(FullscreenDisplayCapture.init(rawValue:)) ?? .default
        let gameMode = values["game_mode"].flatMap(ProfileSwitch.init(rawValue:)) ?? .default
        if let saved = values["game_mode"], ProfileSwitch(rawValue: saved) == nil {
            throw ProfileError.malformed("Profile contains an invalid Game Mode setting.")
        }
        let owner = values["prefix_owner"].flatMap { $0.isEmpty ? nil : $0 }
        if let owner, !Self.isNumericAppID(owner) {
            throw ProfileError.malformed("Prefix owner must be a numeric Steam App ID.")
        }
        let target = values["launch_target"].flatMap { $0.isEmpty ? nil : $0 }
        let cwd = values["launch_cwd"].flatMap { $0.isEmpty ? nil : $0 }
        if let target, !Self.isAbsolutePath(target) { throw ProfileError.malformed("Launch target must be absolute.") }
        if let cwd, !Self.isAbsolutePath(cwd) { throw ProfileError.malformed("Launch directory must be absolute.") }
        guard (target == nil) == (cwd == nil) else {
            throw ProfileError.malformed("Launch target and working directory must be set together.")
        }
        return GameProfile(
            graphics: graphics, msync: msync, retina: retina, hideLauncherTile: hideTile,
            overlayDPI: overlayDPI,
            fullscreenDisplayCapture: fullscreenDisplayCapture,
            gameMode: gameMode,
            prefixOwner: owner, launchTarget: target, launchCwd: cwd
        )
    }

    static func isNumericAppID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\t") && !value.contains("\n") && !value.contains("\r")
    }
}

enum ProfileError: LocalizedError, Sendable {
    case malformed(String)
    case invalidTarget(String)
    case invalidOwner(String)
    case inUse(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): reason
        case .invalidTarget(let reason): reason
        case .invalidOwner(let reason): reason
        case .inUse(let reason): reason
        }
    }
}

enum GameProfileStore {
    static func url(for prefix: WinePrefix) -> URL { prefix.root.appending(path: GameProfile.filename) }

    static func load(for prefix: WinePrefix) throws -> GameProfile {
        let file = url(for: prefix)
        let path = file.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return GameProfile() }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ProfileError.malformed("Profile file must not be a symbolic link.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 else {
            throw ProfileError.malformed("Profile exceeds the 16 KiB size limit.")
        }
        return try GameProfile.decode(Data(contentsOf: file, options: [.mappedIfSafe]))
    }

    static func save(_ profile: GameProfile, for prefix: WinePrefix, libraries: [SteamLibrary]? = nil) throws {
        try validate(profile, for: prefix, libraries: libraries)
        guard !PrefixStore.isInUse(prefix) else { throw ProfileError.inUse("Quit this game before changing its profile.") }
        if let oldOwner = try owner(of: prefix), PrefixStore.isInUse(oldOwner) {
            throw ProfileError.inUse("Quit the current prefix owner before changing this profile.")
        }
        if let owner = try owner(for: profile, child: prefix, libraries: libraries), PrefixStore.isInUse(owner) {
            throw ProfileError.inUse("Quit the selected prefix owner before changing this profile.")
        }
        let destination = url(for: prefix)
        let destinationPath = destination.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: destinationPath) {
            guard try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ProfileError.malformed("Profile file must not be a symbolic link.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: destinationPath)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 else {
                throw ProfileError.malformed("Profile exceeds the 16 KiB size limit.")
            }
        }
        try atomicReplace(destination, with: profile.encoded(), step: "Save game profile")
    }

    private static func owner(for profile: GameProfile, child: WinePrefix, libraries: [SteamLibrary]? = nil) throws -> WinePrefix? {
        guard let ownerID = profile.prefixOwner else { return nil }
        let matches = PrefixStore.all(libraries: libraries ?? [child.library]).filter {
            $0.appID == ownerID && $0.library.root.standardizedFileURL == child.library.root.standardizedFileURL
        }
        guard matches.count == 1, let owner = matches.first else {
            throw ProfileError.invalidOwner("The selected owner is missing or ambiguous.")
        }
        return owner
    }

    static func validate(_ profile: GameProfile, for prefix: WinePrefix, libraries: [SteamLibrary]? = nil) throws {
        if let target = profile.launchTarget {
            let url = URL(filePath: target)
            guard GameProfile.isAbsolutePath(target), ["exe", "bat", "cmd"].contains(url.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: target) else {
                throw ProfileError.invalidTarget("Choose an existing absolute .exe, .bat or .cmd file.")
            }
        }
        if let cwd = profile.launchCwd {
            var isDirectory: ObjCBool = false
            guard GameProfile.isAbsolutePath(cwd),
                  FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProfileError.invalidTarget("Launch directory must be an existing absolute directory.")
            }
        }
        guard (profile.launchTarget == nil) == (profile.launchCwd == nil) else {
            throw ProfileError.invalidTarget("Choose both a program and its working directory, or leave both unset.")
        }
        if let ownerID = profile.prefixOwner {
            guard ownerID != prefix.appID, GameProfile.isNumericAppID(ownerID) else {
                throw ProfileError.invalidOwner("A game cannot own its own prefix.")
            }
            let available = PrefixStore.all(libraries: libraries ?? PrefixStore.libraries())
            let matches = available.filter {
                $0.appID == ownerID && $0.library.root.standardizedFileURL == prefix.library.root.standardizedFileURL
            }
            guard matches.count == 1, let owner = matches.first,
                  FileManager.default.fileExists(atPath: owner.pfx.path(percentEncoded: false)),
               PrefixStore.arch(of: owner) != nil else {
                throw ProfileError.invalidOwner("Choose an existing compatible prefix in this Steam library.")
            }
            // Ownership is one hop. An owner that already delegates would create a chain/cycle.
            let ownerProfile: GameProfile
            do { ownerProfile = try load(for: owner) }
            catch { throw ProfileError.invalidOwner("The selected owner has a malformed profile.") }
            guard ownerProfile.prefixOwner == nil else {
                throw ProfileError.invalidOwner("The selected prefix already uses another owner; chains are not supported.")
            }
            guard PrefixStore.arch(of: prefix) == PrefixStore.arch(of: owner) else {
                throw ProfileError.invalidOwner("The prefixes use incompatible Windows architectures.")
            }
            guard let left = PrefixTools.lastBuild(of: prefix), let right = PrefixTools.lastBuild(of: owner),
                  left.build == right.build, left.display == right.display else {
                throw ProfileError.invalidOwner("The prefixes were created by different compatibility builds.")
            }
        }
    }

    static func owner(of prefix: WinePrefix) throws -> WinePrefix? {
        let profile = try load(for: prefix)
        guard let ownerID = profile.prefixOwner else { return nil }
        guard GameProfile.isNumericAppID(ownerID), ownerID != prefix.appID else {
            throw ProfileError.invalidOwner("Invalid prefix owner reference.")
        }
        let matches = PrefixStore.all(libraries: [prefix.library]).filter { $0.appID == ownerID }
        guard matches.count == 1, let owner = matches.first else {
            throw ProfileError.invalidOwner("The configured prefix owner is missing.")
        }
        let ownerProfile = try load(for: owner)
        let childPrefixExists = FileManager.default.fileExists(atPath: prefix.pfx.path(percentEncoded: false))
        guard ownerProfile.prefixOwner == nil,
              FileManager.default.fileExists(atPath: owner.pfx.path(percentEncoded: false)),
              let ownerArch = PrefixStore.arch(of: owner),
              !childPrefixExists || ownerArch == PrefixStore.arch(of: prefix) else {
            throw ProfileError.invalidOwner("The configured prefix owner is not a compatible root prefix.")
        }
        if childPrefixExists {
            guard let left = PrefixTools.lastBuild(of: prefix), let right = PrefixTools.lastBuild(of: owner),
                  left.build == right.build, left.display == right.display else {
                throw ProfileError.invalidOwner("The configured prefix owner uses a different or unverified compatibility build.")
            }
        }
        return owner
    }

    static func ownerReferenceExists(for prefix: WinePrefix) -> Bool {
        let file = url(for: prefix)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return false }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return true }
        return text.split(separator: "\n").contains { $0.hasPrefix("prefix_owner\t") }
    }

    static func resolveRoot(for prefix: WinePrefix) throws -> URL {
        try owner(of: prefix)?.pfx ?? prefix.pfx
    }

    static func isReferenced(_ candidate: WinePrefix, by prefixes: [WinePrefix]? = nil) -> Bool {
        let source = prefixes ?? PrefixStore.all(libraries: [candidate.library])
        return source.contains { other in
            guard other.id != candidate.id,
                  other.library.root.standardizedFileURL == candidate.library.root.standardizedFileURL,
                  FileManager.default.fileExists(atPath: url(for: other).path(percentEncoded: false)) else { return false }
            if rawOwnerReference(of: other) == candidate.appID { return true }
            let file = url(for: other)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return true }
            return (try? load(for: other)) == nil && text.split(separator: "\n").contains { $0.hasPrefix("prefix_owner\t") }
        }
    }

    private static func rawOwnerReference(of prefix: WinePrefix) -> String? {
        guard let text = try? String(contentsOf: url(for: prefix), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count >= 2, fields[0] == "prefix_owner", GameProfile.isNumericAppID(String(fields[1])) {
                return String(fields[1])
            }
        }
        // Malformed owner keys are conservatively handled by the destructive-action checks.
        return nil
    }

    static func referencingGames(_ candidate: WinePrefix, by prefixes: [WinePrefix]? = nil) -> [WinePrefix] {
        let source = prefixes ?? PrefixStore.all(libraries: [candidate.library])
        return source.filter { other in
            other.id != candidate.id && (try? load(for: other).prefixOwner) == candidate.appID
                && other.library.root.standardizedFileURL == candidate.library.root.standardizedFileURL
        }
    }

    static func graphicsBackends(for prefix: WinePrefix, runners: URL = SupportPaths.runners) -> [GameGraphics] {
        var available: [GameGraphics] = [.default]
        guard let tool = PrefixTools.tool(for: prefix) else { return available }
        let root = SupportPaths.clonedRoot(forBuild: tool.build, runners: runners)
        let windowsArch: String
        switch PrefixStore.arch(of: prefix) {
        case .arm64, .x86_64: windowsArch = "x86_64-windows"
        case .i386: windowsArch = "i386-windows"
        case nil: return available
        }
        for backend in [GameGraphics.d3dmetal, .dxvk, .dxmt] {
            let found = graphicsModulePaths(for: backend, windowsArch: windowsArch).contains {
                FileManager.default.fileExists(atPath: root.appending(path: $0).path(percentEncoded: false))
            }
            if found { available.append(backend) }
        }
        return available
    }

    static func availableGraphics(
        installed: [GameGraphics], runtimeTool: InstalledTool?
    ) -> [GameGraphics] {
        guard runtimeTool?.tool.flavor == .fex else { return installed }
        return installed.filter { $0 != .d3dmetal }
    }

    static func graphicsUnavailableMessage(
        for backend: GameGraphics, runtimeTool: InstalledTool?
    ) -> String? {
        guard backend == .d3dmetal, runtimeTool?.tool.flavor == .fex else { return nil }
        return "D3DMetal is saved in this profile, but the selected FEX runtime uses arm64 Wine and cannot load CrossOver’s x86_64 D3DMetal components. Choose Rosetta, DXMT, or Automatic before launching."
    }

    static func graphicsModulePaths(for backend: GameGraphics, windowsArch: String) -> [String] {
        switch backend {
        case .default: []
        case .d3dmetal: ["lib64/apple_gptk/external/libd3dshared.dylib"]
        case .dxvk: ["lib/dxvk/\(windowsArch)/d3d11.dll"]
        case .dxmt: [
            "lib/dxmt/\(windowsArch)/d3d11.dll",
            "lib/dxmt/\(windowsArch)/dxgi.dll",
            "lib/dxmt/\(windowsArch)/winemetal.dll",
        ]
        }
    }

    static func shareableOwners(for prefix: WinePrefix) -> [WinePrefix] {
        guard !PrefixStore.isInUse(prefix) else { return [] }
        return PrefixStore.all(libraries: [prefix.library]).filter { owner in
            owner.id != prefix.id
                && owner.library.root.standardizedFileURL == prefix.library.root.standardizedFileURL
                && PrefixStore.arch(of: owner) == PrefixStore.arch(of: prefix)
                && !PrefixStore.isInUse(owner)
                && isUnsharedRoot(owner)
                && {
                    guard let childBuild = PrefixTools.lastBuild(of: prefix),
                          let ownerBuild = PrefixTools.lastBuild(of: owner) else { return false }
                    return childBuild.build == ownerBuild.build && childBuild.display == ownerBuild.display
                }()
        }
    }

    private static func isUnsharedRoot(_ prefix: WinePrefix) -> Bool {
        guard let profile = try? load(for: prefix) else { return false }
        return profile.prefixOwner == nil
    }
}
