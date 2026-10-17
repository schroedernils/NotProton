import CoreServices
import Darwin
import Foundation

/// Retain one instance for menu actions and application-activation refreshes. Every
/// operation, including discovery, helper execution and registration, runs on its serial
/// worker. Creating an instance has no side effects; the parent owns lifecycle wiring.
final class SteamGameShortcutSync: Sendable {
    struct Configuration: Sendable {
        let steamRoot: URL
        let support: URL
        let directory: URL

        static var live: Self {
            Self(steamRoot: SupportPaths.Steam.userData, support: SupportPaths.support,
                 directory: SupportPaths.home.appendingPathComponent("Applications/NotProton Games", isDirectory: true))
        }

        var libraryFolders: URL { steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf") }
    }

    typealias Result = SteamGameShortcuts.Result

    struct Dependencies: Sendable {
        var libraries: @Sendable (URL) throws -> [URL] = { vdf in
            PrefixStore.libraries(vdf: vdf).map(\.root)
        }
        var run: @Sendable (URL, [String], TimeInterval, Int) throws -> String = {
            try SteamGameShortcutSync.runHelper($0, arguments: $1, timeout: $2, outputLimit: $3)
        }
        var register: @Sendable (URL) throws -> Void = { app in
            let status = LSRegisterURL(app as CFURL, true)
            guard status == noErr else { throw Failure.registration(status) }
        }
    }

    enum Failure: Error, Equatable {
        case inventoryUnavailable, incompleteInventory, invalidMetadata, missingIcon(String)
        case nativeIconUnavailable(URL), helperFailed(Int32), helperTimedOut, helperOutputLimit
        case registration(OSStatus)
    }

    private let configuration: Configuration
    private let dependencies: Dependencies
    private let worker = DispatchQueue(label: "com.notproton.steam-game-shortcut-sync", qos: .utility)

    init(configuration: Configuration = .live, dependencies: Dependencies = Dependencies()) {
        self.configuration = configuration
        self.dependencies = dependencies
    }

