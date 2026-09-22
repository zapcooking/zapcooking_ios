import Foundation
import Testing
@testable import wisp

/// NIP-22 comments count and label as replies, following Sidecar
/// (dmnyc/sidecar#326) rather than wisp-ios#470.
///
/// The fixture is the six-event conversation Sidecar captured off public
/// relays on 2026-09-17, signatures verified, in which a kind-1 thread
/// continues in kind-1111 from the third event on:
///
///   1. Gatsby  kind 1     thread parent, mentions Amelia
///   2. Amelia  kind 1     reply to 1
///   3. Gatsby  kind 1111  E=1 K=1, e=2 k=1        ← the switch
///   4. Amelia  kind 1111  E=1 K=1, e=3 k=1111
///   5. Gatsby  kind 1111  E=1 K=1, e=4 k=1111
///   6. Amelia  kind 1111  E=1 K=1, e=5 k=1111
///
/// The shape matters: every comment stays rooted on the *kind-1* note, so a
/// client that only reads `I`-rooted comments — which is what we did — sees
/// none of events 3-6.
struct Nip22ReplyParityTests {

    private let gatsby = String(repeating: "a", count: 64)
    private let amelia = String(repeating: "b", count: 64)

    private func comment(
        id: String, author: String,
        root: String, rootKind: String, rootAuthor: String,
        parent: String, parentKind: String, parentAuthor: String
    ) -> NostrEvent {
        NostrEvent(
            id: id, pubkey: author, kind: Nip22.kindComment, createdAt: 0,
            tags: [
                ["E", root, "", rootAuthor],
                ["K", rootKind],
                ["P", rootAuthor],
                ["e", parent, "", parentAuthor],
                ["k", parentKind],
                ["p", parentAuthor],
            ],
            content: "", sig: ""
        )
    }

    /// Event 3: the switch from kind-1 to kind-1111, still rooted on the
    /// kind-1 note.
    private var event3: NostrEvent {
        comment(id: "e3", author: gatsby,
                root: "e1", rootKind: "1", rootAuthor: gatsby,
                parent: "e2", parentKind: "1", parentAuthor: amelia)
    }

    /// Event 4: a comment answering a comment.
    private var event4: NostrEvent {
        comment(id: "e4", author: amelia,
                root: "e1", rootKind: "1", rootAuthor: gatsby,
                parent: "e3", parentKind: "1111", parentAuthor: gatsby)
    }

    // MARK: - Reading an event-rooted comment

    /// The accessors that did not exist before: everything here is the
    /// uppercase/lowercase event form, not the `I` form.
    @Test func eventRootedComment_parsesBothScopes() {
        let e = event4
        #expect(Nip22.rootEventId(of: e) == "e1")
        #expect(Nip22.rootKindRaw(of: e) == "1")
        #expect(Nip22.rootAuthor(of: e) == gatsby)
        #expect(Nip22.parentEventId(of: e) == "e3")
        #expect(Nip22.parentKind(of: e) == Nip22.kindComment)
        #expect(Nip22.parentAuthor(of: e) == gatsby)
        // Rooted on an event, so the external accessors stay silent.
        #expect(Nip22.externalRoot(of: e) == nil)
        #expect(Nip22.externalParent(of: e) == nil)
    }

    /// `E` and `e` mean different things, so the lookup must not fold case.
    @Test func scopeLookup_isCaseSensitive() {
        let e = event4
        #expect(Nip22.rootEventId(of: e) != Nip22.parentEventId(of: e))
    }

    /// An external-root comment has no `k` integer — `k` is "web" there — so
    /// the caption falls back rather than reading a bogus kind.
    @Test func externalRootedComment_hasNoIntegerParentKind() {
        let web = NostrEvent(
            id: "ew", pubkey: amelia, kind: Nip22.kindComment, createdAt: 0,
            tags: [["I", "https://example.com/a"], ["K", "web"],
                   ["i", "https://example.com/a"], ["k", "web"]],
            content: "", sig: ""
        )
        #expect(Nip22.parentKind(of: web) == nil)
        #expect(Nip22.externalRoot(of: web)?.value == "https://example.com/a")
    }

    // MARK: - Labelling by immediate parent

