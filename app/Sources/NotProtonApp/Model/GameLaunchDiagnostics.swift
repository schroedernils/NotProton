import Foundation

/// Read-only diagnosis. Incomplete logs never establish that a process is alive.
struct GameLaunchDiagnostics: Equatable, Sendable {
    static let maximumLogBytes = 256 * 1024

    enum Classification: String, Sendable {
        case completed, missingVCRuntime, runnerMismatch, runnerMissing, failedStartup, stillRunning, unknown
    }

    enum Action: Equatable, Sendable {
        case revealLog(URL)
        case reviewEnvironmentRepair(URL)
        case installRuntime(verb: String)
        case retry
    }

    let classification: Classification
    let title: String
    let message: String
    let evidence: [String]
    let actions: [Action]
    let logIssue: String?

    /// Read only the selected launch log and its matching Wine log.
    static func load(appID: String, logURL: URL, wineLogURL: URL? = nil) -> Self {
        do {
            let before = try snapshot(logURL)
            let log = try readTail(logURL, limit: maximumLogBytes)
            let text = String(decoding: log.data, as: UTF8.self)
            var wine: String?
            if let wineLogURL, let wineBefore = try? snapshot(wineLogURL),
               correlatedWine(appID: appID, log: text, runModified: before.modified,
                              wineModified: wineBefore.modified),
               let tail = try? readTail(wineLogURL, limit: maximumLogBytes),
               let wineAfter = try? snapshot(wineLogURL), wineBefore == wineAfter {
                wine = String(decoding: tail.data, as: UTF8.self)
            }
            guard try snapshot(logURL) == before else {
                return Self(classification: .unknown, title: "Launch log is changing",
                            message: "Refresh after the launch has settled.", evidence: [],
                            actions: [.revealLog(logURL)], logIssue: nil)
            }
            return diagnose(appID: appID, log: text, logURL: logURL,
                            wineLog: wine, wineLogURL: wineLogURL)
        } catch {
            return Self(classification: .unknown, title: "Launch details unavailable",
                        message: "The launch log could not be read. Choose the game’s latest launch log and try again.",
                        evidence: [], actions: [.revealLog(logURL)], logIssue: error.localizedDescription)
        }
    }

    private struct Snapshot: Equatable {
        let modified: Date
        let size: UInt64
        let inode: UInt64
    }

