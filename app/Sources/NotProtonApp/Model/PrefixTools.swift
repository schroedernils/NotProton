// Shortcuts to launch the Wine tools (winecfg/regedit/task manager) against
// a selected prefix, opens prefix directory in finder, etc.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum WineTool: String, CaseIterable, Sendable {
    case winecfg
    case regedit
    case taskmgr

    var label: String {
        switch self {
        case .winecfg: String(localized: "Wine Configuration")
        case .regedit: String(localized: "Registry Editor")
        case .taskmgr: String(localized: "Task Manager")
        }
    }
}

// The logs compat_run.sh writes for a game.
enum PrefixLog: CaseIterable, Sendable {
    case launch
    case wine

    var label: String {
        switch self {
        case .launch: String(localized: "Launch Log")
        case .wine: String(localized: "Wine Log")
        }
    }

    func url(for prefix: WinePrefix, launchers: URL = SupportPaths.launchers) -> URL {
        switch self {
        case .launch: prefix.root.appending(path: "notproton-run.log")
        case .wine: launchers.appending(path: prefix.appID).appending(path: "notproton-wine.log")
        }
    }
}

// What compat_run.sh writes to notproton-build when a tool first runs a prefix.
struct PrefixBuildRecord: Sendable, Equatable {
    let build: String
    let display: String?
}

enum PrefixTools {

    static let buildRecordName = "notproton-build"

    static func buildRecord(of prefix: WinePrefix) -> PrefixBuildRecord? {
        let file = prefix.root.appending(path: buildRecordName)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let build = lines.first, !build.isEmpty else { return nil }
        let display = lines.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
        return PrefixBuildRecord(build: build, display: display)
    }

    static func lastBuild(of prefix: WinePrefix, runners: URL = SupportPaths.runners) -> PrefixBuildRecord? {
        if let record = buildRecord(of: prefix) { return record }
        let file = prefix.pfx.appending(path: ".update-timestamp")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let field = text.split(whereSeparator: \.isWhitespace).first,
              let updated = Int(field)
        else { return nil }
        for build in RunnerStore.clonedBuilds(in: runners) {
            let inf = SupportPaths.clonedRoot(forBuild: build, runners: runners)
                .appending(path: "share/wine/wine.inf")
            let modified = (try? FileManager.default.attributesOfItem(
                atPath: inf.path(percentEncoded: false))[.modificationDate]) as? Date
            if let modified, Int(modified.timeIntervalSince1970) == updated {
                return PrefixBuildRecord(build: build, display: nil)
            }
        }
        return PrefixBuildRecord(build: "", display: String(localized: "another version of CrossOver"))
    }

    static func writeBuildRecord(_ tool: InstalledTool, for prefix: WinePrefix) throws {
        let file = prefix.root.appending(path: buildRecordName)
        try atomicReplace(file, with: Data("\(tool.build)\n\(tool.display)\n".utf8), step: String(localized: "Record prefix build"))
    }

    static func tool(
        for prefix: WinePrefix, among tools: [InstalledTool] = CompatToolList.installed(),
        runners: URL = SupportPaths.runners
    ) -> InstalledTool? {
        let arch = PrefixStore.arch(of: prefix)
        func byArch(_ candidates: [InstalledTool]) -> InstalledTool? {
            guard let arch else { return candidates.first }
            return candidates.first { $0.tool.prefixArch == arch }
        }
        guard let record = lastBuild(of: prefix, runners: runners) else { return byArch(tools) }
        let served = tools.filter { $0.build == record.build }
        if let named = served.first(where: { $0.display == record.display }),
           arch == nil || named.tool.prefixArch == arch {
            return named
        }
        return byArch(served)
    }

