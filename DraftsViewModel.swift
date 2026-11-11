import Foundation
import Observation

/// View model for the "Drafts & Scheduled" screen.
///
/// Drafts are NIP-37 (kind 31234) addressable events on the user's write relays,
/// self-encrypted with NIP-44. Scheduled posts are normal kind-1 (and friends)
/// events with a future `created_at`, parked on `wss://scheduler.nostrarchives.com`
/// (NIP-42 AUTH required), which broadcasts them at the scheduled time.
///
/// Mirrors `DraftsViewModel.kt` in the Android client.
@Observable
@MainActor
final class DraftsViewModel {

    static let schedulerRelay = "wss://scheduler.nostrarchives.com"

    enum Tab: Hashable { case drafts, scheduled }

    let keypair: Keypair

    var drafts: [Nip37.Draft] = []
    var scheduledPosts: [NostrEvent] = []
    var isLoadingDrafts: Bool = false
    var isLoadingScheduled: Bool = false
    var selectedTab: Tab = .drafts
    var errorMessage: String?

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    // MARK: - Drafts

    /// Query write relays for the user's NIP-37 drafts, dedupe by `d` tag (latest
    /// `created_at` wins), decrypt, parse, and drop tombstones (empty content).
    func loadDrafts() async {
        isLoadingDrafts = true
        errorMessage = nil
        defer { isLoadingDrafts = false }

        let relays = topWriteRelays()
        var filter = NostrFilter()
        filter.kinds = [Nip37.kindDraft]
        filter.authors = [keypair.pubkey]
        filter.limit = 200

        let events = await RelayPool.query(relays: relays, filter: filter, timeout: 8)

        // Latest wrapper per `d` tag.
        var latestByDTag: [String: NostrEvent] = [:]
        for e in events {
            guard let dTag = e.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { continue }
            if let existing = latestByDTag[dTag], existing.createdAt >= e.createdAt { continue }
            latestByDTag[dTag] = e
        }

        guard Signer.canSign(keypair) else {
            errorMessage = "Couldn't derive draft encryption key."
            return
        }

        // Self-encrypted, so the peer is our own pubkey. Routed through `Signer`
        // so remote-signer (NIP-46) accounts decrypt via their signer app.
        var parsed: [Nip37.Draft] = []
        for wrapper in latestByDTag.values {
            guard let plaintext = try? await Signer.nip44Decrypt(
                keypair: keypair, peerPubkey: keypair.pubkey, payload: wrapper.content
            ) else { continue }
            // Empty plaintext from a successfully decrypted but empty payload is also a tombstone.
            if plaintext.isEmpty { continue }
            guard let draft = Nip37.parseDraft(wrapper: wrapper, decryptedJSON: plaintext) else { continue }
            // Drop drafts with no salvageable payload — empty text AND no
            // imeta attachments. Gallery drafts may legitimately have an
            // empty caption but still hold images / videos in their imeta
            // tags, so we keep those. Tombstones are already detected
            // upstream as empty wrapper content (line ~69).
            let trimmed = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasImeta = draft.tags.contains { $0.first == "imeta" }
            if trimmed.isEmpty && !hasImeta { continue }
            parsed.append(draft)
        }

        // Deduplicate by trimmed text content — keep newest among identical drafts.
        var latestByContent: [String: Nip37.Draft] = [:]
        for draft in parsed {
            let key = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = latestByContent[key], existing.createdAt >= draft.createdAt { continue }
            latestByContent[key] = draft
        }

        drafts = latestByContent.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Optimistically remove the draft locally, then publish:
    /// (a) a NIP-09 addressable deletion (kind 5 with an `a` tag), and
    /// (b) an empty-content NIP-37 replacement (covers clients that don't honor NIP-09).
    func deleteDraft(dTag: String) async {
        drafts.removeAll { $0.dTag == dTag }
        guard Signer.canSign(keypair) else { return }

        let now = NostrClock.now()
        let relays = topWriteRelays()

        // (a) NIP-09 addressable deletion.
        let delTags = Nip09.deletionTagsForAddressable(kind: Nip37.kindDraft, pubkey: keypair.pubkey, dTag: dTag)
        if let delEvent = try? await Signer.sign(
            keypair: keypair,
            kind: Nip09.kindDeletion, tags: delTags, content: "", createdAt: now
        ) {
            _ = await RelayPool.publish(event: delEvent, to: relays, timeout: 6)
        }

        // (b) Empty-content NIP-37 replacement. The inner JSON is non-empty, so
        // NIP-44's non-empty-plaintext rule is satisfied; parseDraft sees content "".
        let innerJSON = Nip37.serializeInner(
            pubkeyHex: keypair.pubkey, innerKind: 1, content: "", tags: [], createdAt: now
        )
        if let realCipher = try? await Signer.nip44Encrypt(
            keypair: keypair, peerPubkey: keypair.pubkey, plaintext: innerJSON
        ) {
            let wrapperTags = Nip37.wrapperTags(dTag: dTag, innerKind: 1)
            if let wrapper = try? await Signer.sign(
                keypair: keypair,
                kind: Nip37.kindDraft, tags: wrapperTags, content: realCipher, createdAt: now
            ) {
                _ = await RelayPool.publish(event: wrapper, to: relays, timeout: 6)
            }
        }
    }

    // MARK: - Scheduled posts

    /// Connect to the scheduler relay (with NIP-42 AUTH), subscribe for our own
    /// future-dated kind-1 events, collect until EOSE+grace, then return.
    func loadScheduledPosts() async {
        isLoadingScheduled = true
        errorMessage = nil
        defer { isLoadingScheduled = false }

        let relay = Self.schedulerRelay
        await GroupRelayPool.shared.ensureRelay(relay, keypair: keypair)
        await GroupRelayPool.shared.waitForAuthIfNeeded(relayUrl: relay, timeout: 5)

        var filter = NostrFilter()
        filter.kinds = [1]
        filter.authors = [keypair.pubkey]
        filter.limit = 100

        let subId = "scheduled_\(Int(Date().timeIntervalSince1970))"
        let stream = await GroupRelayPool.shared.subscribe(relayUrl: relay, filter: filter, subId: subId)

        var collected: [String: NostrEvent] = [:]
        var refusal: String?
        let collectTask = Task { @MainActor in
            for await item in stream {
                switch item {
                case .event(let event):
                    collected[event.id] = event
                case .authUnavailable:
                    refusal = "Scheduled posts need an account with a signing key."
                case .authFailed(let reason), .notMember(let reason), .closed(let reason):
                    refusal = "Scheduler relay refused the query: \(reason)"
                }
            }
        }
        // Give the relay 10s to deliver everything (matches Android).
        try? await Task.sleep(for: .seconds(10))
        await GroupRelayPool.shared.cancelSubscription(relayUrl: relay, subId: subId)
        collectTask.cancel()

        scheduledPosts = collected.values.sorted { $0.createdAt > $1.createdAt }
        // A relay refusal with nothing delivered was a silent empty list
        // before issue #6 made the state explicit.
        if scheduledPosts.isEmpty, let refusal {
            errorMessage = refusal
        }
    }

    /// Sign a NIP-09 deletion (kind 5 with `e`+`k` tags) and send it to the
    /// scheduler relay via the AUTH-aware retry path.
    func deleteScheduledPost(eventId: String) async {
        scheduledPosts.removeAll { $0.id == eventId }
        guard Signer.canSign(keypair) else { return }
        let tags = Nip09.deletionTagsForEvent(id: eventId, kind: 1)
        guard let event = try? await Signer.sign(
            keypair: keypair,
            kind: Nip09.kindDeletion, tags: tags, content: ""
        ) else { return }
        let relay = Self.schedulerRelay
        await GroupRelayPool.shared.ensureRelay(relay, keypair: keypair)
        _ = await GroupRelayPool.shared.publishWithAuthRetry(event, to: relay)
    }

    // MARK: - Helpers

    private func topWriteRelays() -> [String] {
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            let top = board.scoredRelays.prefix(5).map(\.url)
            if !top.isEmpty { return top }
        }
        return ["wss://relay.primal.net", "wss://nos.lol"]
    }
}
