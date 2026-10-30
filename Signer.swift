import Foundation

/// Unified signing facade for the active account. Routes to local Schnorr
/// signing for nsec/keychain accounts, or to the account's `Nip46Client` for
/// remote-signed (NIP-46 bunker / nostrconnect) accounts.
///
/// Anything that signs or encrypts as the USER must come through here — a
/// direct `NostrEvent.sign(privkey32:)` / `Nip44.getConversationKey` with
/// `keypair.privkey` throws (or silently no-ops) for every remote account,
/// because their private key never leaves the signer app.
@MainActor
enum Signer {

    enum SignerError: Swift.Error, CustomStringConvertible {
        case noActiveRemoteSigner
        case localKeyMissing
        case remoteSignerUnsupported

        var description: String {
            switch self {
            case .noActiveRemoteSigner: return "Remote signer is not connected"
            case .localKeyMissing: return "Missing local private key"
            case .remoteSignerUnsupported: return "Not available with a remote signer"
            }
        }
    }

    // `nonisolated` for the same reason as the NIP-44 helpers below: the secp256k1
    // Schnorr signing is pure compute that must run OFF the main actor. Without this it
    // inherits the project's MainActor default, so signing a NIP-17 seal/gift-wrap inside
    // a `Task.detached` still hops back to main (one Schnorr sign per recipient + self).
    // The local body touches no main-actor state — only the passed-in keypair +
    // nonisolated `Hex`/`NostrEvent.sign`. The remote branch hops to the main actor
    // only to look up the client, then awaits the RPC on the client's own actor.
    nonisolated static func sign(
        keypair: Keypair,
        kind: Int,
        tags: [[String]],
        content: String,
        createdAt: Int? = nil
    ) async throws -> NostrEvent {
        let ts = createdAt ?? NostrClock.now()
        if keypair.isRemote {
            let client = try await remoteClient(for: keypair)
            let unsigned: [String: Any] = [
                "pubkey": keypair.pubkey,
                "kind": kind,
                "created_at": ts,
                "tags": tags,
                "content": content
            ]
            let event = try await client.signEvent(unsigned: unsigned)
            // The signer is trusted to sign, not to choose the content: refuse an
            // event that isn't the one we asked for (wrong author, kind, or body)
            // or whose signature doesn't verify.
            guard event.pubkey.lowercased() == keypair.pubkey.lowercased(),
                  event.kind == kind,
                  event.content == content,
                  event.tags == tags,
                  event.hasValidSignature() else {
                throw Nip46.NipError.malformedResponse
            }
            return event
        }
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32 else {
            throw SignerError.localKeyMissing
        }
        return try NostrEvent.sign(
            privkey32: priv,
            pubkey: keypair.pubkey,
            kind: kind,
            createdAt: ts,
            tags: tags,
            content: content
        )
    }

    // MARK: - Encryption helpers

    // `nonisolated` so the secp256k1 ECDH + ChaCha20 work runs OFF the main
    // actor. The project defaults to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    // which silently pinned these pure-crypto helpers to the main thread — so
    // draining a NIP-17 gift-wrap backlog (kind:1059) decrypted hundreds of wraps
    // on the main thread in a tight loop and froze the app for 5–10s. They touch
    // no main-actor state; only the passed-in keypair + nonisolated `Nip44`/`Hex`.
    nonisolated static func nip44Encrypt(keypair: Keypair, peerPubkey: String, plaintext: String) async throws -> String {
        if keypair.isRemote {
            let client = try await remoteClient(for: keypair)
            return try await client.nip44Encrypt(peerPubkeyHex: peerPubkey, plaintext: plaintext)
        }
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let peer = Hex.decode(peerPubkey), peer.count == 32 else {
            throw SignerError.localKeyMissing
        }
        let convo = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: peer)
        return try Nip44.encrypt(plaintext: plaintext, conversationKey: convo)
    }

    nonisolated static func nip44Decrypt(keypair: Keypair, peerPubkey: String, payload: String) async throws -> String {
        if keypair.isRemote {
            let client = try await remoteClient(for: keypair)
            return try await client.nip44Decrypt(peerPubkeyHex: peerPubkey, ciphertext: payload)
        }
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let peer = Hex.decode(peerPubkey), peer.count == 32 else {
            throw SignerError.localKeyMissing
        }
        let convo = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: peer)
        return try Nip44.decrypt(payload: payload, conversationKey: convo)
    }

    /// True when this account can sign at all (local key or remote signer) —
    /// the check to gate signing UI on, rather than `Hex.decode(privkey)`,
    /// which is nil for remote accounts too.
    nonisolated static func canSign(_ keypair: Keypair) -> Bool {
        if keypair.isRemote { return true }
        guard let priv = Hex.decode(keypair.privkey) else { return false }
        return priv.count == 32
    }

    /// The live client for a remote account, restoring its saved session on
    /// first use (cold launch, account switch) so callers never race the
    /// restore. Keyed by pubkey: a client left over from a different account
    /// is never used to sign as this one.
    nonisolated private static func remoteClient(for keypair: Keypair) async throws -> Nip46Client {
        guard let client = await Nip46Manager.shared.client(for: keypair.pubkey) else {
            throw SignerError.noActiveRemoteSigner
        }
        return client
    }
}

extension Keypair {
    /// True for accounts where signing is delegated to a NIP-46 remote signer:
    /// no local private key, and a saved signer session for this pubkey.
    nonisolated var isRemote: Bool {
        privkey.isEmpty && Nip46SessionStore.isRemoteAccount(pubkey: pubkey)
    }

    /// True for accounts logged in via npub/nprofile QR scan — read-only, no signing capability.
    var isWatchOnly: Bool { NostrKey.isWatchOnly(pubkey: pubkey) }
}
