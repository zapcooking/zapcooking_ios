import Foundation
import Testing
@testable import wisp

/// Sub-thread suppression scoping for `.reply` notifications
/// (zapcooking/zapcooking_ios#220).
///
/// The ingest-time gate used to drop any reply whose p-tag chain named a
/// blocked pubkey anywhere. Because reply p-tags are built by carry-forward
/// and list every thread participant, a reply aimed straight at one of the
/// user's own events vanished whenever *any* participant was muted — most
/// visibly a kind-1 reply to the user's own kind-1111 comment, while pure
/// comment threads kept working (their lowercase `p` is only the parent
/// author). The policy these tests pin:
///
/// - replies targeting the user's OWN events always notify;
/// - for replies targeting someone else's event, only the parent author is
///   judged — via the cached parent event or the parent e-tag's author hint;
/// - `purgeAuthor` mirrors both halves.
///
/// Each case drives a fresh `NotificationRepository` instance rather than
/// `.shared`: the tests run hosted inside the live, logged-in app, whose
/// SwiftUI surfaces observe the shared repository and re-bind it to the
/// real account whenever test writes trigger a re-render — wiping fixture
/// state mid-test. A private instance has no observers. `SafetyFilter`
/// remains global, so each case still installs its own snapshot over the
/// host app's real mute/hellthread preferences.
@Suite(.serialized)
struct NotificationSubThreadSuppressionTests {

    private let a = String(repeating: "2", count: 64)   // non-blocked actor
    private let b = String(repeating: "3", count: 64)   // blocked replier
    private let x = String(repeating: "d", count: 64)   // muted elsewhere in the chain

