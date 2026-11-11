import Foundation

/// Publishes a NIP-09 kind-5 deletion request for an event the active user authored.
///
/// Deletion requests are advisory — relays and other clients MAY honor them but are not
/// required to. Publish goes to both the user's write relays (so anyone pulling their
/// outbox sees the deletion) and any relays we've actually seen the original event on
/// (so those relays can drop their copy).
extension Notification.Name {
    /// Posted by `DeletionSender` after the user's kind 5 is published and
    /// recorded in `DeletionTracker`. `userInfo["eventIds"]` names the posts.
    /// Surfaces that pin the user's own posts (Fresh) drop them at once.
    static let eventDeletionRecorded = Notification.Name("WispEventDeletionRecorded")
}

@MainActor
final class DeletionSender {
    private static func announce(_ deletion: NostrEvent) {
        let ids = deletion.tags.filter { $0.count >= 2 && $0[0] == "e" }.map { $0[1] }
        NotificationCenter.default.post(name: .eventDeletionRecorded, object: nil, userInfo: ["eventIds": ids])
    }

    static let shared = DeletionSender()
    private init() {}

    enum SendError: Error {
        case missingKey
        case notAuthor
        case noRelays
        case publishFailed
    }

    /// Publish a kind-5 referencing `eventId` without requiring a full `NostrEvent` object.
    /// Used by undo flows (reaction undo, repost undo) where we track only the event id.
    func deleteById(_ eventId: String, kind: Int, keypair: Keypair, reason: String = "") async throws {
        var tags = Nip09.deletionTagsForEvent(id: eventId, kind: kind)
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: Nip09.kindDeletion,
                tags: tags,
                content: reason
            )
        } catch {
            throw SendError.missingKey
        }

        var set = Set<String>()
        let writes = await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
        for r in writes { set.insert(r) }
        for r in NoteSourceTracker.shared.relays(for: eventId) { set.insert(r) }
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            for entry in board.scoredRelays.prefix(3) { set.insert(entry.url) }
        }
        if set.isEmpty {
            set = ["wss://relay.primal.net", "wss://nos.lol"]
        }

        let succeeded = await RelayPool.publish(event: event, to: Array(set), timeout: 8)
        if succeeded.isEmpty { throw SendError.publishFailed }
        // Record locally too: a quoted-note card elsewhere in the app should
        // read "deleted by its author" immediately, not after some relay
        // happens to answer a kind-5 query.
        DeletionTracker.shared.ingest(event)
        Self.announce(event)
    }

    /// Publish a kind-5 referencing `targetEvent.id`. The caller MUST verify `targetEvent.pubkey
    /// == keypair.pubkey` at the UI layer; this method also enforces it defensively.
    func delete(_ targetEvent: NostrEvent, keypair: Keypair, reason: String = "") async throws {
        guard targetEvent.pubkey == keypair.pubkey else { throw SendError.notAuthor }

        var tags = Nip09.deletionTagsForEvent(id: targetEvent.id, kind: targetEvent.kind)
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: Nip09.kindDeletion,
                tags: tags,
                content: reason
            )
        } catch {
            throw SendError.missingKey
        }

        var set = Set<String>()
        let writes = await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
        for r in writes { set.insert(r) }
        for r in NoteSourceTracker.shared.relays(for: targetEvent.id) { set.insert(r) }
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            for entry in board.scoredRelays.prefix(3) { set.insert(entry.url) }
        }
        if set.isEmpty {
            set = ["wss://relay.primal.net", "wss://nos.lol"]
        }

        let succeeded = await RelayPool.publish(event: event, to: Array(set), timeout: 8)
        if succeeded.isEmpty { throw SendError.publishFailed }
        DeletionTracker.shared.ingest(event)
        Self.announce(event)
    }
}