    /// Queued calls serialize even across actor suspension. Cancellation is checked
    /// before enqueueing; an enqueued filesystem transaction finishes normally.
    /// Creates or updates shortcuts while retaining existing wrappers.
    func sync() async throws -> Result {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            worker.async { [self] in
                do { continuation.resume(returning: try performSync()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func performSync() throws -> Result {
        let roots = try completeLibraryRoots()
        try Self.requireAccessible(roots)
        return try SteamGameShortcuts.sync(
            libraryRoots: roots, directory: configuration.directory,
            metadata: { id, _, installation in
                let game = try metadata(appID: id, installation: installation)
                try Self.requireAccessible(roots)
                return game
            }, onMetadataFailure: { _, error in
                // Corrupt helper framing is a contract failure, not missing artwork.
                // Fail before publication rather than silently accepting malformed data.
                if let failure = error as? Failure,
                   failure == .invalidMetadata || failure == .helperOutputLimit { throw failure }
            }, beforePublish: {
                try Self.requireAccessible(roots)
            }, register: { app in
                try Self.requireAccessible(roots)
                try dependencies.register(app)
            })
    }

    /// PrefixStore's permissive fallback cannot establish a complete library inventory.
    /// Validate the complete modern VDF first and require its roots to match discovery.
    private func completeLibraryRoots() throws -> [URL] {
        let before = try Self.smallFile(configuration.libraryFolders, limit: 1_048_576)
        let document = try KeyValues.parse(before)
        guard case .section(let folders)? = document["libraryfolders"] else { throw Failure.incompleteInventory }
        var expected = Set<String>()
        for (index, value) in folders {
            guard !index.isEmpty, index.utf8.allSatisfy({ (48...57).contains($0) }),
                  case .section(let entry) = value, case .string(let path)? = entry["path"],
                  path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw Failure.incompleteInventory }
            expected.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        guard !expected.isEmpty else { throw Failure.incompleteInventory }
        let discovered = try dependencies.libraries(configuration.libraryFolders)
        guard discovered.allSatisfy(\.isFileURL),
              Set(discovered.map { $0.standardizedFileURL.path }) == expected,
              try Self.smallFile(configuration.libraryFolders, limit: 1_048_576) == before
        else { throw Failure.incompleteInventory }
        // Include the client library even if a Steam version omits it from the VDF.
        var roots = discovered
        if !expected.contains(configuration.steamRoot.standardizedFileURL.path) { roots.append(configuration.steamRoot) }
        return roots
    }

    private static func requireAccessible(_ roots: [URL]) throws {
        for root in roots {
            let steamapps = root.appendingPathComponent("steamapps", isDirectory: true)
            guard FileManager.default.isReadableFile(atPath: steamapps.path),
                  (try? steamapps.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { throw Failure.inventoryUnavailable }
            _ = try FileManager.default.contentsOfDirectory(atPath: steamapps.path)
        }
    }

    private func metadata(appID: String, installation: URL?) throws -> SteamGameShortcuts.Game {
        _ = try SteamGameShortcuts.bundleIdentifier(appID: appID)
        let info = try dependencies.run(configuration.support.appendingPathComponent("appinfo"),
            [configuration.steamRoot.appendingPathComponent("appcache/appinfo.vdf").path, appID], 10, 8192)
        let fields = try Self.fields(info)
        guard let name = fields["name"], !name.trimmingCharacters(in: .whitespaces).isEmpty,
              name.count <= 512, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw Failure.invalidMetadata }
        let declaredNative = fields["oslist"]?.split(separator: ",")
            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "macos" }) == true
        if declaredNative, let native = try Self.nativeApplication(in: installation) {
            let icon = try Self.nativeIcon(native)
            return .init(appID: appID, name: name, iconURL: icon)
        }
        let cached = configuration.support.appendingPathComponent("launchers/\(appID)/game.icns")
        if !Self.validIcon(cached) {
            let output = try dependencies.run(configuration.support.appendingPathComponent("game-presentation"),
                [configuration.steamRoot.path, appID], 20, 8192)
            let presentation = try Self.fields(output)
            // Accept only the helper's documented per-AppID output, never an arbitrary
            // path returned in helper text. Never pass generated ICNS back to iconmaker.
            guard let path = presentation["icon"], path.hasPrefix("/"),
                  URL(fileURLWithPath: path).standardizedFileURL.path == cached.standardizedFileURL.path,
                  Self.validIcon(cached)
            else { throw Failure.missingIcon(appID) }
        }
        return .init(appID: appID, name: name, iconURL: cached)
    }

    private static func fields(_ text: String) throws -> [String: String] {
        guard text.utf8.count <= 8192 else { throw Failure.helperOutputLimit }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { throw Failure.invalidMetadata }
            let key = String(line[..<separator])
            guard fields[key] == nil else { throw Failure.invalidMetadata }
            fields[key] = String(line[line.index(after: separator)...])
        }
        return fields
    }

    /// Only the installation itself and its immediate children are candidates. Multiple
    /// bundles are ambiguous (e.g. a game and editor); preserve the existing shortcut.
    private static func nativeApplication(in installation: URL?) throws -> URL? {
        guard let installation else { return nil }
        let fm = FileManager.default
        guard (try? installation.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        if installation.pathExtension.lowercased() == "app" { return installation }
        var candidates: [URL] = []
        let names = try fm.contentsOfDirectory(atPath: installation.path)
        guard names.count <= 4096 else { throw Failure.invalidMetadata }
        for name in names where URL(fileURLWithPath: name).pathExtension.lowercased() == "app" {
            let child = installation.appendingPathComponent(name)
            let canonical = child.resolvingSymlinksInPath()
            guard canonical.deletingLastPathComponent() == installation,
                  (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { throw Failure.nativeIconUnavailable(child) }
            candidates.append(child)
        }
        guard candidates.count <= 1 else { throw Failure.nativeIconUnavailable(installation) }
        return candidates.first
    }

    private static func nativeIcon(_ app: URL) throws -> URL {
        guard app.isFileURL, app.pathExtension.lowercased() == "app",
              let data = try? smallFile(app.appendingPathComponent("Contents/Info.plist"), limit: 1_048_576),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let filename = info["CFBundleIconFile"] as? String, !filename.isEmpty,
              !filename.contains("/"), filename != ".", filename != ".."
        else { throw Failure.nativeIconUnavailable(app) }
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true).resolvingSymlinksInPath()
        let icon = resources.appendingPathComponent(filename.hasSuffix(".icns") ? filename : filename + ".icns")
            .resolvingSymlinksInPath()
        guard icon.deletingLastPathComponent().path == resources.path, validIcon(icon) else {
            throw Failure.nativeIconUnavailable(app)
        }
        return icon
    }

    private static func validIcon(_ url: URL) -> Bool {
        guard let data = try? smallFile(url, limit: 32 * 1_048_576), data.count >= 8,
              data.prefix(4) == Data("icns".utf8) else { return false }
        return data[4..<8].reduce(UInt64(0), { ($0 << 8) | UInt64($1) }) == UInt64(data.count)
    }

    private static func smallFile(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.helperOutputLimit }
        return data
    }

    /// A dedicated process group bounds shell descendants as well as the helper. Capture
    /// only bounded stdout; stderr is discarded and stdin is closed. No shell interpolation.
    static func runHelper(_ executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) throws -> String {
        guard executable.isFileURL, !executable.path.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              timeout > 0, timeout.isFinite, outputLimit > 0, outputLimit <= 1_048_576 else {
            throw Failure.invalidMetadata
        }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key })
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executable.path, &actions, &attributes,
                    UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        guard spawned == 0 else { throw Failure.helperFailed(spawned) }
        // The parent's write end must close now, so EOF can be observed. Replace it
        // with -1 so the scope cleanup cannot close a subsequently reused descriptor.
        close(descriptors[1]); descriptors[1] = -1
        var reaped = false
        defer {
            if !reaped {
                kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var eof = false
        var status: Int32 = 0
        while true {
            let count = read(descriptors[0], &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= outputLimit else { throw Failure.helperOutputLimit }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { throw POSIXError(.EIO) }
            // Keep the child unreaped while a descendant holds stdout, reserving its
            // PID/process-group identity until cleanup can safely kill that group.
            if eof && !reaped {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { reaped = true }
                else if waited < 0 && errno != EINTR { throw POSIXError(.ECHILD) }
            }
            if reaped && eof { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.helperTimedOut }
            if count <= 0 { usleep(10_000) }
        }
        guard status == 0 else { throw Failure.helperFailed(status) }
        guard let text = String(data: output, encoding: .utf8) else { throw Failure.invalidMetadata }
        return text
    }

    private indirect enum KeyValues {
        case string(String), section([String: KeyValues])

        static func parse(_ data: Data) throws -> [String: KeyValues] {
            guard let text = String(data: data, encoding: .utf8) else { throw Failure.incompleteInventory }
            let chars = Array(text)
            var i = 0
            func token() throws -> String? {
                while i < chars.count {
                    if chars[i].isWhitespace { i += 1; continue }
                    if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                        while i < chars.count && chars[i] != "\n" { i += 1 }
                        continue
                    }
                    break
                }
                guard i < chars.count else { return nil }
                let first = chars[i]; i += 1
                if first == "{" || first == "}" { return String(first) }
                guard first == "\"" else { throw Failure.incompleteInventory }
                var result = "\""
                while i < chars.count {
                    let ch = chars[i]; i += 1
                    if ch == "\"" { return result }
                    if ch == "\\" {
                        guard i < chars.count, chars[i] == "\\" || chars[i] == "\"" else { throw Failure.incompleteInventory }
                        result.append(chars[i]); i += 1
                    } else { result.append(ch) }
                }
                throw Failure.incompleteInventory
            }
            func section(_ depth: Int) throws -> [String: KeyValues] {
                guard depth < 32 else { throw Failure.incompleteInventory }
                var result: [String: KeyValues] = [:]
                while let key = try token() {
                    if key == "}" {
                        guard depth > 0 else { throw Failure.incompleteInventory }
                        return result
                    }
                    guard key.hasPrefix("\""), result[String(key.dropFirst())] == nil,
                          let value = try token() else { throw Failure.incompleteInventory }
                    if value == "{" { result[String(key.dropFirst())] = .section(try section(depth + 1)) }
                    else {
                        guard value.hasPrefix("\"") else { throw Failure.incompleteInventory }
                        result[String(key.dropFirst())] = .string(String(value.dropFirst()))
                    }
                }
                guard depth == 0 else { throw Failure.incompleteInventory }
                return result
            }
            return try section(0)
        }
    }
}
