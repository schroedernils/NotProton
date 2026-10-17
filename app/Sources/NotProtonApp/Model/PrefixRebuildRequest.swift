import Foundation

struct PrefixRebuildRequest: Equatable {
    enum Resolution: Equatable {
        case missing
        case ambiguous
        case prefix(WinePrefix)
    }

    let appID: String

    static func parse(_ url: URL) -> PrefixRebuildRequest? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "notproton",
              parts.host?.lowercased() == "prefix",
              parts.path == "/rebuild",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil,
              let query = parts.queryItems, query.count == 1,
              query[0].name == "appid", let appID = query[0].value,
              !appID.isEmpty,
              appID.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }), appID != "0",
              UInt32(appID) != nil else {
            return nil
        }
        return PrefixRebuildRequest(appID: appID)
    }

    func resolve(in prefixes: [WinePrefix]) -> Resolution {
        let matches = prefixes.filter { $0.appID == appID }
        switch matches.count {
        case 0: return Resolution.missing
        case 1: return Resolution.prefix(matches[0])
        default: return Resolution.ambiguous
        }
    }

    static func appID(in url: URL) -> String? {
        parse(url)?.appID
    }
}