    static func resolvedTool(
        step: String, for prefix: WinePrefix, among tools: [InstalledTool] = CompatToolList.installed()
    ) throws -> InstalledTool {
        if let found = tool(for: prefix, among: tools) { return found }
        if let record = lastBuild(of: prefix) {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(prefix.title) was last run by \(record.display ?? "build \(record.build)"), which is no longer set up. Rebuild the prefix first.")
            )
        }
        throw StepFailure(step: step, detail: String(localized: "No compatibility tool is set up."))
    }

    static func syncBackend(prefix: WinePrefix) -> String {
        let marker = prefix.root.appending(path: "notproton-msync")
        let recorded = try? String(contentsOf: marker, encoding: .utf8)
        return recorded?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "1" : "0"
    }

    static func environment(
        prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor = .fex
    ) throws -> [String: String] {
        let root = runner.path(percentEncoded: false)
        var environment = ProcessInfo.processInfo.environment
        environment["CX_ROOT"] = root
        environment["CX_HOME"] = SupportPaths.applicationSupport
            .appending(path: "CrossOver").path(percentEncoded: false)
        let wine = layout(runner: runner, flavor: flavor)
        environment["WINELOADER"] = wine.loader.path(percentEncoded: false)
        environment["WINESERVER"] = wine.server.path(percentEncoded: false)
        environment["WINEDLLPATH"] = "\(root)/lib/wine/x86_64-windows:"
            + wine.unixDir.path(percentEncoded: false)
        let resolved = try GameProfileStore.resolveRoot(for: prefix)
        environment["WINEPREFIX"] = resolved.path(percentEncoded: false)
        let profile = try GameProfileStore.load(for: prefix)
        let inherited = ProcessInfo.processInfo.environment
        if inherited["WINEMSYNC"] == nil {
            let profileSync = profile.msync
            environment["WINEMSYNC"] = profileSync == .default
                ? syncBackend(prefix: prefix) : profileSync.rawValue
        }
        if inherited["CX_GRAPHICS_BACKEND"] == nil,
           let backend = profile.graphics.runtimeBackend {
            environment["CX_GRAPHICS_BACKEND"] = backend
        }
        if inherited["NOTPROTON_RETINA"] == nil, profile.retina != .default {
            let value = profile.retina
            environment["NOTPROTON_RETINA"] = value.rawValue
        }
        if inherited["NOTPROTON_HIDE_LAUNCHER_TILE"] == nil,
           profile.hideLauncherTile != .default {
            let value = profile.hideLauncherTile
            environment["NOTPROTON_HIDE_LAUNCHER_TILE"] = value.rawValue
        }
        if inherited["SteamDisableOverlayDPIScaling"] == nil,
           profile.overlayDPI == .disabled {
            environment["SteamDisableOverlayDPIScaling"] = "1"
        }
        if inherited["NOTPROTON_RELEASE_DISPLAYS_FULLSCREEN"] == nil,
           profile.fullscreenDisplayCapture == .released {
            environment["NOTPROTON_RELEASE_DISPLAYS_FULLSCREEN"] = "1"
        }
        environment["PATH"] = "\(root)/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    static func checkedEnvironment(
        prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor = .fex
    ) throws -> [String: String] {
        try environment(prefix: prefix, runner: runner, flavor: flavor)
    }

    static func loader(runner: URL, flavor: CompatTool.Flavor = .fex) -> URL {
        layout(runner: runner, flavor: flavor).loader
    }

    struct WineLayout {
        let loader: URL
        let server: URL
        let unixDir: URL
    }

    static func layout(runner: URL, flavor: CompatTool.Flavor = .fex) -> WineLayout {
        let fm = FileManager.default
        let bin = runner.appending(path: "bin")
        func executable(_ url: URL) -> Bool {
            fm.isExecutableFile(atPath: url.path(percentEncoded: false))
        }

        let arm = runner.appending(path: "lib/wine/aarch64-unix")
        let armLoader = arm.appending(path: "wine.app/Contents/MacOS/wine")
        let armServer = bin.appending(path: "wineserver-arm64")
        if flavor == .fex, executable(armLoader), executable(armServer) {
            return WineLayout(loader: armLoader, server: armServer, unixDir: arm)
        }

        let unix = runner.appending(path: "lib/wine/x86_64-unix")
        let server = bin.appending(path: "wineserver")
        return WineLayout(
            loader: unix.appending(path: "wine"),
            server: executable(server) ? server : bin.appending(path: "wineserver-x86"),
            unixDir: unix
        )
    }

    private static func readyLoader(
        step: String, prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor
    ) throws -> URL {
        let loader = loader(runner: runner, flavor: flavor)
        guard FileManager.default.isExecutableFile(atPath: loader.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "No compatibility tool at \(loader.path(percentEncoded: false)). Use Set Up Compatibility Tool first.")
            )
        }
        let resolved: URL
        do { resolved = try GameProfileStore.resolveRoot(for: prefix) }
        catch {
            throw StepFailure(step: step, detail: error.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(prefix.title) has no prefix at \(prefix.pfx.path(percentEncoded: false)).")
            )
        }
        return loader
    }

    static func launch(_ tool: WineTool, in prefix: WinePrefix) throws {
        let chosen = try resolvedTool(step: String(localized: "Open \(tool.label)"), for: prefix)
        try launch(
            tool, in: prefix, runner: SupportPaths.clonedRoot(forBuild: chosen.build),
            flavor: chosen.tool.flavor
        )
    }

    static func launch(
        _ tool: WineTool, in prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor = .fex
    ) throws {
        try refuseWhileSharedPrefixInUse(prefix, step: "Open \(tool.label)")
        try requireValidOwner(prefix, step: "Open \(tool.label)")
        let loader = try readyLoader(
            step: "Open \(tool.label)", prefix: prefix, runner: runner, flavor: flavor
        )
        try Shell.detach(
            loader.path(percentEncoded: false),
            [tool.rawValue],
            environment: try checkedEnvironment(prefix: prefix, runner: runner, flavor: flavor)
        )
    }

    static func run(_ executable: URL, in prefix: WinePrefix) throws {
        let chosen = try resolvedTool(step: "Run \(executable.lastPathComponent)", for: prefix)
        try run(
            executable, in: prefix, runner: SupportPaths.clonedRoot(forBuild: chosen.build),
            flavor: chosen.tool.flavor
        )
    }

    static func run(
        _ executable: URL,
        in prefix: WinePrefix,
        runner: URL,
        flavor: CompatTool.Flavor = .fex
    ) throws {
        let step = String(localized: "Run \(executable.lastPathComponent)")
        try refuseWhileSharedPrefixInUse(prefix, step: step)
        try requireValidOwner(prefix, step: step)
        let loader = try readyLoader(step: step, prefix: prefix, runner: runner, flavor: flavor)
        guard FileManager.default.fileExists(atPath: executable.path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: String(localized: "No file at \(executable.path(percentEncoded: false))."))
        }
        guard let arguments = arguments(for: executable) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(executable.lastPathComponent) is not a Windows program. Pick an exe, msi, bat or cmd file.")
            )
        }

        let profile = try GameProfileStore.load(for: prefix)
        try Shell.detach(
            loader.path(percentEncoded: false),
            arguments,
            environment: try checkedEnvironment(prefix: prefix, runner: runner, flavor: flavor),
            currentDirectory: profile.launchCwd.map { URL(filePath: $0) } ?? executable.deletingLastPathComponent()
        )
    }

    // Winetricks is LGPL, so it is downloaded rather than shipped.
    static let winetricksRelease = "20260125"
    static let winetricksSHA256 = "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b"
    static let winetricksLogName = "winetricks.log"

    static func winetricksVerbs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func winetricks(_ verbs: [String], in prefix: WinePrefix) async throws -> URL {
        let step = String(localized: "Run Winetricks")
        let chosen = try resolvedTool(step: step, for: prefix)
        let script = try await PinnedDownload.obtain(
            file: "winetricks",
            sha256: winetricksSHA256,
            bases: [URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(winetricksRelease)/src")!],
            into: SupportPaths.winetricksDownloads,
            step: step,
            from: "GitHub"
        )
        return try winetricks(
            verbs, in: prefix, script: script,
            runner: SupportPaths.clonedRoot(forBuild: chosen.build), flavor: chosen.tool.flavor
        )
    }

    static func winetricks(
        _ verbs: [String], in prefix: WinePrefix, script: URL, runner: URL,
        flavor: CompatTool.Flavor = .fex
    ) throws -> URL {
        let step = String(localized: "Run Winetricks")
        guard !verbs.isEmpty else {
            throw StepFailure(step: step, detail: String(localized: "Enter at least one verb, like vcrun2022."))
        }
        if let refused = verbs.first(where: { $0 == "annihilate" || $0.hasPrefix("prefix=") || $0.hasPrefix("-") }) {
            throw StepFailure(step: step, detail: String(localized: "NotProton does not run \(refused) with Winetricks."))
        }
        try refuseWhileSharedPrefixInUse(prefix, step: step)
        try requireValidOwner(prefix, step: step)
        guard !PrefixStore.isInUse(prefix) else {
            throw StepFailure(step: step, detail: String(localized: "\(prefix.title) is running. Quit the game first."))
        }
        let loader = try readyLoader(step: step, prefix: prefix, runner: runner, flavor: flavor)
        var environment = try checkedEnvironment(prefix: prefix, runner: runner, flavor: flavor)
        environment["WINE"] = loader.path(percentEncoded: false)
        let log = prefix.root.appending(path: winetricksLogName)
        let status = try Shell.logged(
            "/bin/sh", [script.path(percentEncoded: false), "-q"] + verbs,
            environment: environment, to: log
        )
        _ = try? Shell.run(layout(runner: runner, flavor: flavor).server.path(percentEncoded: false), ["-w"], environment: environment)
        guard status == 0 else {
            throw StepFailure(
                step: step,
                detail: String(localized: "Winetricks stopped with status \(status). Its output is in \(log.path(percentEncoded: false)).")
            )
        }
        return log
    }

    static func arguments(for executable: URL) -> [String]? {
        let path = executable.path(percentEncoded: false)
        switch executable.pathExtension.lowercased() {
        case "exe", "bat", "cmd": return [path]
        case "msi": return ["msiexec", "/i", path]
        default: return nil
        }
    }

    private static func refuseWhileSharedPrefixInUse(_ prefix: WinePrefix, step: String) throws {
        let root = try GameProfileStore.resolveRoot(for: prefix)
        if root != prefix.pfx, PrefixStore.isInUse(prefix) {
            throw StepFailure(step: step, detail: String(localized: "The shared prefix is in use. Quit its game before launching another helper."))
        }
    }

    private static func requireValidOwner(_ prefix: WinePrefix, step: String) throws {
        do { _ = try GameProfileStore.resolveRoot(for: prefix) }
        catch { throw StepFailure(step: step, detail: error.localizedDescription) }
    }

    static var runnableTypes: [UTType] {
        ["exe", "msi", "bat", "cmd"].compactMap { UTType(filenameExtension: $0) }
    }

    static func hasLog(_ log: PrefixLog, for prefix: WinePrefix) -> Bool {
        FileManager.default.fileExists(atPath: log.url(for: prefix).path(percentEncoded: false))
    }

    static func open(_ log: PrefixLog, for prefix: WinePrefix) {
        NSWorkspace.shared.open(log.url(for: prefix))
    }

    static func reveal(_ prefix: WinePrefix) {
        NSWorkspace.shared.selectFile(
            prefix.pfx.path(percentEncoded: false),
            inFileViewerRootedAtPath: prefix.root.path(percentEncoded: false)
        )
    }

    static func reveal(at url: URL) {
        NSWorkspace.shared.selectFile(
            url.path(percentEncoded: false),
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path(percentEncoded: false)
        )
    }

    static func deleteBackup(_ backup: URL) throws {
        try WriteRefused.catching(backup.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: backup)
        }
    }

    static func delete(_ prefix: WinePrefix) throws {
        guard !GameProfileStore.ownerReferenceExists(for: prefix),
              !GameProfileStore.isReferenced(prefix) else {
            throw StepFailure(step: String(localized: "Delete prefix"), detail: String(localized: "This prefix is shared. Remove its game profile references before deleting it."))
        }
        if GameProfileStore.isReferenced(prefix) {
            let games = GameProfileStore.referencingGames(prefix).map(\.title).joined(separator: ", ")
            throw StepFailure(step: String(localized: "Delete prefix"), detail: String(localized: "This prefix is shared by \(games). Remove those profile references first."))
        }
        guard !PrefixStore.isInUse(prefix) else {
            throw StepFailure(
                step: String(localized: "Delete prefix"),
                detail: String(localized: "\(prefix.title) is running. Quit the game first.")
            )
        }
        try WriteRefused.catching(prefix.root) {
            try FileManager.default.removeItem(at: prefix.root)
        }
    }

    static func refuseIfShared(_ prefix: WinePrefix, step: String) throws {
        guard !GameProfileStore.ownerReferenceExists(for: prefix) else {
            throw StepFailure(step: step, detail: String(localized: "This game uses a shared prefix. Rebuild its owner prefix instead."))
        }
        guard !GameProfileStore.isReferenced(prefix) else {
            throw StepFailure(step: step, detail: String(localized: "This prefix is shared by another game and cannot be rebuilt."))
        }
    }
}
