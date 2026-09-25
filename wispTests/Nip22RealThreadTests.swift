import Foundation
import Testing
@testable import wisp

/// The same NIP-22 handling, exercised against real relay bytes rather than
/// a hand-built fixture.
///
/// `Resources/nip22/sidecar-thread.json` is the tail of the conversation
/// Sidecar documented in dmnyc/sidecar#326, re-fetched from public relays on
/// 2026-09-22 — four kind-1111 comments, signatures as published. The two
/// kind-1 events that root the thread had already been dropped by every
/// relay queried, which is its own argument for reading comments properly:
/// the comments outlived the notes they hang off.
///
/// The synthetic fixture in `Nip22ReplyParityTests` models this shape. This
/// checks the model against the wire.
struct Nip22RealThreadTests {

    /// Chronological, oldest first.
    private static let events: [NostrEvent] = {
        // Synchronized folders can flatten or preserve the subdirectory, and
        // the resource may land in either bundle — try both, as NSpamTests
        // does for its model files.
        let candidates = [Bundle(for: BundleToken.self), Bundle.main].flatMap { bundle in
            [bundle.url(forResource: "sidecar-thread", withExtension: "json", subdirectory: "nip22"),
             bundle.url(forResource: "sidecar-thread", withExtension: "json")]
        }
        guard let url = candidates.compactMap({ $0 }).first,
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let pubkey = dict["pubkey"] as? String,
                  let kind = dict["kind"] as? Int,
                  let createdAt = dict["created_at"] as? Int,
                  let tags = dict["tags"] as? [[String]],
                  let content = dict["content"] as? String,
                  let sig = dict["sig"] as? String else { return nil }
            return NostrEvent(id: id, pubkey: pubkey, kind: kind,
                              createdAt: createdAt, tags: tags, content: content, sig: sig)
        }.sorted { $0.createdAt < $1.createdAt }
    }()

    private final class BundleToken {}

    @Test func fixture_loaded() {
        #expect(Self.events.count == 4, "fixture did not load")
        #expect(Self.events.allSatisfy { $0.kind == Nip22.kindComment })
    }

    /// Every comment is rooted on a **kind-1** note. This is the case our
    /// `Nip22` helper could not see at all — it only read the external `I`
    /// form — and the reason these were invisible to counting.
    @Test func everyComment_isRootedOnAKind1Note() {
        for e in Self.events {
            #expect(Nip22.rootKindRaw(of: e) == "1", "\(e.id.prefix(8))")
            #expect(Nip22.rootEventId(of: e) != nil, "\(e.id.prefix(8))")
            // Rooted on an event, so the external accessors stay quiet.
            #expect(Nip22.externalRoot(of: e) == nil, "\(e.id.prefix(8))")
        }
        // All four hang off the same root.
        #expect(Set(Self.events.compactMap { Nip22.rootEventId(of: $0) }).count == 1)
    }

    /// The parent chain walks back one event at a time, and `k` flips from
    /// 1 to 1111 at the switch — which is exactly the signal the caption
    /// reads.
    @Test func parentChain_walksBackAndFlipsKind() {
        let ids = Self.events.map(\.id)
        let parents = Self.events.map { Nip22.parentEventId(of: $0) }
        // Each comment after the first names its predecessor.
        for i in 1..<Self.events.count {
            #expect(parents[i] == ids[i - 1],
                    "comment \(i) should answer \(ids[i - 1].prefix(8)), got \(parents[i]?.prefix(8) ?? "nil")")
        }
        // The first answered a note; the rest answered comments.
        #expect(Nip22.parentKind(of: Self.events[0]) == 1)
        for e in Self.events.dropFirst() {
            #expect(Nip22.parentKind(of: e) == Nip22.kindComment, "\(e.id.prefix(8))")
        }
    }

    /// Ingesting the real chain as the author of each parent produces reply
    /// rows captioned by what was actually answered.
    @MainActor
    @Test func realChain_classifiesAndCaptions() {
        let repo = NotificationRepository.shared
        let savedSelfIds = repo.selfEventIds
        defer { repo.selfEventIds = savedSelfIds }

        for (i, event) in Self.events.enumerated() {
            guard let parentId = Nip22.parentEventId(of: event) else {
                Issue.record("no parent on \(event.id)"); continue
            }
            // Stand in as whoever owns the parent this comment answers.
            repo.bind(activePubkey: String(repeating: "f", count: 64))
            repo.selfEventIds = [parentId]
            #expect(repo.ingest(event, relayUrl: "", persist: false), "\(event.id.prefix(8)) ignored")

            let row = repo.flatItems.first { $0.id == event.id }
            let item = try? #require(row)
            #expect(item?.kind == .reply)
            #expect(item?.referencedEventId == parentId)
            // First answered a note, the rest answered comments.
            let expected = i == 0 ? "replying to your note" : "replying to your comment"
            #expect(item?.replyCaption == expected, "\(event.id.prefix(8))")
        }
    }
}