    private static func snapshot(_ url: URL) throws -> Snapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnknown)
        }
        return Snapshot(modified: modified, size: size.uint64Value, inode: inode.uint64Value)
    }

    /// Existing launcher contract: run log is appended, Wine log is truncated
    /// by the per-app bundle. No guessed path or filesystem-wide log search.
    /// Reject early aborts, helper runs, missing headers, and ambiguous dates.
    /// Same-second output is deliberately omitted: date(1) has no subsecond ID.
    static func correlatedWine(appID: String, log: String, runModified: Date, wineModified: Date) -> Bool {
        let lines = latestRun(log)
        guard let header = lines.first, header.hasPrefix("=== notproton run "),
              header.hasSuffix(" ==="), lines.contains("STEAM_COMPAT_APP_ID=\(appID)"),
              lines.contains("verb=waitforexitandrun"),
              lines.contains(where: { $0.hasPrefix("=== launching (waitforexitandrun): ") }),
              !lines.contains(where: { $0.hasPrefix("=== aborted during ") }),
              let date = runDate(String(header.dropFirst(18).dropLast(4))),
              wineModified.timeIntervalSince(date) >= 1,
              wineModified <= runModified else { return false }
        return true
    }

    private static func runDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        // BSD date's default layout; unknown/localized formats fail closed.
        formatter.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        return formatter.date(from: text)
    }

    private static func latestRun(_ log: String) -> [String] {
        let all = log.components(separatedBy: .newlines)
        let start = all.lastIndex(where: { $0.hasPrefix("=== notproton run ") && $0.hasSuffix(" ===") }) ?? 0
        return Array(all[start...])
    }

    /// Seeks before reading; never loads the whole file. Drop a partial first line
    /// so truncated text cannot become a valid stage marker or DLL diagnostic.
    static func readTail(_ url: URL, limit: Int) throws -> (data: Data, truncated: Bool) {
        precondition(limit > 0 && limit <= maximumLogBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > UInt64(limit) ? size - UInt64(limit) : 0
        try handle.seek(toOffset: offset)
        var data = try handle.read(upToCount: limit) ?? Data()
        if offset > 0 {
            if let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
            else { data = Data() }
        }
        return (data, offset > 0)
    }

    static func diagnose(appID: String, log: String, logURL: URL,
                         wineLog: String? = nil, wineLogURL: URL? = nil) -> Self {
        let lines = latestRun(log)
        // The loader validates provenance before supplying this optional snapshot.
        let wineLines = wineLog?.components(separatedBy: .newlines) ?? []
        func matches(_ pattern: String) -> [String] {
            lines.filter { $0.range(of: pattern, options: .regularExpression) != nil }
        }
        func result(_ kind: Classification, _ title: String, _ message: String,
                    _ evidence: [String] = [], repair: Bool = false, runtime: String? = nil) -> Self {
            var actions: [Action] = [.revealLog(logURL)]
            if repair, let url = repairURL(appID: appID) { actions.append(.reviewEnvironmentRepair(url)) }
            if !wineLines.isEmpty, let wineLogURL { actions.append(.revealLog(wineLogURL)) }
            if let runtime { actions.append(.installRuntime(verb: runtime)) }
            if kind != .stillRunning && kind != .completed { actions.append(.retry) }
            return Self(classification: kind, title: title, message: message,
                        evidence: Array(evidence.prefix(4)).map { String($0.prefix(500)) }, actions: actions, logIssue: nil)
        }
        let exits = matches(#"^=== (game|helper|bundle) exited status=[0-9]+( ===|, killing wine prefix ===)$"#)
        func status(_ line: String) -> Int? {
            guard let range = line.range(of: #"status=[0-9]+"#, options: .regularExpression) else { return nil }
            return Int(line[range].dropFirst(7))
        }
        let finalStatus = exits.last.flatMap(status)
        let ended = lines.contains("=== wine prefix killed, session ending ===")
        if lines.contains("=== prefix is still running after the restart wait ===") {
            return result(.stillRunning, "Previous game session blocked this launch",
                          "The previous session was still active when this launch was attempted. Check Steam and quit the game before changing its environment. The log does not confirm whether it is still running now.",
                          ["=== prefix is still running after the restart wait ==="])
        }
        let mismatch = matches(#"^=== (prefix was last run by build .+ and this compatibility tool runs .+, rebuild the prefix in NotProton|prefix ntdll is .+ and this compatibility tool wants .+, rebuild the prefix in NotProton|runner .+ ntdll is not the patched copy, set up the runner in NotProton) ===$"#)
        if !mismatch.isEmpty {
            return result(.runnerMismatch, "Game environment uses a different runner",
                          "This game’s Windows environment does not match the selected compatibility tool. Review the environment repair before making changes.", mismatch, repair: true)
        }
        let missing = matches(#"^=== (build .+ behind this compatibility tool is not set up, set it up in NotProton|runner has no .+ ntdll, set up the runner in NotProton|runner is missing .+, set up the runner in NotProton|no patched ntdll for build .+ in the bridge, set it up in NotProton) ===$"#)
        if !missing.isEmpty {
            return result(.runnerMissing, "Compatibility tool is incomplete",
                          "Required runner files are unavailable. Review the compatibility tool setup and environment repair.", missing, repair: true)
        }
        // Match Wine's concrete import failure, not DLL names, arbitrary err:
        // messages, c0000135 alone, or an unrelated missing library.
        let diagnosticLines = lines + wineLines
        let dlls = diagnosticLines.filter { $0.range(of: #"(?i)^[0-9a-f]+:err:module:import_dll Library (?:\"|')?(?:vcruntime140(?:_1)?|msvcp140(?:_1|_2)?|concrt140)\.dll(?:\"|')? \(which is needed by .+\) not found$"#, options: .regularExpression) != nil }
        let aborts = matches(#"^=== aborted during .+ \(exit [1-9][0-9]*\) before launch ===$"#)
        let failed = !aborts.isEmpty || (finalStatus.map { $0 != 0 } ?? false)
        let fatalStartup = diagnosticLines.filter { $0.range(of: #"(?i)^[0-9a-f]+:err:module:loader_init Importing dlls for .+ failed, status c0000135$"#, options: .regularExpression) != nil }
        if !dlls.isEmpty && (failed || !fatalStartup.isEmpty) {
            return result(.missingVCRuntime, "Microsoft Visual C++ runtime is missing",
                          "Wine could not load a required Visual C++ DLL. You can review and install vcrun2022 using the existing Winetricks tool. Installation may download files and changes this game’s environment.", dlls, runtime: "vcrun2022")
        }
        if fatalStartup.isEmpty && ended && finalStatus == 0 {
            return result(.completed, "Session ended without a reported launch failure",
                          "The launcher reported a normal exit. This does not confirm that the game displayed a window or worked correctly.", exits.suffix(1).map { $0 })
        }
        if failed || !fatalStartup.isEmpty {
            return result(.failedStartup, "Launch did not finish normally",
                          "The launcher reported a failure. Review the log for details; it does not establish a specific repair. Retry only after checking the game and its settings.", aborts + exits.suffix(1) + fatalStartup)
        }
        return result(.unknown, "Launch outcome is unknown",
                      "The available log does not confirm a failed launch or a running game. Reveal the log for details, or retry through Steam when you are ready.")
    }

    static func repairURL(appID: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "notproton"
        parts.host = "prefix"
        parts.path = "/rebuild"
        parts.queryItems = [URLQueryItem(name: "appid", value: appID)]
        guard let url = parts.url, PrefixRebuildRequest.parse(url) != nil else { return nil }
        return url
    }
}