    /// Sidecar's distinction, and the reason `parentKind` is carried onto the
    /// row: in this thread Gatsby owns the root note *and* comments further
    /// down, so "replied to your note" would be wrong for events 4 and 6.
    @Test func caption_followsTheImmediateParent() {
        var answeredMyNote = FlatNotificationItem(
            id: "x", kind: .reply, actorPubkey: amelia,
            referencedEventId: "e1", timestamp: 0
        )
        answeredMyNote.replyTargetIsMine = true
        answeredMyNote.parentKind = 1
        #expect(answeredMyNote.replyCaption == "replying to your note")

        var answeredMyComment = answeredMyNote
        answeredMyComment.parentKind = Nip22.kindComment
        #expect(answeredMyComment.replyCaption == "replying to your comment")

        // A kind-1 reply carries no parent kind and keeps the old wording.
        var plainReply = answeredMyNote
        plainReply.parentKind = nil
        #expect(plainReply.replyCaption == "replying to your note")

        // Nested under my thread but not answering me — unchanged.
        var inMyThread = answeredMyComment
        inMyThread.replyTargetIsMine = false
        #expect(inMyThread.replyCaption == "replying in your thread")
    }

    /// A comment is a reply for every purpose except wording — it must not
    /// become a new `NotificationKind`, or it would fall out of the replies
    /// filter and the effect table.
    @Test func commentStaysAReply_forFilteringAndEffects() {
        #expect(NotificationFilter.bucket(for: .reply) == .replies)
        let plan = NotificationEffectPlan.plan(for: .reply, soundsOn: true, typeEnabled: true)
        #expect(plan.sound == .reply)
        #expect(plan.haptic == .pulse)
    }

    // MARK: - Notification classification

    /// Events 3 and 4 of the captured thread, ingested for the account that
    /// owns each parent. Both must surface, and each must carry the parent
    /// kind that decides its wording.
    @MainActor
    @Test func mixedThread_surfacesCommentsAsReplies() {
        let repo = NotificationRepository.shared
        let savedSelfIds = repo.selfEventIds
        defer { repo.selfEventIds = savedSelfIds }

        // Amelia owns event 2; Gatsby's event 3 answers it.
        repo.bind(activePubkey: amelia)
        repo.selfEventIds = ["e2"]
        #expect(repo.ingest(event3, relayUrl: "", persist: false))
        let toAmelia = repo.flatItems.first { $0.id == "e3" }
        let a = try? #require(toAmelia)
        #expect(a?.kind == .reply)
        #expect(a?.actorPubkey == gatsby)
        #expect(a?.referencedEventId == "e2")
        // She was answered on a note, not a comment.
        #expect(a?.parentKind == 1)
        #expect(a?.replyCaption == "replying to your note")

        // Gatsby owns event 3; Amelia's event 4 answers that comment.
        repo.bind(activePubkey: gatsby)
        repo.selfEventIds = ["e1", "e3"]
        #expect(repo.ingest(event4, relayUrl: "", persist: false))
        let toGatsby = repo.flatItems.first { $0.id == "e4" }
        let g = try? #require(toGatsby)
        #expect(g?.kind == .reply)
        #expect(g?.referencedEventId == "e3")
        // He owns the root note too, so a flat "your note" would be wrong.
        #expect(g?.parentKind == Nip22.kindComment)
        #expect(g?.replyCaption == "replying to your comment")
    }

    /// A comment in a thread I have nothing to do with stays out.
    @MainActor
    @Test func unrelatedComment_isNotANotification() {
        let repo = NotificationRepository.shared
        let savedSelfIds = repo.selfEventIds
        defer { repo.selfEventIds = savedSelfIds }
        repo.bind(activePubkey: String(repeating: "c", count: 64))
        repo.selfEventIds = []
        #expect(repo.ingest(event4, relayUrl: "", persist: false) == false)
    }

    // MARK: - Publishing stays put

    /// wisp-ios#470 makes every reply kind-1 and deletes the comment tag
    /// builder. NIP-22's own "A reply to a comment" example is a kind-1111
    /// carrying `k: 1111`, and Sidecar labels a forced kind-1 answer to a
    /// comment nonstandard. We keep building comments.
    @Test func replyingToAComment_staysAComment() {
        let parent = NostrEvent(
            id: "ep", pubkey: gatsby, kind: Nip22.kindComment, createdAt: 0,
            tags: [["I", "https://example.com/a"], ["K", "web"],
                   ["i", "https://example.com/a"], ["k", "web"],
                   ["P", amelia]],
            content: "", sig: ""
        )
        let tags = Nip22.buildReplyTags(to: parent)
        let built = try? #require(tags)
        #expect(built?.contains { $0 == ["k", "1111"] } == true)
        #expect(built?.contains { $0.first == "I" } == true)
        // The root author survives the hop, as the spec requires.
        #expect(built?.contains { $0.count >= 2 && $0[0] == "P" && $0[1] == amelia } == true)
    }
}
