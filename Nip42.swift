import Foundation

/// NIP-42: client authentication on relays via kind-22242 events.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/42.md
nonisolated enum Nip42 {

    static let kindAuth = 22242

    enum AuthError: Error, Equatable {
        /// Logging in to this relay is switched off (`loginAllowed`).
        case loginDisabled(relayUrl: String)
    }

    /// Whether the app may log in to `relayUrl` at all. False only for the
    /// curated feed relay while `FeatureFlags.feedRelayLoginEnabled` is off
    /// (Guideline 2.1(b): a login there unlocks the paid Cook+ tier, and
    /// tells the relay who is reading). The user's "sign in to relays
    /// automatically" setting and per-relay approval cannot override it.
    static func loginAllowed(relayUrl: String,
                             feedRelayLoginEnabled: Bool = FeatureFlags.feedRelayLoginEnabled) -> Bool {
        feedRelayLoginEnabled || !FeedRelay.isFeedRelay(relayUrl)
    }

    /// Build a signed kind-22242 AUTH event in response to a relay's
    /// `["AUTH", challenge]` frame.
    ///
    /// This is the only place the app constructs a kind-22242 event
    /// (`FeedRelayNoAuthTests` scans the sources for another), so the
    /// `loginAllowed` refusal here covers every relay path. Every caller
    /// already treats a throw as "no AUTH sent".
    static func buildAuthEvent(challenge: String, relayUrl: String, keypair: Keypair,
                               createdAt: Int = NostrClock.now()) throws -> NostrEvent {
        guard loginAllowed(relayUrl: relayUrl) else {
            throw AuthError.loginDisabled(relayUrl: relayUrl)
        }
        let tags: [[String]] = [
            ["relay", relayUrl],
            ["challenge", challenge]
        ]
        let priv = Hex.decode(keypair.privkey) ?? Data()
        return try NostrEvent.sign(privkey32: priv, pubkey: keypair.pubkey, kind: kindAuth,
                                   createdAt: createdAt, tags: tags, content: "")
    }
}
