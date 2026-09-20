import Foundation
import Testing
@testable import wisp

/// `RelayNoteReviewReplyPublisher` — the concrete publisher's outcome
/// mapping through its `NoteReviewReplyTransport` seam (relays / broadcast /
/// `persist`), so the same-id retry invariant cannot regress unnoticed: an
/// empty relay set is `failed`, an empty accept list is `timeout` holding
/// the EXACT signed event, and an accept persists and reports `published`.
/// No socket is opened.
@MainActor
struct NoteReviewReplyPublisherTests {

    private static func keypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private static let parent = NostrEvent(
        id: String(repeating: "ab", count: 32),
        pubkey: String(repeating: "cd", count: 32),
        kind: 1, createdAt: 1_700_000_000,
        tags: [["p", String(repeating: "ef", count: 32)]],
        content: "dinner https://example.com/dish.jpg",
        sig: String(repeating: "0", count: 128)
    )

    /// Recording transport with scripted relays / accepts.
    private final class FakeTransport: NoteReviewReplyTransport {
        let relaySet: [String]
        let accepted: [String]
        var resolved: [(parent: String, author: String)] = []
        var broadcasts: [(id: String, relays: [String], timeout: TimeInterval)] = []
        var persisted: [String] = []
        init(relays: [String], accepted: [String]) {
            self.relaySet = relays
            self.accepted = accepted
        }
        func relays(for parent: NostrEvent, author: String) async -> [String] {
            resolved.append((parent.id, author))
            return relaySet
        }
        func broadcast(_ event: NostrEvent, to relays: [String], timeout: TimeInterval) async -> [String] {
            broadcasts.append((event.id, relays, timeout))
            return accepted
        }
        func persist(_ event: NostrEvent) async { persisted.append(event.id) }
    }

    private func publisher(_ transport: FakeTransport) -> RelayNoteReviewReplyPublisher {
        RelayNoteReviewReplyPublisher(okTimeout: 3, transport: transport)
    }

    @Test func replyTags_areTheThreadComposersTagSet() {
        let tags = RelayNoteReviewReplyPublisher.replyTags(parent: Self.parent)
        var expected = Nip10.buildReplyTags(replyTo: Self.parent, relayHint: "")
        if let client = NostrEvent.clientTagIfEnabled() { expected.append(client) }
        #expect(tags == expected)
        #expect(tags.contains(["e", Self.parent.id, "", "root"]))
        #expect(tags.contains(["p", String(repeating: "ef", count: 32)]))
        #expect(tags.contains(["p", Self.parent.pubkey]))
    }

    @Test func emptyRelaySet_isFailed_withNoBroadcastAndNoPersist() async throws {
        let keypair = try Self.keypair()
        let trace = FakeTransport(relays: [], accepted: [])
        let outcome = await publisher(trace)
            .publish(content: "hi", parent: Self.parent, keypair: keypair)
        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(trace.resolved.count == 1)
        #expect(trace.resolved.first?.author == keypair.pubkey)
        #expect(trace.broadcasts.isEmpty)
        #expect(trace.persisted.isEmpty)
    }

    @Test func emptyAcceptList_isTimeout_holdingTheExactSignedEvent_andNothingPersisted() async throws {
        let keypair = try Self.keypair()
        let trace = FakeTransport(relays: ["wss://a", "wss://b"], accepted: [])
        let outcome = await publisher(trace)
            .publish(content: "my words", parent: Self.parent, keypair: keypair)
        guard case .timeout(let signed) = outcome else { Issue.record("expected timeout, got \(outcome)"); return }
        #expect(signed.kind == 1)
        #expect(signed.pubkey == keypair.pubkey)
        #expect(signed.content == "my words")
        #expect(signed.tags == RelayNoteReviewReplyPublisher.replyTags(parent: Self.parent))
        #expect(trace.broadcasts.map(\.id) == [signed.id])
        #expect(trace.broadcasts.first?.relays == ["wss://a", "wss://b"])
        #expect(trace.broadcasts.first?.timeout == 3)
        #expect(trace.persisted.isEmpty)
    }

    @Test func retry_republishesTheSameId_withoutResigning() async throws {
        let keypair = try Self.keypair()
        let trace = FakeTransport(relays: ["wss://a"], accepted: [])
        let first = await publisher(trace)
            .publish(content: "my words", parent: Self.parent, keypair: keypair)
        guard case .timeout(let signed) = first else { Issue.record("expected timeout"); return }
        let retry = FakeTransport(relays: ["wss://a"], accepted: ["wss://a"])
        let second = await publisher(retry)
            .publishSigned(signed, parent: Self.parent)
        guard case .published(let event) = second else { Issue.record("expected published, got \(second)"); return }
        #expect(event.id == signed.id)
        #expect(event.sig == signed.sig)
        #expect(trace.broadcasts.map(\.id) == [signed.id])
        #expect(retry.broadcasts.map(\.id) == [signed.id])
        #expect(trace.persisted.isEmpty)
        #expect(retry.persisted == [signed.id])
    }

    @Test func accept_isPublished_andPersisted() async throws {
        let keypair = try Self.keypair()
        let trace = FakeTransport(relays: ["wss://a"], accepted: ["wss://a"])
        let outcome = await publisher(trace)
            .publish(content: "hi", parent: Self.parent, keypair: keypair)
        guard case .published(let event) = outcome else { Issue.record("expected published, got \(outcome)"); return }
        #expect(event.content == "hi")
        #expect(trace.persisted == [event.id])
    }

    @Test func emptyPrivkey_isSignRejected_beforeAnyRelayWork() async throws {
        let keypair = try Self.keypair()
        let trace = FakeTransport(relays: ["wss://a"], accepted: ["wss://a"])
        let outcome = await publisher(trace)
            .publish(content: "hi", parent: Self.parent, keypair: Keypair(privkey: "", pubkey: keypair.pubkey))
        guard case .signRejected = outcome else { Issue.record("expected signRejected, got \(outcome)"); return }
        #expect(trace.resolved.isEmpty)
        #expect(trace.broadcasts.isEmpty)
    }
}
