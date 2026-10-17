import Foundation
import Darwin

/// Offline importer. No Steam API/URL invocation is treated as evidence of acceptance.
/// Integrators should present `WindowsGameImportView`; Steam must remain closed throughout saving.
enum WindowsGameImport {
    enum Failure: Error, LocalizedError, Equatable {
        case running, invalidSelection, unavailableTool, unsafeFiles, malformed, collision, changed, recovery, io
        var errorDescription: String? {
            switch self {
            case .running: "Quit Steam and any games, then try again."
            case .invalidSelection: "Choose an existing Windows game and enter a name without quotes or control characters."
            case .unavailableTool: "The selected compatibility tool is no longer installed. Open Settings to set it up."
            case .unsafeFiles: "This Steam folder cannot be safely updated. Choose an existing Steam account."
            case .malformed: "Steam’s library settings have an unsupported format. Nothing was imported."
            case .collision: "An existing Steam entry conflicts with this game. It has been left unchanged."
            case .changed: "Steam’s library changed during import. Close Steam and try again."
            case .recovery: "An interrupted import needs recovery. Keep Steam closed and choose Restore an interrupted import below."
            case .io: "The import could not be saved. Check access to the Steam folder and try again."
            }
        }
    }

    struct Request: Sendable {
        let executable: URL
        let name: String
        let toolName: String
    }
    struct Result: Sendable {
        let appID: UInt32
        let updated: Bool
        /// Contains byte-for-byte originals and absent-file markers; may contain private Steam settings.
        let backup: URL
    }
    struct Receipt: Codable, Equatable {
        let appID: UInt32
        let executable: String
        let name: String
        let tool: String
    }

