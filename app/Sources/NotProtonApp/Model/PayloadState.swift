// Checks files on disk versus the manifest, presents state to user

import Foundation
import Darwin

struct PayloadState: Sendable {
    var expected: Int
    var present: Int
    var missing: [PayloadEntry]
    var overlayShimPresent: Bool
    var iconmakerPresent: Bool
    var appinfoPresent: Bool
    var gameIdentityPresent: Bool = false
    var sessionCheckPresent: Bool = true
    var gamePresentationPresent: Bool = false
    var signatureDatabase: String?
    var legacyCompatPresent: Int
    var legacyCompatExpected: Int
    var manifestProblem: String?

    var isSteamComplete: Bool {
        manifestProblem == nil && missingSteamFiles.isEmpty && signatureDatabase != nil
    }

    var missingSteamFiles: [String] {
        var names = missing(origin: .built).map(\.path)
        if !overlayShimPresent { names.append("overlay-shim.dylib") }
        if !iconmakerPresent { names.append("iconmaker") }
        if !appinfoPresent { names.append("appinfo") }
        if !gameIdentityPresent { names.append(SupportPaths.gameIdentityName) }
        if !sessionCheckPresent { names.append(SupportPaths.sessionCheckName) }
        if !gamePresentationPresent { names.append(SupportPaths.gamePresentationName) }
        return names
    }

    var isComplete: Bool {
        isSteamComplete && missing.isEmpty
    }

    var isEmpty: Bool {
        present == 0 && !overlayShimPresent && !iconmakerPresent && !appinfoPresent
            && !gameIdentityPresent && !sessionCheckPresent && !gamePresentationPresent
            && signatureDatabase == nil
    }

    func missing(origin: PayloadOrigin) -> [PayloadEntry] {
        missing.filter { $0.origin == origin }
    }
}

enum PayloadInspector {

    static func inspect(
        bridge: URL = SupportPaths.bridge, builds: [RunnerBuild] = RunnerStore.installedBuilds(),
        support: URL = SupportPaths.support,
        legacyCompat: URL = SupportPaths.Steam.legacyCompat
    ) -> PayloadState {
        let fm = FileManager.default

        var expected = 0
        var missing: [PayloadEntry] = []
        var problem: String?

        do {
            let manifest = try PayloadManifest.bundled()
            let entries = manifest.entries.flatMap { expand($0, for: builds) }
            expected = entries.count
            missing = entries.filter {
                !fm.fileExists(atPath: bridge.appending(path: $0.path).path(percentEncoded: false))
            }
        } catch {
            problem = error.localizedDescription
        }

        let legacyNames = ((try? ValvePackageManifest.bundled())?.files ?? [])
            .filter { $0.bridgePath.hasPrefix("legacycompat/") }
            .map { URL(filePath: $0.bridgePath).lastPathComponent }
        let legacyPresent = legacyNames.filter {
            fm.fileExists(
                atPath: legacyCompat
                    .appending(path: $0).path(percentEncoded: false)
            )
        }.count

        return PayloadState(
            expected: expected,
            present: expected - missing.count,
            missing: missing,
            overlayShimPresent: isRegularFile(support.appending(path: "overlay-shim.dylib")),
            iconmakerPresent: isRegularFile(support.appending(path: "iconmaker")),
            appinfoPresent: isRegularFile(support.appending(path: "appinfo")),
            gameIdentityPresent: isRegularFile(support.appending(path: SupportPaths.gameIdentityName)),
            sessionCheckPresent: isExecutableRegularFile(support.appending(path: SupportPaths.sessionCheckName)),
            gamePresentationPresent: isExecutableRegularFile(support.appending(path: SupportPaths.gamePresentationName)),
            signatureDatabase: newestSignatureDatabase(in: support.appending(path: "signatures/macos.arm64")),
            legacyCompatPresent: legacyPresent,
            legacyCompatExpected: legacyNames.count,
            manifestProblem: problem
        )
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func isExecutableRegularFile(_ url: URL) -> Bool {
        isRegularFile(url) && FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
    }

    private static func expand(_ entry: PayloadEntry, for builds: [RunnerBuild]) -> [PayloadEntry] {
        guard entry.origin == .patched,
              let arch = WineArch.allCases.first(where: {
                  entry.path == "wine/\($0.rawValue)/ntdll.dll"
              })
        else { return [entry] }
        return builds.filter { $0.patchedNtdll[arch] != nil }.map {
            PayloadEntry(origin: .patched, path: "wine/\($0.id)/\(arch.rawValue)/ntdll.dll")
        }
    }

    static func newestSignatureDatabase(in directory: URL = SupportPaths.signatures) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .map(\.lastPathComponent)
            .compactMap { name -> (name: String, build: UInt64)? in
                guard name.hasSuffix(".json"),
                      let build = UInt64(name.dropLast(5)), build > 0
                else { return nil }
                return (name, build)
            }
            .max { $0.build < $1.build }?
            .name
    }
}
