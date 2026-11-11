import Foundation

/// What `Signer` needs from a NIP-46 remote signer: sign an event template
/// and do NIP-44 as the user. `Nip46Client` is the production conformer; the
/// protocol exists so tests can stand a fake signer in for it
/// (`Signer.remoteSigningOverrides`, DEBUG only) and drive `Signer.sign`'s
/// remote branch, including the check that the signed event is the one asked for.
nonisolated protocol RemoteSigning: Sendable {
    func signEvent(unsigned: [String: Any]) async throws -> NostrEvent
    func nip44Encrypt(peerPubkeyHex: String, plaintext: String) async throws -> String
    func nip44Decrypt(peerPubkeyHex: String, ciphertext: String) async throws -> String
}

extension Nip46Client: RemoteSigning {}
