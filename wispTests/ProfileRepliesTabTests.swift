import Foundation
import Testing
@testable import wisp

/// Pins the profile tab split for NIP-22 comments. A mixed kind-1/1111
/// thread is one conversation, but the comment half is invisible to the
/// Replies tab's old kind-1-only query: the thread root rides in the
/// uppercase `E`, which NIP-10 parsing never reads. Event-rooted comments
/// (`E`/`A`) therefore count as replies, while external ones (`I`) keep to
/// the Comments tab.
struct ProfileRepliesTabTests {

    private static let rootNoteId = "rootnote"
    private static let author = String(repeating: "a", count: 64)

    private func event(
        _ kind: Int,
        tags: [[String]],
        pubkey: String = Self.author
    ) -> NostrEvent {
        NostrEvent(id: "id\(kind)\(tags.count)", pubkey: pubkey, kind: kind,
                   createdAt: 0, tags: tags, content: "", sig: "")
    }

    // MARK: - Nip22.isEventRootedComment

    @Test func topLevelEventRootedCommentCounts() {
        // Top-level comment on a nostr note: lowercase `e` mirrors the `E` root.
        let e = event(1111, tags: [
            ["E", Self.rootNoteId, "wss://r", "rootpk"], ["K", "1"],
            ["e", Self.rootNoteId, "wss://r", "rootpk"], ["k", "1"],
            ["p", "rootpk"],
        ])
        #expect(Nip22.isEventRootedComment(e))
    }

    @Test func nestedEventRootedCommentCounts() {
        // Comment-to-comment: `E` stays the thread root, `e` names the parent
        // comment — the exact shape a mixed thread produces below the first
        // reply, and the one a kind-1-only Replies tab dropped.
        let e = event(1111, tags: [
            ["E", Self.rootNoteId, "wss://r", "rootpk"], ["K", "1"],
            ["e", "parentcomment", "wss://r", "parentpk"], ["k", "1111"],
            ["p", "parentpk"],
        ])
        #expect(Nip22.isEventRootedComment(e))
    }

    @Test func addressableRootedCommentCounts() {
        let e = event(1111, tags: [
            ["A", "30023:rootpk:recipes"], ["K", "30023"],
            ["e", "parentcomment", "wss://r", "parentpk"],
        ])
        #expect(Nip22.isEventRootedComment(e))
    }

    @Test func externalTopLevelCommentDoesNotCount() {
        let e = event(1111, tags: [
            ["I", "https://example.com/a"], ["K", "web"],
            ["i", "https://example.com/a"], ["k", "web"],
        ])
        #expect(!Nip22.isEventRootedComment(e))
    }

    @Test func externalNestedCommentDoesNotCount() {
        // The trap: a reply to a comment on a web page carries a lowercase
        // `e` (the parent comment), so "has an `e` tag" would wrongly pull
        // it into Replies. The root scope `I` is what excludes it.
        let e = event(1111, tags: [
            ["I", "https://example.com/a"], ["K", "web"],
            ["e", "parentcomment", "wss://r", "parentpk"], ["k", "1111"],
        ])
        #expect(!Nip22.isEventRootedComment(e))
    }

    @Test func unscopedCommentDoesNotCount() {
        // A comment with no E/A/I root is unthreadable by anyone — the same
        // shape `Nip22.buildReplyTags` refuses to answer. It belongs in no
        // profile list.
        let e = event(1111, tags: [["e", "parentcomment", "wss://r", "pk"]])
        #expect(!Nip22.isEventRootedComment(e))
    }

    @Test func kindOneWithEventRootTagIsNotAComment() {
        let e = event(1, tags: [["E", Self.rootNoteId], ["e", Self.rootNoteId]])
        #expect(!Nip22.isEventRootedComment(e))
    }

    // MARK: - ProfileViewModel.isReply (the tab split)

    @MainActor
    private func makeViewModel() -> ProfileViewModel {
        ProfileViewModel(pubkey: Self.author, activeUserPubkey: String(repeating: "b", count: 64))
    }

    @Test @MainActor func kindOneReplyStaysIn() {
        let vm = makeViewModel()
        let reply = event(1, tags: [
            ["e", Self.rootNoteId, "wss://r", "root"],
            ["e", "parentnote", "wss://r", "reply"],
            ["p", "rootpk"],
        ])
        #expect(vm.isReply(reply))
    }

    @Test @MainActor func kindOneRootNoteStaysOut() {
        let vm = makeViewModel()
        #expect(!vm.isReply(event(1, tags: [])))
    }

    @Test @MainActor func mixedThreadCommentIsAReply() {
        // The reported bug: this kind-1111 was invisible on the profile —
        // too comment-shaped for the kind-1 Replies query, too event-rooted
        // for the external-only Comments tab.
        let vm = makeViewModel()
        let comment = event(1111, tags: [
            ["E", Self.rootNoteId, "wss://r", "rootpk"], ["K", "1"],
            ["e", "parentcomment", "wss://r", "parentpk"], ["k", "1111"],
            ["p", "parentpk"],
        ])
        #expect(vm.isReply(comment))
    }

    @Test @MainActor func externalCommentStaysInCommentsTab() {
        let vm = makeViewModel()
        let comment = event(1111, tags: [
            ["I", "https://example.com/a"], ["K", "web"],
            ["i", "https://example.com/a"], ["k", "web"],
        ])
        #expect(!vm.isReply(comment))
    }

    @Test @MainActor func someoneElsesCommentStaysOut() {
        let vm = makeViewModel()
        let comment = event(1111, tags: [
            ["E", Self.rootNoteId], ["e", "parentcomment"],
        ], pubkey: String(repeating: "c", count: 64))
        #expect(!vm.isReply(comment))
    }
}
