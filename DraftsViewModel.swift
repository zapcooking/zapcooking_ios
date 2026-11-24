import Foundation
import Observation

/// View model for the "Drafts & Scheduled" screen.
///
/// Drafts are NIP-37 (kind 31234) addressable events on the user's write relays,
/// self-encrypted with NIP-44. Scheduled posts are events signed with a future
/// `created_at` and held by Zap Cooking's scheduler API (`ScheduleApi`,
/// `docs/schedule-contract.md` in zapcooking/frontend), which broadcasts them
/// at that time. The list is the account's rows there, so a post scheduled on
/// web or Android shows here too.
@Observable
@MainActor
final class DraftsViewModel {

    enum Tab: Hashable { case drafts, scheduled }

    let keypair: Keypair

    var drafts: [Nip37.Draft] = []
    /// Waiting to go out, next up first.
    private(set) var pendingPosts: [ScheduledPost] = []
    /// Gave up; shown under the pending ones with a plain explanation.
    private(set) var failedPosts: [ScheduledPost] = []
    /// Every row the Scheduled tab shows, in order.
    var scheduledPosts: [ScheduledPost] { pendingPosts + failedPosts }
    /// Why the pending list could not be loaded, when it could not.
    var scheduledLoadError: String?
    /// What happened to the last cancel that did not simply work.
    var scheduledNotice: String?
    /// Rows with a cancel in flight.
    private(set) var cancellingIds: Set<String> = []
    /// Test and harness seam; nil means `ScheduledPostsApi.live`.
    @ObservationIgnored var scheduledListing: (any ScheduledListing)?
    @ObservationIgnored private var scheduledLoadGeneration = 0
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

    private var listing: any ScheduledListing { scheduledListing ?? ScheduledPostsApi.live }

    /// Load the account's pending and failed posts from the scheduler API,
    /// both at once. The pending ones are shown the moment they arrive; the
    /// failed ones join when theirs does, and if that request fails the
    /// pending list stands on its own. Nothing is cached between calls: every
    /// load is the server's current answer.
    func loadScheduledPosts() async {
        scheduledLoadGeneration += 1
        let generation = scheduledLoadGeneration
        isLoadingScheduled = true
        let listing = listing
        let keypair = keypair

        async let failedResult = listing.list(status: .failed, keypair: keypair)
        let pendingResult = await listing.list(status: .pending, keypair: keypair)
        // A newer load (a pull to refresh during this one) owns the screen.
        if generation == scheduledLoadGeneration {
            switch pendingResult {
            case .success(let posts):
                pendingPosts = ScheduledList.pendingOrder(posts)
                scheduledLoadError = nil
            case .failure(let failure):
                scheduledLoadError = ScheduledList.loadMessage(for: failure)
            }
            isLoadingScheduled = false
        }

        let failed = await failedResult
        guard generation == scheduledLoadGeneration else { return }
        // On an error the failed rows already on screen stay as they are.
        if case .success(let posts) = failed {
            failedPosts = ScheduledList.failedOrder(posts)
        }
    }

    /// Cancel a pending post. The row stays, marked as cancelling, until the
    /// server answers: it is removed only once the post really is cancelled.
    /// If it cannot be cancelled any more (it is being published, or already
    /// went out) the list says so and reloads to show what is true now.
    func cancelScheduledPost(id: String) async {
        guard !cancellingIds.contains(id) else { return }
        cancellingIds.insert(id)
        scheduledNotice = nil
        let result = await listing.cancel(id: id, keypair: keypair)
        cancellingIds.remove(id)

        switch result {
        case .success:
            pendingPosts.removeAll { $0.id == id }
        case .failure(let failure):
            scheduledNotice = failure.message
            switch failure {
            case .notCancellable, .notFound:
                // The row on screen is out of date: fetch what is true now.
                await loadScheduledPosts()
            default:
                break
            }
        }
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
