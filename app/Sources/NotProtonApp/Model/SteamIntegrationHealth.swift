import AppKit
import Foundation
import Observation

/// Checks are read-only; recovery is an explicit user action.
enum SteamIntegrationHealth {
    struct Paths: Sendable {
        var app: URL
        var client: URL
        var support: URL
        var bootstrapLog: URL

        static var live: Self {
            Self(app: SupportPaths.Steam.app, client: SupportPaths.Steam.innerClient,
                 support: SupportPaths.support,
                 bootstrapLog: SupportPaths.Steam.userData.appending(path: "logs/bootstrap_log.txt"))
        }
        var dylib: URL { SupportPaths.Steam.deployedDylib(inBundle: app) }
        var versionFile: URL { support.appending(path: "dylib.version") }
        var runtimeLog: URL { support.appending(path: "notproton.log") }
    }

    /// Compiled, declarative allowlist. No network/catalog input. These entries prove
    /// only the documented library layout, not native hooks or all Steam features.
    struct Layout: Sendable, Equatable {
        var name: String
        var build: String? // nil: the older build was not recorded in the evidence.
        var hashes: [String: String]
    }
    static let bundledLayouts: [Layout] = [
        Layout(name: "Steam library chunk layout", build: nil, hashes: [
            "steamui/library.js": "dbaed206d64c72f1d78c1566c59de60c77b8e002cb905d070805f4770a47aa05",
            "steamui/chunk~2dcc5aaf7.js": "f9606b111203c9140dcdd6fc016a0ee00e4c8406aeb786187c42873f08d071fb"
        ]),
        Layout(name: "Steam bundled library layout", build: "1791918634", hashes: [
            "steamui/sp.js": "5a28c25041d07e69cf591a414519e0cf970b6884c1a0106659dcd9f1fb9586f9"
        ])
    ]

    struct ProcessEvidence: Sendable {
        let pid: Int32
        let executable: URL
        let launchedAt: Date
    }

    enum Action: String, Sendable { case none, recoverIntegration, updateNotProton, setupIntegration }
    enum Status: String, Sendable { case steamMissing, needsSetup, unknownLayout, current, recoveryNeeded, unavailable }
    struct Observation: Sendable, Equatable {
        let value: String
        let source: URL
        let context: String
    }
    struct Snapshot: Sendable {
        var status: Status
        var action: Action
        var detail: String
        var layout: String?
        var verifiedDiskBuild: String?
        var verifiedDeployedVersion: String?
        var clientPath: URL?
        var currentProcessDylibVersion: String?
        var currentProcessPath: URL?
        /// Historical log observations never assert which process is currently alive.
        var lastLaunchedBuild: Observation?
        var lastLoadedDylib: Observation?
        var recordedDeploymentVersion: String?
        var deployedDylibSHA256: String?
        var differences: [String] = []
    }

