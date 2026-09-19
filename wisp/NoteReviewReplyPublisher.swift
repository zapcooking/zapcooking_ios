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
/// event; `failed` only when the relay set itself is empty.
struct RelayNoteReviewReplyPublisher: NoteReviewReplyPublishing {
    /// Web `RETRY_PUBLISH_TIMEOUT_MS` — 15 s of waiting on a relay OK.
    static let okTimeout: TimeInterval = 15

    var okTimeout: TimeInterval
    /// Relay set for a reply from `author` to `parent`. Defaults to the
    /// thread composer's rule; the live gate pins `RelayDefaults.defaults`.
    var relayResolver: (_ parent: NostrEvent, _ author: String) async -> [String]
    var broadcast: (_ event: NostrEvent, _ relays: [String], _ timeout: TimeInterval) async -> [String]
    var persist: (_ event: NostrEvent) async -> Void

    init(
        okTimeout: TimeInterval = RelayNoteReviewReplyPublisher.okTimeout,
        relayResolver: ((_ parent: NostrEvent, _ author: String) async -> [String])? = nil,
        broadcast: ((_ event: NostrEvent, _ relays: [String], _ timeout: TimeInterval) async -> [String])? = nil,
        persist: ((_ event: NostrEvent) async -> Void)? = nil
    ) {
        self.okTimeout = okTimeout
        self.relayResolver = relayResolver ?? { parent, author in
            await RelayNoteReviewReplyPublisher.replyRelays(parent: parent, author: author)
        }
        self.broadcast = broadcast ?? { event, relays, timeout in
            await RelayPool.publish(event: event, to: relays, timeout: timeout)
        }
        self.persist = persist ?? { event in await EventStore.shared.persist([event]) }
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
        let relays = await relayResolver(parent, event.pubkey)
        if relays.isEmpty { return .failed }
        let accepted = await broadcast(event, relays, okTimeout)
        if accepted.isEmpty { return .timeout(signed: event) }
        // Local bookkeeping mirrors the thread composer so the reply is in
        // the durable cache without waiting for the relay echo.
        await persist(event)
        return .published(event)
    }
}