    /// The caller explicitly selects an account; never infer it from login credentials or last login.
    static func accounts(steamRoot: URL = SupportPaths.Steam.userData) -> [String] {
        let base = steamRoot.appendingPathComponent("userdata")
        return ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { numeric($0.lastPathComponent) && $0.lastPathComponent != "0"
                && (try? safePath($0.appendingPathComponent("config/shortcuts.vdf"))) != nil
                && (try? $0.appendingPathComponent("config").resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted()
    }

    /// SRM's actual implementation (not a claim that current Steam itself still generates deterministic IDs):
    /// https://github.com/SteamGridDB/steam-rom-manager/blob/master/src/lib/helpers/steam/generate-app-id.ts
    /// shortcuts.vdf stores these 32 bits (signed in some serializers); config.vdf uses unsigned decimal.
    /// Local evidence: dylib/feats/compat.c SetCompatToolMapping(uint32_t appid, ..., priority=250).
    static func shortcutID(quotedExecutable: String, name: String) -> UInt32 {
        crc32(Data((quotedExecutable + name).utf8)) | 0x80000000
    }
    static func crc32(_ bytes: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
    private static func numeric(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) } && UInt32(text) != nil
    }

    static func save(
        _ request: Request, steamRoot: URL = SupportPaths.Steam.userData, accountID: String
    ) throws -> Result {
        do {
            return try perform(request, steamRoot: steamRoot, accountID: accountID)
        } catch let failure as Failure { throw failure }
        catch { throw Failure.io } // Never surface Foundation errors containing config contents or credentials.
    }

    static func clientRunning() throws -> Bool {
        // Unlike a Boolean ps helper, a failed process listing must never mean "stopped".
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-A", "-o", "comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { throw Failure.running }
        return output.split(separator: "\n").contains {
            let name = URL(filePath: $0.trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased()
            return ["steam", "steam_osx", "steamwebhelper", "steam helper"].contains(name)
        }
    }

    private static func perform(
        _ request: Request, steamRoot: URL, accountID: String
    ) throws -> Result {
        let fm = FileManager.default
        func stopped() throws { if try clientRunning() { throw Failure.running } }
        try stopped()
        let exe = request.executable
        let path = exe.path
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        func clean(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count < 4096 && !value.contains("\"") && !value.contains("\\") &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard exe.isFileURL, exe.pathExtension.lowercased() == "exe", clean(path), clean(name),
              (try? exe.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              fm.isReadableFile(atPath: path) else { throw Failure.invalidSelection }
        guard CompatToolList.installed().contains(where: { $0.name == request.toolName }), (request.toolName == "notproton" || request.toolName.hasPrefix("notproton-")),
              request.toolName.utf8.allSatisfy({ [45, 46, 95].contains($0) || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { throw Failure.unavailableTool }
        guard numeric(accountID), accountID != "0", steamRoot.isFileURL else { throw Failure.unsafeFiles }
        let root = steamRoot
        let config = root.appendingPathComponent("config/config.vdf")
        let userConfig = root.appendingPathComponent("userdata/\(accountID)/config")
        let shortcuts = userConfig.appendingPathComponent("shortcuts.vdf")
        let receiptsURL = userConfig.appendingPathComponent("notproton-imports.json")
        let urls = [shortcuts, config, receiptsURL]
        for url in urls { try safePath(url) }
        guard fm.fileExists(atPath: config.path), fm.fileExists(atPath: userConfig.path) else { throw Failure.unsafeFiles }
        // Serialize our imports across accounts/processes. This cannot lock Steam itself; rechecks below
        // catch observed starts/changes. Steam must stay closed until this synchronous call returns.
        let lockURL = config.deletingLastPathComponent().appendingPathComponent(".notproton-import.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unsafeFiles }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.changed }
        let configDir = config.deletingLastPathComponent()
        for entry in try fm.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix("notproton-import-") {
            if fm.fileExists(atPath: entry.appendingPathComponent("pending").path) { throw Failure.recovery }
        }
        try stopped()
        let originals = try urls.map { try readOptional($0) }
        let originalShortcuts = originals[0] ?? BinaryVDF.encode([.object("shortcuts", [])])
        var document = try BinaryVDF.decode(originalShortcuts)
        guard document.count == 1, document[0].key.lowercased() == "shortcuts",
              var entries = document[0].children else { throw Failure.malformed }
        var ids = Set<UInt32>()
        for entry in entries {
            guard numeric(entry.key), UInt32(entry.key).map(String.init) == entry.key, let fields = entry.children,
                  let id = fields.field("appid")?.uint32,
                  fields.field("appname")?.string != nil, fields.field("exe")?.string != nil,
                  fields.field("startdir")?.string != nil, ids.insert(id).inserted else { throw Failure.malformed }
        }
        var receipts: [Receipt] = []
        if let data = originals[2] {
            guard let decoded = try? JSONDecoder().decode([Receipt].self, from: data),
                  Set(decoded.map(\.appID)).count == decoded.count else { throw Failure.malformed }
            receipts = decoded
        }
        let quotedExe = "\"\(path)\""
        let quotedDir = "\"\(exe.deletingLastPathComponent().path)\""
        // Same executable is the stable ownership identity; renaming keeps its existing app ID/prefix.
        let owners = receipts.filter { $0.executable == quotedExe }
        guard owners.count <= 1 else { throw Failure.malformed }
        let owner = owners.first
        let appID = owner?.appID ?? shortcutID(quotedExecutable: quotedExe, name: name)
        let existingIndex = entries.firstIndex { $0.children?.field("appid")?.uint32 == appID }
        if let owner {
            guard let index = existingIndex, let fields = entries[index].children,
                  fields.field("exe")?.string == owner.executable,
                  fields.field("appname")?.string == owner.name else { throw Failure.collision }
        } else {
            // Never adopt somebody else's shortcut, including identical executable/name or CRC collision.
            guard existingIndex == nil, !entries.contains(where: { $0.children?.field("exe")?.string == quotedExe })
            else { throw Failure.collision }
        }
        if let index = existingIndex {
            var fields = entries[index].children!
            fields.set(.text(fields.field("appname")!.key, name))
            fields.set(.text(fields.field("exe")!.key, quotedExe))
            fields.set(.text(fields.field("startdir")!.key, quotedDir))
            entries[index] = .object(entries[index].key, fields)
        } else {
            let next = (entries.compactMap { UInt32($0.key) }.max().map { UInt64($0) + 1 }) ?? 0
            guard next <= UInt32.max else { throw Failure.malformed }
            entries.append(.object(String(next), [
                .number("appid", appID), .text("AppName", name), .text("Exe", quotedExe),
                .text("StartDir", quotedDir), .text("icon", ""), .text("ShortcutPath", ""),
                .text("LaunchOptions", ""), .number("IsHidden", 0), .number("AllowDesktopConfig", 1),
                .number("AllowOverlay", 1), .number("OpenVR", 0), .number("Devkit", 0),
                .text("DevkitGameID", ""), .number("DevkitOverrideAppID", 0), .number("LastPlayTime", 0),
                .text("FlatpakAppID", ""), .object("tags", [])
            ]))
        }
        document[0] = .object(document[0].key, entries)
        let newShortcuts = BinaryVDF.encode(document)
        let newConfig = try TextVDF.mapping(originals[1]!, appID: appID, tool: request.toolName, previousTool: owner?.tool)
        receipts.removeAll { $0.appID == appID }
        receipts.append(Receipt(appID: appID, executable: quotedExe, name: name, tool: request.toolName))
        let newReceipts = try JSONEncoder().encode(receipts)
        let replacements = [newShortcuts, newConfig, newReceipts]
        // Decode our output before any mutation; opaque binary values and unrelated text remain exact.
        _ = try BinaryVDF.decode(newShortcuts)
        let backup = configDir.appendingPathComponent("notproton-import-\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for index in urls.indices {
            let saved = backup.appendingPathComponent("\(index).original")
            try (originals[index] ?? Data()).write(to: saved, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saved.path)
            if originals[index] == nil { try Data().write(to: backup.appendingPathComponent("\(index).absent")) }
            try replacements[index].write(to: backup.appendingPathComponent("\(index).planned"))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.appendingPathComponent("\(index).planned").path)
        }
        let pending = backup.appendingPathComponent("pending")
        try Data(accountID.utf8).write(to: pending, options: .withoutOverwriting)
        for entry in try fm.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil) {
            let handle = try FileHandle(forWritingTo: entry)
            try handle.synchronize()
            try handle.close()
        }
        try syncDirectory(backup)
        try syncDirectory(configDir)
        var written: [Int] = []
        do {
            for index in urls.indices {
                try stopped()
                for check in urls.indices {
                    try safePath(urls[check])
                    let expected = written.contains(check) ? replacements[check] : originals[check]
                    guard try readOptional(urls[check]) == expected else { throw Failure.changed }
                }
                try atomicWrite(replacements[index], urls[index])
                written.append(index)
                guard try readOptional(urls[index]) == replacements[index] else { throw Failure.changed }
            }
            try stopped()
            for index in urls.indices {
                try safePath(urls[index])
                guard try readOptional(urls[index]) == replacements[index] else { throw Failure.changed }
            }
            try fm.removeItem(at: pending)
        } catch {
            // Roll back only while stopped and only if every file still matches our own writes.
            // Otherwise retain the journal and block further imports rather than overwrite Steam's edits.
            do {
                try stopped()
                for index in urls.indices {
                    try safePath(urls[index])
                    guard try readOptional(urls[index]) == (written.contains(index) ? replacements[index] : originals[index])
                    else { throw Failure.changed }
                }
                for index in written.reversed() {
                    try stopped()
                    try safePath(urls[index])
                    guard try readOptional(urls[index]) == replacements[index] else { throw Failure.changed }
                    if let data = originals[index] { try atomicWrite(data, urls[index]) }
                    else { try fm.removeItem(at: urls[index]) }
                }
                for index in urls.indices {
                    try safePath(urls[index])
                    guard try readOptional(urls[index]) == originals[index] else { throw Failure.changed }
                }
                try fm.removeItem(at: pending)
                try syncDirectory(backup)
            } catch { throw Failure.recovery }
            throw error
        }
        return Result(appID: appID, updated: owner != nil, backup: backup)
    }

    /// Settings recovery entry point. Invoke only after the user chooses to restore this backup.
    /// A crash/failed rollback keeps `pending`; every current file must match original or planned
    /// bytes. Foreign changes and running Steam are refused, and backup data is never logged.
    static func restoreInterruptedImport(
        backup: URL, steamRoot: URL = SupportPaths.Steam.userData, accountID: String
    ) throws {
        do {
            let fm = FileManager.default
            guard numeric(accountID), accountID != "0" else { throw Failure.unsafeFiles }
            let configDir = steamRoot.appendingPathComponent("config")
            guard backup.deletingLastPathComponent().standardizedFileURL == configDir,
                  backup.lastPathComponent.hasPrefix("notproton-import-") else { throw Failure.unsafeFiles }
            try safePath(backup.appendingPathComponent("pending"))
            guard try readOptional(backup.appendingPathComponent("pending")) == Data(accountID.utf8)
            else { throw Failure.unsafeFiles }
            if try clientRunning() { throw Failure.running }
            let lockURL = configDir.appendingPathComponent(".notproton-import.lock")
            let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unsafeFiles }
            defer { flock(fd, LOCK_UN); close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.changed }
            // Another recovery may have completed while this caller waited for the lock.
            try safePath(backup.appendingPathComponent("pending"))
            guard try readOptional(backup.appendingPathComponent("pending")) == Data(accountID.utf8)
            else { throw Failure.recovery }
            let userConfig = steamRoot.appendingPathComponent("userdata/\(accountID)/config")
            let urls = [userConfig.appendingPathComponent("shortcuts.vdf"), configDir.appendingPathComponent("config.vdf"),
                        userConfig.appendingPathComponent("notproton-imports.json")]
            var originals = [Data?](), observed = [Data?]()
            for index in urls.indices {
                let originalURL = backup.appendingPathComponent("\(index).original")
                let plannedURL = backup.appendingPathComponent("\(index).planned")
                let absentURL = backup.appendingPathComponent("\(index).absent")
                for url in [urls[index], originalURL, plannedURL, absentURL] { try safePath(url) }
                guard let saved = try readOptional(originalURL), let planned = try readOptional(plannedURL)
                else { throw Failure.recovery }
                let original: Data? = fm.fileExists(atPath: absentURL.path) ? nil : saved
                let current = try readOptional(urls[index])
                guard current == original || current == planned else { throw Failure.changed }
                originals.append(original); observed.append(current)
            }
            for index in urls.indices.reversed() {
                if try clientRunning() { throw Failure.running }
                try safePath(urls[index])
                guard try readOptional(urls[index]) == observed[index] else { throw Failure.changed }
                if let data = originals[index] { try atomicWrite(data, urls[index]) }
                else if observed[index] != nil { try fm.removeItem(at: urls[index]) }
            }
            if try clientRunning() { throw Failure.running }
            for index in urls.indices {
                try safePath(urls[index])
                guard try readOptional(urls[index]) == originals[index] else { throw Failure.changed }
                try syncDirectory(urls[index].deletingLastPathComponent())
            }
            try fm.removeItem(at: backup.appendingPathComponent("pending"))
            try syncDirectory(backup)
        } catch let failure as Failure { throw failure }
        catch { throw Failure.recovery }
    }

    private static func readOptional(_ url: URL) throws -> Data? {
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32 * 1024 * 1024 else { throw Failure.malformed }
        return try Data(contentsOf: url)
    }
    private static func safePath(_ url: URL) throws {
        // Reject redirected config paths, dangling links, special files, and hard-linked files.
        // Foundation exposes temporary folders via macOS root-owned /var and /tmp aliases.
        var item = url
        while item.path != "/" {
            var info = stat()
            if lstat(item.path, &info) == 0 {
                let kind = info.st_mode & S_IFMT
                let alias = ["/var", "/tmp"].contains(item.path) && kind == S_IFLNK && info.st_uid == 0 &&
                    ["private" + item.path, "/private" + item.path].contains(
                        (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) ?? "")
                guard alias || kind == S_IFDIR || (item.path == url.path && kind == S_IFREG && info.st_nlink == 1)
                else { throw Failure.unsafeFiles }
            } else if errno != ENOENT { throw Failure.unsafeFiles }
            item.deleteLastPathComponent()
        }
    }
    static func atomicWrite(_ data: Data, _ url: URL) throws {
        let fm = FileManager.default
        let staged = url.deletingLastPathComponent().appendingPathComponent(".notproton-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
        try data.write(to: staged, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
        let handle = try FileHandle(forWritingTo: staged)
        try handle.synchronize()
        try handle.close()
        guard rename(staged.path, url.path) == 0 else { throw Failure.io }
        try syncDirectory(url.deletingLastPathComponent())
    }
    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.io }
    }
}

/// Valve KeyValues binary wire types, preserving scalar bytes (including NaN bit patterns).
/// https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/tier1/KeyValues.cpp
/// Steam shortcuts use the legacy 0x08 end marker. WSTRING/PTR/extended layouts are refused.
enum BinaryVDF {
    struct Node: Equatable {
        let key: String
        let type: UInt8
        let payload: Data
        let children: [Node]?
        static func object(_ key: String, _ children: [Node]) -> Node { Node(key: key, type: 0, payload: Data(), children: children) }
        static func text(_ key: String, _ value: String) -> Node { Node(key: key, type: 1, payload: Data(value.utf8) + Data([0]), children: nil) }
        static func number(_ key: String, _ value: UInt32) -> Node {
            Node(key: key, type: 2, payload: Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }), children: nil)
        }
        var string: String? { type == 1 ? String(data: payload.dropLast(), encoding: .utf8) : nil }
        var uint32: UInt32? {
            guard type == 2, payload.count == 4 else { return nil }
            return payload.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
    }
    static func decode(_ data: Data) throws -> [Node] {
        guard data.count <= 32 * 1024 * 1024 else { throw WindowsGameImport.Failure.malformed }
        let bytes = [UInt8](data)
        var cursor = 0, nodes = 0
        func zeroString() throws -> Data {
            let start = cursor
            while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count, cursor - start < 4096 else { throw WindowsGameImport.Failure.malformed }
            cursor += 1
            return Data(bytes[start..<cursor])
        }
        func group(_ depth: Int) throws -> [Node] {
            guard depth < 64 else { throw WindowsGameImport.Failure.malformed }
            var result: [Node] = [], names = Set<String>()
            while cursor < bytes.count {
                let type = bytes[cursor]; cursor += 1
                if type == 8 { return result }
                nodes += 1
                guard nodes <= 100_000, [0, 1, 2, 3, 6, 7].contains(type),
                      let key = String(data: try zeroString().dropLast(), encoding: .utf8),
                      !key.isEmpty, names.insert(key.lowercased()).inserted else { throw WindowsGameImport.Failure.malformed }
                if type == 0 { result.append(.object(key, try group(depth + 1))) }
                else if type == 1 {
                    let payload = try zeroString()
                    guard String(data: payload.dropLast(), encoding: .utf8) != nil else { throw WindowsGameImport.Failure.malformed }
                    result.append(Node(key: key, type: type, payload: payload, children: nil))
                } else {
                    let count = type == 7 ? 8 : 4
                    guard cursor + count <= bytes.count else { throw WindowsGameImport.Failure.malformed }
                    result.append(Node(key: key, type: type, payload: Data(bytes[cursor..<cursor + count]), children: nil))
                    cursor += count
                }
            }
            throw WindowsGameImport.Failure.malformed
        }
        let result = try group(0)
        guard cursor == bytes.count else { throw WindowsGameImport.Failure.malformed }
        return result
    }
    static func encode(_ nodes: [Node]) -> Data {
        var result = Data()
        for node in nodes {
            result.append(node.type)
            result.append(contentsOf: node.key.utf8); result.append(0)
            if let children = node.children { result.append(encode(children)) }
            else { result.append(node.payload) }
        }
        result.append(8)
        return result
    }
}

private extension Array where Element == BinaryVDF.Node {
    func field(_ key: String) -> Element? { first { $0.key.lowercased() == key.lowercased() } }
    mutating func set(_ node: Element) {
        if let index = firstIndex(where: { $0.key.lowercased() == node.key.lowercased() }) { self[index] = node }
        else { append(node) }
    }
}

/// Parses structure and retains byte ranges. The sole edit is an insertion or one owned mapping's
/// name value; comments, casing, whitespace, unrelated keys and escape spelling remain byte exact.
enum TextVDF {
    struct Node {
        let key: String
        let value: String?
        let valueRange: Range<Int>?
        let children: [Node]?
        let close: Int?
        func child(_ name: String) -> Node? { children?.first { $0.key.lowercased() == name.lowercased() } }
    }
    static func parse(_ data: Data) throws -> [Node] {
        guard data.count <= 32 * 1024 * 1024, String(data: data, encoding: .utf8) != nil else { throw WindowsGameImport.Failure.malformed }
        let bytes = [UInt8](data)
        var p = 0, count = 0
        func skip() {
            while p < bytes.count {
                if [9, 10, 13, 32].contains(bytes[p]) { p += 1 }
                else if p + 1 < bytes.count && bytes[p] == 47 && bytes[p + 1] == 47 {
                    while p < bytes.count && bytes[p] != 10 { p += 1 }
                } else { break }
            }
        }
        func token() throws -> (String, Range<Int>) {
            skip(); let start = p
            guard p < bytes.count else { throw WindowsGameImport.Failure.malformed }
            var value = [UInt8]()
            if bytes[p] == 34 {
                p += 1
                while p < bytes.count && bytes[p] != 34 {
                    let byte = bytes[p]; p += 1
                    if byte == 92 {
                        guard p < bytes.count else { throw WindowsGameImport.Failure.malformed }
                        let escaped = bytes[p]; p += 1
                        switch escaped {
                        case 34, 92: value.append(escaped)
                        case 110: value.append(10)
                        case 116: value.append(9)
                        case 114: value.append(13)
                        default: throw WindowsGameImport.Failure.malformed
                        }
                    } else { guard byte != 0 else { throw WindowsGameImport.Failure.malformed }; value.append(byte) }
                }
                guard p < bytes.count else { throw WindowsGameImport.Failure.malformed }; p += 1
            } else {
                while p < bytes.count && ![9, 10, 13, 32, 123, 125].contains(bytes[p]) {
                    guard ![0, 34, 35, 91, 93].contains(bytes[p]) else { throw WindowsGameImport.Failure.malformed }
                    value.append(bytes[p]); p += 1
                }
                guard !value.isEmpty else { throw WindowsGameImport.Failure.malformed }
            }
            guard let text = String(bytes: value, encoding: .utf8) else { throw WindowsGameImport.Failure.malformed }
            return (text, start..<p)
        }
        func group(_ depth: Int) throws -> ([Node], Int?) {
            guard depth < 64 else { throw WindowsGameImport.Failure.malformed }
            var nodes = [Node](), names = Set<String>()
            while true {
                skip()
                if p == bytes.count {
                    guard depth == 0 else { throw WindowsGameImport.Failure.malformed }
                    return (nodes, nil)
                }
                if bytes[p] == 125 {
                    guard depth > 0 else { throw WindowsGameImport.Failure.malformed }
                    let close = p; p += 1; return (nodes, close)
                }
                let (key, _) = try token(); count += 1
                guard !key.isEmpty, count <= 100_000, names.insert(key.lowercased()).inserted else { throw WindowsGameImport.Failure.malformed }
                skip()
                guard p < bytes.count else { throw WindowsGameImport.Failure.malformed }
                if bytes[p] == 123 {
                    p += 1; let (children, close) = try group(depth + 1)
                    nodes.append(Node(key: key, value: nil, valueRange: nil, children: children, close: close))
                } else {
                    let (value, range) = try token()
                    nodes.append(Node(key: key, value: value, valueRange: range, children: nil, close: nil))
                }
            }
        }
        return try group(0).0
    }
    static func mapping(_ data: Data, appID: UInt32, tool: String, previousTool: String?) throws -> Data {
        let tree = try parse(data)
        guard tree.count == 1, tree[0].key.lowercased() == "installconfigstore", tree[0].children != nil else {
            throw WindowsGameImport.Failure.malformed
        }
        let path = ["Software", "Valve", "Steam", "CompatToolMapping"]
        var parent = tree[0]
        for (index, key) in path.enumerated() {
            if let child = parent.child(key) {
                guard child.children != nil else { throw WindowsGameImport.Failure.malformed }
                parent = child
            } else {
                var inserted = entry(appID, tool)
                for missing in path[index...].reversed() { inserted = "\"\(missing)\"\n{\n\(inserted)\n}\n" }
                return try patch(data, range: parent.close!..<parent.close!, text: "\n" + inserted)
            }
        }
        let longID = String((UInt64(appID) << 32) | 0x02000000)
        guard parent.child(longID) == nil else { throw WindowsGameImport.Failure.collision }
        if let existing = parent.child(String(appID)) {
            guard previousTool != nil, existing.child("name")?.value == previousTool,
                  existing.child("config")?.value == "", existing.child("priority")?.value == "250",
                  let range = existing.child("name")?.valueRange else { throw WindowsGameImport.Failure.collision }
            return try patch(data, range: range, text: "\"\(tool)\"")
        }
        // Also refuse a mapping keyed by the long launch ID; never silently create contradictory settings.
        return try patch(data, range: parent.close!..<parent.close!, text: "\n" + entry(appID, tool) + "\n")
    }
    private static func entry(_ id: UInt32, _ tool: String) -> String {
        "\"\(id)\"\n{\n\"name\" \"\(tool)\"\n\"config\" \"\"\n\"priority\" \"250\"\n}\n"
    }
    private static func patch(_ data: Data, range: Range<Int>, text: String) throws -> Data {
        var result = data
        result.replaceSubrange(range, with: text.utf8)
        _ = try parse(result)
        return result
    }
}
