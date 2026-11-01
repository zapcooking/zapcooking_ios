import Foundation

/// NIP-42: client authentication on relays via kind-22242 events.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/42.md
nonisolated enum Nip42 {

    static let kindAuth = 22242

    /// Build a signed kind-22242 AUTH event in response to a relay's
    /// `["AUTH", challenge]` frame. Routes through `Signer`, so remote-signer
    /// (NIP-46) accounts work too — which means a network round-trip that may
    /// be slow or throw.
    static func buildAuthEvent(challenge: String, relayUrl: String, keypair: Keypair,
                               createdAt: Int = NostrClock.now()) async throws -> NostrEvent {
        let tags: [[String]] = [
            ["relay", relayUrl],
            ["challenge", challenge]
        ]
        return try await Signer.sign(keypair: keypair, kind: kindAuth, tags: tags,
                                     content: "", createdAt: createdAt)
    }
}