    static func inspect(
        paths: Paths = .live,
        bundledVersion: String = AppVersion.bundled,
        bundledDylib: URL?,
        payload: PayloadState?,
        deployment: DeploymentContent.Status,
        layouts: [Layout] = bundledLayouts,
        process: ProcessEvidence? = nil
    ) -> Snapshot {
        let launch = lastMatch(in: paths.bootstrapLog,
            pattern: #"(?m)^([^\n]*).*Startup - Steam Client launched with: '([^'\n]+)'"#)
        // Steam's bootstrapper is 6.1; it is not the client build. Extract the
        // explicit installed version only from the latest launch's log section.
        let bootstrap = tail(paths.bootstrapLog)
        let session = bootstrap.components(separatedBy: "Startup - Steam Client launched with:").last ?? ""
        let build = capture(#"installed version ([0-9]+),"#, in: session)
        let loaded = lastMatch(in: paths.runtimeLog,
            pattern: #"(?m)^([^\n]*np_init: loaded into steam_osx \(pid [0-9]+\) version ([^\s]+))"#)
        var result = Snapshot(status: .unavailable, action: .none, detail: "Integration has not been verified.",
            lastLaunchedBuild: build.flatMap { value in
                guard launch != nil else { return nil }
                return Observation(value: value, source: paths.bootstrapLog,
                    context: "Last launch / installed-build log evidence: \(launch!.0)")
            },
            lastLoadedDylib: loaded.map { Observation(value: $0.1, source: paths.runtimeLog, context: $0.0) },
            recordedDeploymentVersion: SteamBundle.deployedVersion(at: paths.versionFile),
            deployedDylibSHA256: Digest.sha256IfPresent(paths.dylib))
        if let process, let loaded,
           process.executable.lastPathComponent == "steam_osx",
           process.executable.deletingLastPathComponent().resolvingSymlinksInPath() == paths.client.resolvingSymlinksInPath(),
           capture(#"\(pid ([0-9]+)\)"#, in: loaded.0) == String(process.pid) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            // Logs have local, second-resolution timestamps. Require the matching
            // PID's load entry to belong to this launch, preventing PID reuse.
            if let date = formatter.date(from: String(loaded.0.prefix(19))),
               date >= process.launchedAt.addingTimeInterval(-1), date <= Date() {
                result.currentProcessDylibVersion = loaded.1
                result.currentProcessPath = process.executable
            }
        }
        guard FileManager.default.fileExists(atPath: paths.app.path) else {
            result.status = .steamMissing
            result.detail = "Steam is missing at \(paths.app.path). Select the installed Steam app."
            return result
        }
        guard hasExistingSetup(paths) else {
            result.status = .needsSetup
            result.action = .setupIntegration
            result.detail = "Reconnect Steam to use NotProton again."
            return result
        }
        let matches = layouts.filter { layout in
            !layout.hashes.isEmpty && layout.hashes.allSatisfy { relative, hash in
                Digest.sha256IfPresent(paths.client.appending(path: relative)) == hash
            }
        }
        guard matches.count == 1 else {
            result.status = .unknownLayout
            result.action = .updateNotProton
            result.detail = "Unknown Steam UI layout. The installed JavaScript does not uniquely match the bundled verified hashes. A build number alone cannot establish compatibility. Update NotProton; Steam security updates remain available."
            return result
        }
        result.layout = matches[0].name
        result.verifiedDiskBuild = matches[0].build
        result.clientPath = paths.client
        // A historical build differing from a hash entry is reported, never used
        // to override exact file evidence or treated as the current running build.
        var differences: [String] = []
        let plist = SupportPaths.Steam.infoPlist(inBundle: paths.app)
        if SteamBundle.currentInsert(at: plist) != paths.dylib.path { differences.append("Steam's injection setting is missing or differs.") }
        if SteamBundle.currentControllerBlock(at: plist) != SteamBundle.controllerBlockValue { differences.append("Steam's controller setting differs.") }
        let dylibMatches = bundledDylib.map { source in
            (try? DeploymentContent.File(source: source, destination: paths.dylib,
                name: "notproton.dylib", allowsResigning: true).matches()) == true
        } ?? false
        if dylibMatches { result.verifiedDeployedVersion = bundledVersion }
        if !dylibMatches { differences.append("The deployed dylib is missing, stale, or cannot be verified against the bundled payload.") }
        if let payload, !payload.isSteamComplete { differences.append(payload.manifestProblem ?? "Missing Steam components: " + payload.missingSteamFiles.joined(separator: ", ")) }
        if payload == nil { differences.append("The account payload has not been checked.") }
        switch deployment {
        case .update(let names), .repair(let names), .unrecorded(let names): differences += names
        case .current: break
        case .newerInstalled:
            result.action = .updateNotProton
            differences.append("A newer NotProton deployment is installed.")
        case .unavailable(let reason): differences.append(reason)
        case .unchecked: differences.append("Deployment content has not been checked.")
        }
        result.differences = differences
        if differences.isEmpty {
            result.status = .current
            result.detail = "Verified library layout and current deployment files. Runtime loading and native hook compatibility are not established by this check."
        } else {
            result.status = .recoveryNeeded
            let canRecoverFiles = hasExistingSetup(paths)
            if result.action != .updateNotProton, canRecoverFiles,
               !deployment.blocksInstallation, deployment != .unchecked,
               payload?.manifestProblem == nil, payload != nil, bundledDylib != nil {
                result.action = .recoverIntegration
                result.detail = "Restore the files that connect Steam to NotProton. Quit Steam first; your existing files will be backed up."
            } else {
                result.action = .updateNotProton
                result.detail = "This version of NotProton cannot restore the connection. Check for a NotProton update."
            }
        }
        return result
    }

    /// One event-driven production check. Run on a worker task: hashing may read
    /// large JS files. Takes one running-app snapshot; changes no processes or settings.
    static func check() -> Snapshot {
        let clients = NSWorkspace.shared.runningApplications.compactMap { app -> ProcessEvidence? in
            guard let executable = app.executableURL, executable.lastPathComponent == "steam_osx",
                  let launchedAt = app.launchDate else { return nil }
            return ProcessEvidence(pid: app.processIdentifier, executable: executable, launchedAt: launchedAt)
        }
        do {
            let plan = try bundledRecoveryPlan()
            let changed = plan.files.filter {
                Digest.sha256IfPresent($0.destination) != $0.sha256
                    || ($0.executable && !FileManager.default.isExecutableFile(atPath: $0.destination.path))
            }.map { $0.destination.lastPathComponent }
            var deployment: DeploymentContent.Status = changed.isEmpty ? .current : .repair(changed)
            if let installed = SteamBundle.deployedVersion(),
               installed.compare(plan.version, options: .numeric) == .orderedDescending {
                deployment = .newerInstalled
            }
            if let installed = try DeploymentContent.readBuild(at: DeploymentContent.record(beside: SupportPaths.deployedVersion)),
               installed.version.compare(plan.version, options: .numeric) == .orderedDescending
                    || (installed.version == plan.version && plan.builtAt > 0 && installed.builtAt > plan.builtAt) {
                deployment = .newerInstalled
            }
            return inspect(bundledDylib: plan.files.first?.source,
                payload: PayloadInspector.inspect(), deployment: deployment,
                process: clients.count == 1 ? clients[0] : nil)
        } catch {
            return inspect(bundledDylib: nil, payload: nil, deployment: .unavailable(error.localizedDescription),
                process: clients.count == 1 ? clients[0] : nil)
        }
    }

    struct RecoveryFile: Sendable {
        let source: URL
        let destination: URL
        let sha256: String
        var executable = false
    }
    struct RecoveryPlan: Sendable {
        let files: [RecoveryFile]
        let version: String
        var builtAt: Int64 = 0
    }
    enum RecoveryOutcome: Sendable {
        case needsSetup
        case updateNotProton
        case recovered(backup: URL, files: [String])
    }

    /// Constructed ONLY from the app's bundled payload and installed tool registry.
    /// No catalogs, arbitrary downloads, runner patching, or setup changes.
    static func bundledRecoveryPlan(paths: Paths = .live) throws -> RecoveryPlan {
        let payload = try InstallPayload.locate()
        guard MachOBuild.identity(of: payload.dylib) != nil,
              try Shell.run("/usr/bin/codesign", ["--verify", "--strict", payload.dylib.path]).succeeded else {
            throw recoveryError("The bundled recovery files could not be verified. Update NotProton.")
        }
        let bridge = try BridgePayload.locate()
        var files: [(URL, URL, Bool)] = [
            (payload.dylib, paths.dylib, false),
            (payload.overlayShim, paths.support.appending(path: "overlay-shim.dylib"), false),
            (payload.iconmaker, paths.support.appending(path: "iconmaker"), true),
            (payload.appinfo, paths.support.appending(path: "appinfo"), true),
            (payload.gameIdentity, paths.support.appending(path: SupportPaths.gameIdentityName), false),
            (payload.sessionCheck, paths.support.appending(path: SupportPaths.sessionCheckName), true),
            (payload.gamePresentation, paths.support.appending(path: SupportPaths.gamePresentationName), true)
        ]
        for signature in payload.signatures {
            guard UInt64(signature.deletingPathExtension().lastPathComponent) != nil,
                  (try JSONSerialization.jsonObject(with: Data(contentsOf: signature))) is [String: Any] else {
                throw recoveryError("The bundled recovery files could not be verified. Update NotProton.")
            }
            files.append((signature, paths.support.appending(path: "signatures/macos.arm64/\(signature.lastPathComponent)"), false))
        }
        for item in bridge.sources {
            for relative in item.bridgePaths {
                files.append((item.source, paths.support.appending(path: "bridge/\(relative)"), false))
            }
        }
        for relative in payload.fonts {
            files.append((payload.fontsRoot.appending(path: relative), paths.support.appending(path: "fonts/\(relative)"), false))
        }
        // Existing launcher registrations only; never create/edit tool manifests.
        for tool in CompatToolList.installed() {
            files.append((payload.run, SupportPaths.Steam.compatTools.appending(path: "\(tool.name)/run"), true))
        }
        return try RecoveryPlan(files: files.map {
            RecoveryFile(source: $0.0, destination: $0.1, sha256: try Digest.sha256(of: $0.0), executable: $0.2)
        }, version: AppVersion.bundled, builtAt: payload.builtAt)
    }

    static func recover() throws -> URL {
        let outcome = try recover(paths: .live, plan: bundledRecoveryPlan(),
            launcherRoot: SupportPaths.Steam.compatTools, isSteamRunning: { SteamBundle.isRunning })
        let backup = try requireRecovered(outcome)
        guard check().status == .current else {
            throw recoveryError("Some files still need attention. Recovery backup: \(backup.path). Update NotProton or use Steam setup.")
        }
        return backup
    }

    /// The parent may discard the return value: every non-repair outcome throws.
    static func requireRecovered(_ outcome: RecoveryOutcome) throws -> URL {
        switch outcome {
        case .needsSetup: throw recoveryError("Steam needs setup. Choose Set up Steam to reconnect it.")
        case .updateNotProton: throw recoveryError("Recovery is unavailable. Update NotProton, then try again.")
        case .recovered(let backup, let files):
            guard !files.isEmpty else { throw recoveryError("No files needed recovery. Check the connection again.") }
            return backup
        }
    }

    /// Testable direct file recovery. Each replacement is atomic. All old files
    /// are backed up before the first write; a later failure restores prior files.
    /// `plan` is an internal dependency seam; production uses bundledRecoveryPlan.
    static func recover(
        paths: Paths, plan: RecoveryPlan, launcherRoot: URL? = nil,
        layouts: [Layout] = bundledLayouts,
        isSteamRunning: () -> Bool
    ) throws -> RecoveryOutcome {
        let fm = FileManager.default
        let lock = try DeploymentContent.acquireInstallationLock(
            in: paths.support.deletingLastPathComponent(), steamFolder: paths.app.deletingLastPathComponent())
        defer { lock.release() }
        func preflight() throws -> RecoveryOutcome? {
            guard !isSteamRunning() else { throw recoveryError("Quit Steam normally, then try again.") }
            guard hasExistingSetup(paths) else { return .needsSetup }
            let matches = layouts.filter { layout in
                !layout.hashes.isEmpty && layout.hashes.allSatisfy {
                    Digest.sha256IfPresent(paths.client.appending(path: $0.key)) == $0.value
                }
            }
            guard matches.count == 1 else { return .updateNotProton }
            if let installed = try DeploymentContent.readBuild(at: DeploymentContent.record(beside: paths.versionFile)),
               installed.version.compare(plan.version, options: .numeric) == .orderedDescending
                    || (installed.version == plan.version && plan.builtAt > 0 && installed.builtAt > plan.builtAt) { return .updateNotProton }
            if let installed = SteamBundle.deployedVersion(at: paths.versionFile),
               installed.compare(plan.version, options: .numeric) == .orderedDescending { return .updateNotProton }
            return nil
        }
        if let refusal = try preflight() { return refusal }
        guard !plan.files.isEmpty, plan.files.contains(where: { $0.destination == paths.dylib }) else {
            throw recoveryError("Recovery files are incomplete. Update NotProton.")
        }
        var destinations = Set<String>()
        for file in plan.files {
            // Refuse symlink traversal (including directory ancestors), duplicate
            // destinations and paths outside the explicitly permitted surfaces.
            let destination = file.destination.standardizedFileURL
            let path = destination.path
            let inSupport = path.hasPrefix(paths.support.standardizedFileURL.path + "/")
            let inLauncher = launcherRoot.map {
                let relative = String(path.dropFirst($0.standardizedFileURL.path.count + 1))
                return path.hasPrefix($0.standardizedFileURL.path + "/")
                    && relative.split(separator: "/").count == 2 && destination.lastPathComponent == "run"
            } ?? false
            guard destination == paths.dylib.standardizedFileURL || inSupport || inLauncher,
                  destination.resolvingSymlinksInPath().path == path,
                  file.source.resolvingSymlinksInPath().path == file.source.standardizedFileURL.path,
                  destinations.insert(path).inserted,
                  (try file.source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  try Digest.sha256(of: file.source) == file.sha256 else {
                throw recoveryError("Recovery files could not be verified. Update NotProton.")
            }
        }
        for file in plan.files where fm.fileExists(atPath: file.destination.path) {
            guard (try file.destination.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw recoveryError("A recovery destination is not a file. Update NotProton.")
            }
        }
        let changed = plan.files.filter {
            Digest.sha256IfPresent($0.destination) != $0.sha256
                || ($0.executable && !fm.isExecutableFile(atPath: $0.destination.path))
        }
        guard !changed.isEmpty else { throw recoveryError("No files needed recovery. Check the connection again.") }
        let backup = paths.support.deletingLastPathComponent().appending(path: "notproton-recovery-\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        let staging = backup.appending(path: "validated")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        // Snapshot Info.plist for audit only. It is NEVER written by recovery.
        try fm.copyItem(at: SupportPaths.Steam.infoPlist(inBundle: paths.app), to: backup.appending(path: "Info.plist"))
        var existed: [Bool] = []
        var originalHashes: [String?] = []
        for (index, file) in changed.enumerated() {
            let oldExists = fm.fileExists(atPath: file.destination.path)
            existed.append(oldExists)
            let original = backup.appending(path: "old-\(index)")
            if oldExists { try fm.copyItem(at: file.destination, to: original) }
            originalHashes.append(oldExists ? try Digest.sha256(of: original) : nil)
            let staged = staging.appending(path: String(index))
            try fm.copyItem(at: file.source, to: staged)
            guard try Digest.sha256(of: staged) == file.sha256 else { throw recoveryError("Recovery files changed. Try again.") }
            if file.executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path) }
        }
        let inventory = changed.enumerated().map { index, file in
            ["destination": file.destination.path, "backup": existed[index] ? "old-\(index)" : "absent", "sha256": file.sha256]
        }
        try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys])
            .write(to: backup.appending(path: "files.json"), options: .atomic)
        if let refusal = try preflight() { return refusal }
        var written: [Int] = []
        do {
            for (index, file) in changed.enumerated() {
                if let _ = try preflight() { throw recoveryError("Steam changed during recovery. Try again after closing Steam.") }
                guard file.destination.standardizedFileURL.resolvingSymlinksInPath() == file.destination.standardizedFileURL else {
                    throw recoveryError("A recovery destination changed. Try again.")
                }
                guard Digest.sha256IfPresent(file.destination) == originalHashes[index],
                      fm.fileExists(atPath: file.destination.path) == existed[index],
                      Digest.sha256IfPresent(staging.appending(path: String(index))) == file.sha256 else {
                    throw recoveryError("Recovery files changed. Your other changes were kept.")
                }
                try atomicReplace(file.destination, from: staging.appending(path: String(index)), step: "Recover Steam integration")
                written.append(index)
                guard Digest.sha256IfPresent(file.destination) == file.sha256 else { throw recoveryError("A recovered file could not be verified.") }
            }
            if let _ = try preflight() { throw recoveryError("Steam changed during recovery. Check again after closing Steam.") }
            for file in plan.files {
                guard file.destination.standardizedFileURL.resolvingSymlinksInPath() == file.destination.standardizedFileURL,
                      Digest.sha256IfPresent(file.destination) == file.sha256,
                      !file.executable || fm.isExecutableFile(atPath: file.destination.path) else {
                    throw recoveryError("A recovered file changed. Check the connection again.")
                }
            }
        } catch {
            var rollbackFailed = false
            for index in written.reversed() {
                do {
                    guard !isSteamRunning(),
                          changed[index].destination.standardizedFileURL.resolvingSymlinksInPath() == changed[index].destination.standardizedFileURL,
                          Digest.sha256IfPresent(changed[index].destination) == changed[index].sha256 else {
                        throw recoveryError("Close Steam and keep the backup for restoration.")
                    }
                    if existed[index] {
                        guard Digest.sha256IfPresent(backup.appending(path: "old-\(index)")) == originalHashes[index] else {
                            throw recoveryError("The recovery backup changed.")
                        }
                        try atomicReplace(changed[index].destination, from: backup.appending(path: "old-\(index)"), step: "Restore recovery backup")
                    } else { try fm.removeItem(at: changed[index].destination) }
                } catch { rollbackFailed = true }
            }
            throw recoveryError("Recovery did not finish. \(rollbackFailed ? "Some files need restoration from the backup." : "Earlier files were restored.") Backup: \(backup.path). \(error.localizedDescription)")
        }
        return .recovered(backup: backup, files: changed.map { $0.destination.path })
    }

    static func hasExistingSetup(_ paths: Paths) -> Bool {
        let plist = SupportPaths.Steam.infoPlist(inBundle: paths.app)
        return SteamBundle.currentInsert(at: plist) == paths.dylib.path
            && SteamBundle.currentControllerBlock(at: plist) == SteamBundle.controllerBlockValue
    }

    private static func recoveryError(_ detail: String) -> StepFailure {
        StepFailure(step: "Recover Steam integration", detail: detail)
    }

    /// Bounded log reads; missing/truncated/foreign formats remain unknown.
    private static func tail(_ url: URL) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd() else { return "" }
        try? file.seek(toOffset: end > 256 * 1024 ? end - 256 * 1024 : 0)
        return String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
    }
    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func lastMatch(in url: URL, pattern: String) -> (String, String)? {
        let text = tail(url)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let whole = Range(match.range(at: 0), in: text),
              let value = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[whole]), String(text[value]))
    }
}

@MainActor @Observable
final class SteamIntegrationHealthModel {
    private(set) var snapshot: SteamIntegrationHealth.Snapshot?
    private(set) var isBusy = false
    private(set) var error: String?
    private let check: @Sendable () async -> SteamIntegrationHealth.Snapshot
    private let repair: @Sendable () async throws -> Void

    init(check: @escaping @Sendable () async -> SteamIntegrationHealth.Snapshot,
         authorizedRepair: @escaping @Sendable () async throws -> Void) {
        self.check = check
        self.repair = authorizedRepair
    }
    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        snapshot = await check()
        if snapshot?.status == .current { error = nil }
    }
    func recoverIntegration() async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        // Recheck immediately before every user-triggered action.
        snapshot = await check()
        guard snapshot?.action == .recoverIntegration else { return }
        do { try await repair() } catch { self.error = error.localizedDescription }
        snapshot = await check()
    }
}
