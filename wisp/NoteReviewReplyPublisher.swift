import Foundation

/// Outcome of publishing a Cheffy Note Review draft as a kind-1 reply.
nonisolated enum NoteReviewPublishOutcome: Sendable {
    /// At least one relay accepted. The event is persisted locally.
    case published(NostrEvent)
    /// Signed and broadcast, but no relay OK inside the window. The reply
    /// may already be out there — retry via `publishSigned` with this exact
    /// event (same id; relays dedupe). Never discard it: re-signing would
    /// mint a second id and a double post.
    case timeout(signed: NostrEvent)
    /// Nothing was sent (no relay to send to). The draft stays intact;
    /// re-posting runs the full sign-and-send again.
    case failed
    /// The signer declined — a user choice, not a network error.
    case signRejected
}

/// Seam so the view model's publish state machine is unit-testable with
/// scripted outcomes. Production is `RelayNoteReviewReplyPublisher`.
protocol NoteReviewReplyPublishing {
    /// Sign the member-edited `content` as a NIP-10 reply to `parent`, then broadcast.
    func publish(content: String, parent: NostrEvent, keypair: Keypair) async -> NoteReviewPublishOutcome
    /// Timeout-retry path: re-broadcast an ALREADY-SIGNED event — no re-sign.
    func publishSigned(_ event: NostrEvent, parent: NostrEvent) async -> NoteReviewPublishOutcome
}

/// Publishes a Cheffy Note Review draft as a public kind-1 NIP-10 reply
/// (port of Android `RelayNoteReviewReplyPublisher`).
///
/// Deliberately NOT routed through `PostPublisher`: that path is
/// fire-and-forget (its OK tracking only drives the status pill) and never
/// surfaces the signed event, so it cannot satisfy the retry invariant (a
/// publish timeout must retain the SIGNED event so retry re-broadcasts the
/// same id). This publisher reuses the same primitives — `Nip10.buildReplyTags`
/// + the NIP-89 client tag, `ThreadViewModel`'s reply relay rule,
/// `RelayPool.publish` — and adds the explicit outcome on top.
///
/// `RelayPool.publish` returns the accepting relays after `timeout` and
/// cannot separate "no socket" from "no OK", so the mapping is: a non-empty
/// accept list → `published`; an empty one → `timeout` holding the signed
/// event; `failed` only when the relay set itself is empty. Pinned by
/// `NoteReviewReplyPublisherTests` through `NoteReviewReplyTransport`.
/// The relay-facing half of the publisher, behind a protocol so the outcome
/// mapping is testable with a recording fake. (Stored `async` closure
/// properties were the first seam; Swift 6.2 crashed both compiling and
/// running the reabstraction thunks for them, so a witness table it is.)
protocol NoteReviewReplyTransport {
    /// Relay set for a reply from `author` to `parent`.
    func relays(for parent: NostrEvent, author: String) async -> [String]
    /// Broadcast and return the accepting relays within `timeout`.
    func broadcast(_ event: NostrEvent, to relays: [String], timeout: TimeInterval) async -> [String]
    /// Local bookkeeping after an accept.
    func persist(_ event: NostrEvent) async
}

/// Production transport: `ThreadViewModel`'s reply relay rule,
/// `RelayPool.publish`, `EventStore` persistence.
struct RelayReplyTransport: NoteReviewReplyTransport {
    func relays(for parent: NostrEvent, author: String) async -> [String] {
        await RelayNoteReviewReplyPublisher.replyRelays(parent: parent, author: author)
    }

    func broadcast(_ event: NostrEvent, to relays: [String], timeout: TimeInterval) async -> [String] {
        await RelayPool.publish(event: event, to: relays, timeout: timeout)
    }

    func persist(_ event: NostrEvent) async {
        await EventStore.shared.persist([event])
    }
}

struct RelayNoteReviewReplyPublisher: NoteReviewReplyPublishing {
    /// Web `RETRY_PUBLISH_TIMEOUT_MS` — 15 s of waiting on a relay OK.
    static let okTimeout: TimeInterval = 15

    var okTimeout: TimeInterval
    var transport: any NoteReviewReplyTransport

    init(
        okTimeout: TimeInterval = RelayNoteReviewReplyPublisher.okTimeout,
        transport: any NoteReviewReplyTransport = RelayReplyTransport()
    ) {
        self.okTimeout = okTimeout
        self.transport = transport
    }

    /// The exact tag set the thread composer emits for a plain public reply:
    /// NIP-10 reply tags, then the NIP-89 client tag when the preference
    /// allows. Pure — pinned against `Nip10.buildReplyTags` by the tests.
    nonisolated static func replyTags(parent: NostrEvent) -> [[String]] {
        var tags = Nip10.buildReplyTags(replyTo: parent, relayHint: "")
        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }
        return tags
    }

    /// `ThreadViewModel.publishReply`'s relay rule: own write relays (or the
    /// outbox score board's top five plus `RelayDefaults.fallbacks` when the
    /// account has no NIP-65 list) ∪ the read relays of every pubkey the
    /// reply tags, minus the author.
    static func replyRelays(parent: NostrEvent, author: String) async -> [String] {
        var targets = Set<String>()
        let repo = RelayListRepository.shared
        let ownWrite = await repo.getWriteRelays(author)
        if ownWrite.isEmpty {
            if let board = RelayScoreBoard.load(pubkey: author) {
                for relay in board.scoredRelays.prefix(5) { targets.insert(relay.url) }
            }
            for url in RelayDefaults.fallbacks { targets.insert(url) }
        } else {
            for url in ownWrite { targets.insert(url) }
        }
        var inboxPubkeys = Set<String>()
        inboxPubkeys.insert(parent.pubkey)
        for tag in Nip10.participantTags(replyingTo: parent) where tag.count >= 2 {
            inboxPubkeys.insert(tag[1])
        }
        inboxPubkeys.remove(author)
        for pubkey in inboxPubkeys {
            for url in await repo.getReadRelays(pubkey) { targets.insert(url) }
        }
        return Array(targets)
    }

    func publish(content: String, parent: NostrEvent, keypair: Keypair) async -> NoteReviewPublishOutcome {
        // A watch-only / empty key cannot sign — "your signer, not the relays".
        if keypair.privkey.isEmpty { return .signRejected }
        let tags = Self.replyTags(parent: parent)
        let signed: NostrEvent
        do {
            signed = try await Signer.sign(
                keypair: keypair, kind: 1, tags: tags, content: content, createdAt: NostrClock.now()
            )
        } catch {
            return .signRejected
        }
        return await publishSigned(signed, parent: parent)
    }

    func publishSigned(_ event: NostrEvent, parent: NostrEvent) async -> NoteReviewPublishOutcome {
        let relays = await transport.relays(for: parent, author: event.pubkey)
        if relays.isEmpty { return .failed }
        let accepted = await transport.broadcast(event, to: relays, timeout: okTimeout)
        if accepted.isEmpty { return .timeout(signed: event) }
        // Local bookkeeping mirrors the thread composer so the reply is in
        // the durable cache without waiting for the relay echo.
        await transport.persist(event)
        return .published(event)
    }
}
