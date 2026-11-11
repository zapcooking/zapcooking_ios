import Foundation
import Testing
@testable import wisp

/// A stand-in NIP-46 signer: signs whatever template it's sent with its own
/// key, optionally moving `created_at` first (a signer that re-stamps the
/// event, or one answering a different request).
private actor FakeRemoteSigner: RemoteSigning {
    let privkey: Data
    let pubkey: String
    let createdAtShift: Int
    private(set) var requestedCreatedAt: [Int] = []

    init(privkey: Data, pubkey: String, createdAtShift: Int = 0) {
        self.privkey = privkey
        self.pubkey = pubkey
        self.createdAtShift = createdAtShift
    }

    func signEvent(unsigned: [String: Any]) async throws -> NostrEvent {
        guard let kind = unsigned["kind"] as? Int,
              let createdAt = unsigned["created_at"] as? Int,
              let tags = unsigned["tags"] as? [[String]],
              let content = unsigned["content"] as? String else {
            throw Nip46.NipError.malformedResponse
        }
        requestedCreatedAt.append(createdAt)
        return try NostrEvent.sign(privkey32: privkey, pubkey: pubkey, kind: kind,
                                   createdAt: createdAt + createdAtShift, tags: tags, content: content)
    }

    func nip44Encrypt(peerPubkeyHex: String, plaintext: String) async throws -> String {
        throw Signer.SignerError.remoteSignerUnsupported
    }

    func nip44Decrypt(peerPubkeyHex: String, ciphertext: String) async throws -> String {
        throw Signer.SignerError.remoteSignerUnsupported
    }
}

/// `Signer.sign` for a remote (NIP-46) account, driven through a fake signer.
/// Regression cover for c2e39ba: the returned event's `created_at` was compared
/// to the optional `createdAt` parameter, which is nil for most callers, so
/// every remote signature was rejected as malformed.
@MainActor
@Suite(.serialized)
struct RemoteSignerCreatedAtTests {

    private static let sessionListKey = "nip46_account_pubkeys"

    /// Registers a fresh remote account (session list entry + fake signer),
    /// runs `body`, and removes both whatever happens.
    private func withRemoteAccount(
        createdAtShift: Int = 0,
        _ body: (Keypair, FakeRemoteSigner) async throws -> Void
    ) async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = Hex.encode(try Schnorr.xonlyPubkey(privkey32: priv))
        let fake = FakeRemoteSigner(privkey: priv, pubkey: pub, createdAtShift: createdAtShift)
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: Self.sessionListKey)
        defaults.set((saved ?? []) + [pub], forKey: Self.sessionListKey)
        Signer.remoteSigningOverrides[pub] = fake
        defer {
            Signer.remoteSigningOverrides[pub] = nil
            if let saved { defaults.set(saved, forKey: Self.sessionListKey) }
            else { defaults.removeObject(forKey: Self.sessionListKey) }
        }
        let keypair = Keypair(privkey: "", pubkey: pub)
        #expect(keypair.isRemote)
        try await body(keypair, fake)
    }

    @Test func signsWithNoCreatedAtPassed() async throws {
        try await withRemoteAccount { keypair, fake in
            let before = NostrClock.now()
            let event = try await Signer.sign(keypair: keypair, kind: 1,
                                              tags: [["t", "soup"]], content: "remote hello")
            let sent = await fake.requestedCreatedAt
            #expect(sent.count == 1)
            #expect(event.createdAt == sent.first)
            #expect(event.createdAt >= before)
            #expect(event.pubkey == keypair.pubkey)
            #expect(event.content == "remote hello")
            #expect(event.hasValidSignature())
        }
    }

    @Test func rejectsADifferentCreatedAtAsMalformed() async throws {
        try await withRemoteAccount(createdAtShift: 7) { keypair, _ in
            do {
                _ = try await Signer.sign(keypair: keypair, kind: 1, tags: [], content: "remote hello")
                Issue.record("a re-stamped event was accepted")
            } catch let error as Nip46.NipError {
                guard case .malformedResponse = error else {
                    Issue.record("expected malformedResponse, got \(error)")
                    return
                }
            }
        }
    }

    /// End to end: the same refusal surfaces in a real status line through
    /// `localizedDescription`, as the case's text rather than the generic
    /// "The operation couldn't be completed" string. Signing fails before any
    /// relay I/O, so this stays hermetic.
    @Test func refusalReadsAsItsDescriptionInTheMediaServersStatus() async throws {
        try await withRemoteAccount(createdAtShift: 7) { keypair, _ in
            let vm = MediaServersViewModel(pubkey: keypair.pubkey)
            await vm.publish(keypair: keypair)
            #expect(vm.publishState == .failed("Signing failed: Malformed signer response"))
        }
    }

    @Test func everyErrorCaseLocalizesToItsDescription() {
        let nipErrors: [Nip46.NipError] = [
            .invalidBunkerUri("x"), .invalidNostrconnectUri("x"), .malformedResponse,
            .rpcError("signer said no"), .timeout(method: "sign_event"), .noRelays,
            .relaysUnreachable, .secretMismatch, .decryptFailed, .alreadyConnected,
            .notConnected, .invalidKey
        ]
        for e in nipErrors {
            #expect((e as Error).localizedDescription == e.description)
        }
        let signerErrors: [Signer.SignerError] = [
            .noActiveRemoteSigner, .localKeyMissing, .remoteSignerUnsupported, .malformedPayload
        ]
        for e in signerErrors {
            #expect((e as Error).localizedDescription == e.description)
        }
    }
}