    private func snapshot(blocked: Set<String>) -> SafetyFilterSnapshot {
        SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: blocked, mutedThreads: [],
            wotEnabled: false, qualifiedNetwork: [], userPubkey: ""
        )
    }

    // MARK: - Ingest: replies to my own events always notify

    /// The #220 regression: a kind-1 reply to my own kind-1111 comment whose
    /// carry-forward p-tag chain names a muted participant. The chain-wide
    /// check dropped this; only the parent author may be judged, and the
    /// target here is mine.
    @MainActor
    @Test func kind1ReplyToOwnComment_survivesMutedParticipantInChain() {
        let repo = NotificationRepository()
        let me = String(repeating: "e", count: 64)
        repo.bind(activePubkey: me)
        repo.selfEventIds = ["c220-mine"]   // my kind-1111 comment

        SafetyFilter.shared.install(snapshot(blocked: [x]))
        defer { SafetyFilter.shared.install(.empty) }

        let reply = NostrEvent(
            id: "r220-to-my-comment", pubkey: a, kind: 1, createdAt: 100,
            tags: [
                ["e", "c220-mine", "", "reply"],
                ["p", me],           // parent (me)
                ["p", x],            // muted participant carried forward
            ],
            content: "answering your comment", sig: ""
        )
        #expect(repo.ingest(reply, relayUrl: "", persist: false))

        let row = repo.flatItems.first { $0.id == "r220-to-my-comment" }
        let item = try? #require(row)
        #expect(item?.kind == .reply)
        #expect(item?.referencedEventId == "c220-mine")
        #expect(item?.replyTargetIsMine == true)
    }

    /// A reply in my thread answering ANOTHER participant still notifies when
    /// a muted pubkey rides along in the chain — the un-cached parent leaves
    /// no one to judge but the actor, who already passed the chokepoint.
    @MainActor
    @Test func kind1ReplyInMyThread_mutedParticipantElsewhere_shows() {
        let repo = NotificationRepository()
        let me = String(repeating: "6", count: 64)
        repo.bind(activePubkey: me)
        repo.selfEventIds = ["n220-mine"]

        SafetyFilter.shared.install(snapshot(blocked: [x]))
        defer { SafetyFilter.shared.install(.empty) }

        let other = String(repeating: "9", count: 64)
        let reply = NostrEvent(
            id: "r220-under-root", pubkey: a, kind: 1, createdAt: 101,
            tags: [
                ["e", "n220-mine", "", "root"],
                ["e", "o220-rep", "", "reply"],   // someone else's note
                ["p", me],
                ["p", other],                     // parent author
                ["p", x],                         // muted participant
            ],
            content: "", sig: ""
        )
        #expect(repo.ingest(reply, relayUrl: "", persist: false))
        let item = repo.flatItems.first { $0.id == "r220-under-root" }
        #expect(item?.replyTargetIsMine == false)
        #expect(item?.replyCaption == "replying in your thread")
    }

    // MARK: - Ingest: someone else's parent is still judged

    /// The case the gate exists for: non-blocked A answers blocked B's reply.
    /// B's event was seen (cached) before the mute, so the parent author
    /// resolves and the sub-thread stays suppressed.
    @MainActor
    @Test func kind1ReplyToBlockedParent_cachedBeforeMute_drops() {
        let repo = NotificationRepository()
        let me = String(repeating: "5", count: 64)
        repo.bind(activePubkey: me)
        repo.selfEventIds = ["n220-mine"]

        // B answered my note before being muted — event lands in the cache.
        let bsReply = NostrEvent(
            id: "b220-rep", pubkey: b, kind: 1, createdAt: 100,
            tags: [["e", "n220-mine", "", "root"], ["p", me]],
            content: "", sig: ""
        )
        #expect(repo.ingest(bsReply, relayUrl: "", persist: false))

        SafetyFilter.shared.install(snapshot(blocked: [b]))
        defer { SafetyFilter.shared.install(.empty) }

        let aReplies = NostrEvent(
            id: "r220-to-b", pubkey: a, kind: 1, createdAt: 101,
            tags: [
                ["e", "n220-mine", "", "root"],
                ["e", "b220-rep", "", "reply"],
                ["p", me],
                ["p", b],
            ],
            content: "", sig: ""
        )
        #expect(repo.ingest(aReplies, relayUrl: "", persist: false) == false)
        #expect(repo.flatItems.contains { $0.id == "r220-to-b" } == false)
    }

    /// Kind-1111 comments carry the parent author in the lowercase e-tag's
    /// hint slot, so a comment answering a muted author's comment still
    /// drops — no cache needed.
    @MainActor
    @Test func commentAnsweringMutedAuthor_drops() {
        let repo = NotificationRepository()
        let me = String(repeating: "8", count: 64)
        repo.bind(activePubkey: me)
        repo.selfEventIds = ["n220-mine"]

        SafetyFilter.shared.install(snapshot(blocked: [x]))
        defer { SafetyFilter.shared.install(.empty) }

        let comment = NostrEvent(
            id: "c220-under-root-x", pubkey: a, kind: Nip22.kindComment, createdAt: 100,
            tags: [
                ["E", "n220-mine", "", me],
                ["K", "1"],
                ["P", me],
                ["e", "x220-comment", "", x],
                ["k", "1111"],
                ["p", x],
            ],
            content: "", sig: ""
        )
        #expect(repo.ingest(comment, relayUrl: "", persist: false) == false)
        #expect(repo.flatItems.contains { $0.id == "c220-under-root-x" } == false)
    }

    /// Same shape, parent author not muted: the hint resolves, nobody
    /// matches, the row surfaces.
    @MainActor
    @Test func commentAnsweringUnmutedAuthor_shows() {
        let repo = NotificationRepository()
        let me = String(repeating: "8", count: 64)
        repo.bind(activePubkey: me)
        repo.selfEventIds = ["n220-mine"]

        SafetyFilter.shared.install(snapshot(blocked: [x]))
        defer { SafetyFilter.shared.install(.empty) }

        let other = String(repeating: "9", count: 64)
        let comment = NostrEvent(
            id: "c220-under-root-other", pubkey: a, kind: Nip22.kindComment, createdAt: 100,
            tags: [
                ["E", "n220-mine", "", me],
                ["K", "1"],
                ["P", me],
                ["e", "o220-comment", "", other],
                ["k", "1111"],
                ["p", other],
            ],
            content: "", sig: ""
        )
        #expect(repo.ingest(comment, relayUrl: "", persist: false))
        let item = repo.flatItems.first { $0.id == "c220-under-root-other" }
        #expect(item?.kind == .reply)
        #expect(item?.replyTargetIsMine == false)
    }

    // MARK: - purgeAuthor mirrors the ingest gate

    /// Blocking B later must purge B's own rows and the sub-thread answering
    /// B's event, but KEEP the reply to my own note that merely p-tags B —
    /// the chain-wide mirror of the #220 fix.
    @MainActor
    @Test func purgeAuthor_keepsRepliesToOwnEvents_purgesBlockedSubThreads() {
        let repo = NotificationRepository()
        let me = String(repeating: "7", count: 64)
        repo.bind(activePubkey: me)
        repo.selfEventIds = ["n220-mine"]

        func kind1(_ id: String, tags: [[String]], createdAt: Int) -> NostrEvent {
            NostrEvent(id: id, pubkey: a, kind: 1, createdAt: createdAt, tags: tags, content: "", sig: "")
        }

        // B answered my note (seen, cached); A answered my note (p-tags B);
        // A also answered B's reply. The tests run hosted in the real,
        // logged-in app, whose own SafetyFilter snapshot (real mute /
        // hellthread prefs) would drop these two-p-tag fixtures at the
        // ingest chokepoint — install a clean one like every other case.
        SafetyFilter.shared.install(snapshot(blocked: []))
        defer { SafetyFilter.shared.install(.empty) }

        #expect(repo.ingest(
            NostrEvent(id: "b220-rep", pubkey: b, kind: 1, createdAt: 100,
                       tags: [["e", "n220-mine", "", "root"], ["p", me]], content: "", sig: ""),
            relayUrl: "", persist: false))
        #expect(repo.ingest(
            kind1("r220-to-my-note", tags: [
                ["e", "n220-mine", "", "root"],
                ["p", me], ["p", b],
            ], createdAt: 101),
            relayUrl: "", persist: false))
        #expect(repo.ingest(
            kind1("r220-to-b-late", tags: [
                ["e", "n220-mine", "", "root"],
                ["e", "b220-rep", "", "reply"],
                ["p", me], ["p", b],
            ], createdAt: 102),
            relayUrl: "", persist: false))

        repo.purgeAuthor(b)
        // Kept: answers my own event, B only rides along in the chain.
        #expect(repo.flatItems.contains { $0.id == "r220-to-my-note" })
        // Purged: B's own row, and the reply to B's event.
        #expect(repo.flatItems.contains { $0.id == "b220-rep" } == false)
        #expect(repo.flatItems.contains { $0.id == "r220-to-b-late" } == false)
        #expect(repo.event(forId: "b220-rep") == nil)
    }
}
