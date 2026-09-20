import Testing
import Foundation
@testable import wisp

/// Covers the tracker side of NIP-09 deletion handling: which kind-5 `e`
/// tags record a deletion, the optional author-hint rule, and the
/// `SafetyFilter.shouldDrop` chokepoint.
///
/// Serialized: these exercise `DeletionTracker.shared`, a process-global
/// singleton, and they clear it. Run in parallel, a clear wipes another
/// test's data out from under it (upstream learned this the hard way).
@Suite(.serialized)
struct DeletionTests {

    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)
    private let noteId = String(repeating: "1", count: 64)
    private let otherNoteId = String(repeating: "2", count: 64)

    private func event(kind: Int, pubkey: String, tags: [[String]], content: String = "") -> NostrEvent {
        NostrEvent(
            id: String(repeating: "e", count: 64),
            pubkey: pubkey,
            kind: kind,
            createdAt: 1_700_000_000,
            tags: tags,
            content: content,
            sig: String(repeating: "c", count: 128)
        )
    }

    // MARK: - Ingest

    @Test func ingestRecordsETagIds() {
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        DeletionTracker.shared.ingest(event(kind: 5, pubkey: alice, tags: [
            ["e", noteId],
            ["k", "1"],
            ["e", otherNoteId],
            ["p", bob]
        ]))
        #expect(DeletionTracker.shared.isDeleted(noteId))
        #expect(DeletionTracker.shared.isDeleted(otherNoteId))
    }

    @Test func ingestIgnoresNonDeletionKinds() {
        // Ordinary notes carry `e` tags for threading — reading them as
        // deletion targets would mark every parent in a thread as retracted.
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        DeletionTracker.shared.ingest(event(kind: 1, pubkey: alice, tags: [["e", noteId]]))
        #expect(!DeletionTracker.shared.isDeleted(noteId))
    }

    @Test func ingestRejectsMismatchedAuthorHint() {
        // NIP-09: the kind-5's optional fourth `e`-tag element names the
        // deleted event's author. If present and different from the signer,
        // the request is not the author's and must be ignored.
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        DeletionTracker.shared.ingest(event(kind: 5, pubkey: bob, tags: [
            ["e", noteId, "wss://relay.example.com", alice]
        ]))
        #expect(!DeletionTracker.shared.isDeleted(noteId))
    }

    @Test func ingestAcceptsMissingOrEmptyAuthorHint() {
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        // Relay hint in position 2, no author hint at all.
        DeletionTracker.shared.ingest(event(kind: 5, pubkey: alice, tags: [
            ["e", noteId, "wss://relay.example.com"]
        ]))
        // Author hint present but empty.
        DeletionTracker.shared.ingest(event(kind: 5, pubkey: bob, tags: [
            ["e", otherNoteId, "", ""]
        ]))
        #expect(DeletionTracker.shared.isDeleted(noteId))
        #expect(DeletionTracker.shared.isDeleted(otherNoteId))
    }

    @Test func reingestReportsNoChange() {
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        let deletion = event(kind: 5, pubkey: alice, tags: [["e", noteId]])
        #expect(DeletionTracker.shared.ingest(deletion))
        #expect(!DeletionTracker.shared.ingest(deletion))
        #expect(!DeletionTracker.shared.ingestBatch([deletion]))
    }

    @Test func ingestBatchDedupesAcrossEvents() {
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        let first = event(kind: 5, pubkey: alice, tags: [["e", noteId]])
        var secondTags = first.tags
        secondTags.append(["k", "1"])
        let second = NostrEvent(
            id: String(repeating: "f", count: 64),
            pubkey: alice,
            kind: 5,
            createdAt: 1_700_000_001,
            tags: secondTags,
            content: "",
            sig: String(repeating: "c", count: 128)
        )
        #expect(DeletionTracker.shared.ingestBatch([first, second]))
        #expect(DeletionTracker.shared.ingestBatch([first, second]) == false)
        #expect(DeletionTracker.shared.isDeleted(noteId))
    }

    @Test func clearDropsEverything() {
        DeletionTracker.shared.clear()
        DeletionTracker.shared.ingest(event(kind: 5, pubkey: alice, tags: [["e", noteId]]))
        #expect(DeletionTracker.shared.isDeleted(noteId))
        DeletionTracker.shared.clear()
        #expect(!DeletionTracker.shared.isDeleted(noteId))
    }

    // MARK: - SafetyFilter chokepoint

    @Test func shouldDropHidesDeletedEvents() {
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        let target = NostrEvent(
            id: noteId,
            pubkey: alice,
            kind: 1,
            createdAt: 1_700_000_000,
            tags: [],
            content: "about to be retracted",
            sig: String(repeating: "c", count: 128)
        )
        #expect(!SafetyFilter.shared.shouldDrop(event: target, context: .feed))
        DeletionTracker.shared.ingest(event(kind: 5, pubkey: alice, tags: [["e", noteId]]))
        #expect(SafetyFilter.shared.shouldDrop(event: target, context: .feed))
    }
}
