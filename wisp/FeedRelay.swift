import Foundation

/// The curated feed relay (`wss://feed.zap.cooking`, build spec §2 "Fresh
/// feed relay"). The one fact about it that every relay path needs: is this
/// URL that relay? `Nip42.loginAllowed` asks, so no socket anywhere in the
/// app answers its NIP-42 challenge while `FeatureFlags.feedRelayLoginEnabled`
/// is off.
nonisolated enum FeedRelay {
    static let url = "wss://feed.zap.cooking"
    static let host = "feed.zap.cooking"

    /// True when `raw` names the feed relay's host, however it is spelled:
    /// any scheme or none, any case, a port, a path, a query, user info, a
    /// trailing slash or a trailing root dot. Matched on the host alone
    /// because a relay URL reaches the signing paths from many places (the
    /// relay picker, relay lists, hints) and none of them agree on a
    /// canonical form. Subdomains and look-alike hosts do not match.
    static func isFeedRelay(_ raw: String) -> Bool {
        var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        // Authority ends at the first path, query or fragment delimiter.
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = rest[..<end]
        }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
        while rest.hasSuffix(".") { rest = rest.dropLast() }
        return rest == host
    }
}
