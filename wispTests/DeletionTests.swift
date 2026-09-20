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

    // MARK: - Nip09 read helpers

    @Test func deletedEventIdsReadsETags() {
        let deletion = event(kind: 5, pubkey: alice, tags: [
            ["e", noteId],
            ["k", "1"],
            ["e", otherNoteId],
            ["p", bob]
        ])
        #expect(Nip09.deletedEventIds(deletion) == [noteId, otherNoteId])
    }

    @Test func deletedEventIdsIgnoresOtherKinds() {
        // Ordinary notes carry `e` tags for threading — reading them as deletion
        // targets would mark every parent in a thread as retracted.
        let reply = event(kind: 1, pubkey: alice, tags: [["e", noteId]])
        #expect(Nip09.deletedEventIds(reply).isEmpty)
    }

    @Test func deletionFilterConstrainsToTargetAndAuthor() {
        let filter = Nip09.deletionFilter(eventId: noteId, authors: [alice])
        #expect(filter.kinds == [Nip09.kindDeletion])
        #expect(filter.eTags == [noteId])
        #expect(filter.authors == [alice])
    }

    @Test func deletionFilterOmitsAuthorsWhenUnknown() {
        #expect(Nip09.deletionFilter(eventId: noteId, authors: nil).authors == nil)
        #expect(Nip09.deletionFilter(eventId: noteId, authors: []).authors == nil)
    }

    // MARK: - Registry attribution

    /// The app-wide gate and the quote card read the same store but ask
    /// different questions: the gate trusts the kind-5's optional author
    /// hint, the card demands the signer match the author it already knows.
    /// A stranger's kind-5 must not make the card claim the author retracted
    /// their note.
    @Test func strictLookupRejectsAStrangersRequest() {
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        let target = "aa" + String(repeating: "0", count: 62)
        let owner = "bb" + String(repeating: "0", count: 62)
        let stranger = "cc" + String(repeating: "0", count: 62)
        let request = NostrEvent(
            id: "dd" + String(repeating: "0", count: 62),
            pubkey: stranger, kind: Nip09.kindDeletion, createdAt: 0,
            tags: [["e", target]], content: "", sig: ""
        )
        DeletionTracker.shared.ingest(request)
        #expect(!DeletionTracker.shared.isDeleted(eventId: target, author: owner))
        #expect(DeletionTracker.shared.isDeleted(eventId: target, author: stranger))
    }

    /// An unknown author can't be matched, so the question is unanswerable —
    /// a bare `note1…` reference no relay will serve stays "not found" rather
    /// than being reported as retracted.
    @Test func strictLookupNeedsAnAuthor() {
        DeletionTracker.shared.clear()
        defer { DeletionTracker.shared.clear() }

        let target = "ee" + String(repeating: "0", count: 62)
        let signer = "ff" + String(repeating: "0", count: 62)
        DeletionTracker.shared.ingest(NostrEvent(
            id: "01" + String(repeating: "0", count: 62),
            pubkey: signer, kind: Nip09.kindDeletion, createdAt: 0,
            tags: [["e", target]], content: "", sig: ""
        ))
        #expect(!DeletionTracker.shared.isDeleted(eventId: target, author: nil))
    }

    // MARK: - Author hint plumbing

    @Test func parserKeepsTheNeventAuthorHint() {
        guard let idBytes = Hex.decode(noteId), let authorBytes = Hex.decode(alice),
              let nevent = Nip19.neventEncode(
                  eventId32: Array(idBytes),
                  relays: ["wss://relay.example.com"],
                  author32: Array(authorBytes)
              ) else {
            Issue.record("could not build an nevent")
            return
        }
        let segments = ContentParser.parse(content: "look at this nostr:\(nevent)", tags: [])
        var quote: (id: String, hints: [String], author: String?)?
        for segment in segments {
            if case .nostrNote(let id, let hints, let author) = segment {
                quote = (id, hints, author)
                break
            }
        }
        #expect(quote?.id == noteId)
        #expect(quote?.hints == ["wss://relay.example.com"])
        // The hint is what lets a deletion be attributed when the note itself
        // can no longer be fetched.
        #expect(quote?.author == alice)
    }

    @Test func parserLeavesBareNoteReferencesUnattributed() {
        guard let idBytes = Hex.decode(noteId),
              let note = Nip19.noteEncode(eventId: Array(idBytes)) else {
            Issue.record("could not build a note1")
            return
        }
        let segments = ContentParser.parse(content: "nostr:\(note)", tags: [])
        var quoteCount = 0
        var authors: [String] = []
        for segment in segments {
            if case .nostrNote(_, _, let author) = segment {
                quoteCount += 1
                if let author { authors.append(author) }
            }
        }
        #expect(quoteCount == 1)
        // A bare `note1…` carries no author, so a deletion request for it can
        // never be attributed — the card stays "not found" rather than guessing.
        #expect(authors.isEmpty)
    }
}
