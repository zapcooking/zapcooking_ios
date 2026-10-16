import Foundation
import Testing
@testable import wisp

// Spec 0.6.2-draft conformance: the rules the changelog wrote down after a
// fifth implementation — items are distinct, a tag without a value is not
// one, a profile's items are its content fields, relay URLs compare
// normalized, and the re-read's "newer" follows NIP-01 (a later created_at,
// or the same second with a lower id).
// https://github.com/dmnyc/lazarus/blob/main/SPEC.md
struct LazarusSpec062Tests {

    private let relay = "wss://a"

    // MARK: - Item keys

    /// A tag without a value is not an item.
    @Test func aTagWithoutAValueIsNotAnItem() {
        let types = LazarusRegistry.profile(for: 3)!.itemTypes
        let tags: [[String]] = [["p", "a"], ["p"], ["p", ""], [""], ["p", "a", "hint"]]
        let keys = Set(tags.compactMap { Lazarus.itemKey($0, kind: 3, types: types, relayItems: false) })
        #expect(keys.count == 1)
        #expect(keys.first == ["p", "a"])
    }

    /// A tag whose type isn't the kind's is not an item.
    @Test func aTagOfAnotherTypeIsNotAnItem() {
        // Mutes count p, word, t and e; a follow list counts p only.
        #expect(Lazarus.itemKey(["word", "spam"], kind: 10000, types: ["p", "word", "t", "e"], relayItems: false) == ["word", "spam"])
        #expect(Lazarus.itemKey(["word", "spam"], kind: 3, types: ["p"], relayItems: false) == nil)
    }

    /// An unregistered kind has no type filter: every typed tag is an item.
    @Test func anUnregisteredKindAcceptsEveryTypedTag() {
        #expect(Lazarus.itemKey(["custom", "x"], kind: 9999, types: nil, relayItems: false) == ["custom", "x"])
        #expect(Lazarus.itemKey(["custom"], kind: 9999, types: nil, relayItems: false) == nil)
    }

    // MARK: - Relay URL comparison

    /// Scheme and host compare lowercased; a default port, repeated slashes
    /// and a trailing slash drop; paths and queries survive.
    @Test func relayURLsCompareNormalized() {
        let n = Lazarus.normalizeRelayURLForComparison
        #expect(n("wss://Relay.Example/") == "wss://relay.example")
        #expect(n("WSS://relay.example:443") == "wss://relay.example")
        #expect(n("wss://relay.example:8080") == "wss://relay.example:8080")
        #expect(n("ws://relay.example:80") == "ws://relay.example")
        #expect(n("wss://relay.example/a//b///") == "wss://relay.example/a/b")
        #expect(n(" wss://relay.example/path?q=1 ") == "wss://relay.example/path?q=1")
        #expect(n("wss://relay.example/path/") == "wss://relay.example/path")
        // Not parseable: compares as written, on both sides.
        #expect(n("not a url") == "not a url")
    }

    /// Two spellings of one relay are one item; a changed marker is not.
    @Test func aRelayURLRewriteIsNotAChangeButAMarkerChangeIs() {
        let current = LazarusFixture.event(kind: 10002, createdAt: 2000, tags: [["r", "wss://Relay.Example/", "write"]])
        let chosen = LazarusFixture.event(kind: 10002, createdAt: 1000, tags: [["r", "wss://relay.example", "write"]])
        let delta = Lazarus.delta(chosen: chosen, current: current)
        #expect(delta.addedCount == 0)
        #expect(delta.removedCount == 0)

        let other = LazarusFixture.event(kind: 10002, createdAt: 1000, tags: [["r", "wss://relay.example", "read"]])
        let markerDelta = Lazarus.delta(chosen: other, current: current)
        #expect(markerDelta.addedCount == 1)
        #expect(markerDelta.removedCount == 1)
    }

    /// A normalized rewrite also changes the registry count, not just the delta.
    @Test func registryCountsNormalizeRelayURLs() {
        let event = LazarusFixture.event(
            kind: 10002, createdAt: 1000,
            tags: [["r", "wss://A.Example/"], ["r", "wss://a.example"], ["r", "wss://b.example:443", "read"]]
        )
        #expect(LazarusRegistry.profile(for: 10002)!.itemCount(event).count == 2)
    }

    // MARK: - Distinct items

    /// A repeated tag is one item (spec 0.6.2: items are distinct).
    @Test func duplicateTagsCountOnce() {
        let event = LazarusFixture.event(createdAt: 1000, tags: [["p", "a"], ["p", "a"], ["p", "b"]])
        #expect(LazarusRegistry.profile(for: 3)!.itemCount(event).count == 2)
    }

    /// A profile's items are its content fields with a value: wiped to `{}`,
    /// nulls only, or content that isn't an object at all, it is empty.
    @Test func aProfileCountsItsValuedFields() {
        #expect(LazarusRegistry.profile(for: 0)!.itemCount(LazarusFixture.event(kind: 0, createdAt: 1000, content: "{}")).count == 0)
        #expect(LazarusRegistry.profile(for: 0)!.itemCount(LazarusFixture.event(kind: 0, createdAt: 1000, content: "{\"name\":null}")).count == 0)
        #expect(LazarusRegistry.profile(for: 0)!.itemCount(LazarusFixture.event(kind: 0, createdAt: 1000, content: "{\"name\":\"zap\",\"about\":null}")).count == 1)
        #expect(LazarusRegistry.profile(for: 0)!.itemCount(LazarusFixture.event(kind: 0, createdAt: 1000, content: "not json")).count == 0)
        #expect(LazarusRegistry.profile(for: 0)!.itemCount(LazarusFixture.event(kind: 0, createdAt: 1000, content: "[1,2]")).count == 0)
    }

    /// An item listed both publicly and privately is one item: only the
    /// private items the public tags don't hold add on to the exact count.
    @Test func privateCountsExcludeItemsThePublicTagsAlreadyHold() {
        let event = LazarusFixture.event(createdAt: 1000, tags: [["p", "a"], ["p", "b"]])
        let profile = LazarusRegistry.profile(for: 3)!
        let scan = Lazarus.rank(
            profile,
            [LazarusTaggedEvent(event: event, relayUrl: relay)],
            privateTags: [event.id: [["p", "b"], ["p", "c"]]]
        )
        let candidate = scan.candidates.first { $0.id == event.id }
        #expect(candidate?.itemCount.count == 2)
        #expect(candidate?.itemCount.privateCount == 1)
        #expect(candidate?.itemCount.range == LazarusCountRange(min: 3, max: 3))
    }

    // MARK: - Identical content, one private item set

    /// Two versions with identical encrypted content hold the same private
    /// items, counted or not: neither side reads as unknown, and the shared
    /// set compares instead of two opaque payloads.
    @Test func identicalContentHoldsTheSamePrivateItems() {
        let encrypted = String(repeating: "A", count: 200)
        let chosen = LazarusFixture.event(createdAt: 2000, tags: [["p", "a"]], content: encrypted)
        let current = LazarusFixture.event(createdAt: 1000, tags: [["p", "a"]], content: encrypted)
        let delta = Lazarus.delta(chosen: chosen, current: current)
        #expect(delta.addedCount == 0)
        #expect(delta.removedCount == 0)
        #expect(!delta.privateUnknown)
        #expect(!delta.currentPrivateUnknown)
        #expect(!delta.shrinks)
    }

    // MARK: - Re-read ordering

    /// NIP-01 in the re-read: a version from the same second with a lower id
    /// is strictly newer, and the restore must re-review against it.
    @Test func aSameSecondLowerIdReadsAsChanged() {
        let lower = String(repeating: "0", count: 64)
        let higher = String(repeating: "f", count: 64)
        let reviewed = LazarusFixture.event(id: higher, createdAt: 2000, tags: [["p", "a"]])
        let newer = LazarusFixture.event(id: lower, createdAt: 2000, tags: [["p", "b"]])
        let answers = [LazarusReadAnswer(events: [newer], answered: true, relay: relay)]
        guard case .changed(let current) = Lazarus.checkCurrent(reviewed: reviewed, local: nil, answers: answers) else {
            Issue.record("expected .changed")
            return
        }
        #expect(current.id == lower)
    }

    @Test func aSameSecondHigherIdIsNoChange() {
        let lower = String(repeating: "0", count: 64)
        let higher = String(repeating: "f", count: 64)
        let reviewed = LazarusFixture.event(id: lower, createdAt: 2000, tags: [["p", "a"]])
        let older = LazarusFixture.event(id: higher, createdAt: 2000, tags: [["p", "b"]])
        let answers = [LazarusReadAnswer(events: [older], answered: true, relay: relay)]
        guard case .proceed = Lazarus.checkCurrent(reviewed: reviewed, local: nil, answers: answers) else {
            Issue.record("expected .proceed")
            return
        }
    }

    /// A local stand-in has a synthetic id outside the NIP-01 order: at the
    /// same second it is never strictly newer, so it can't force a re-review
    /// (an answered relay would otherwise be trumped by this device's copy).
    @Test func aLocalCopyAtTheSameSecondIsNoChange() {
        let reviewed = LazarusFixture.event(id: String(repeating: "f", count: 64), createdAt: 2000, tags: [["p", "a"]])
        let local = NostrEvent(
            id: "local-3-2000", pubkey: LazarusFixture.pubkey, kind: 3, createdAt: 2000,
            tags: [["p", "b"]], content: "", sig: ""
        )
        let answers = [LazarusReadAnswer(events: [], answered: true, relay: relay)]
        guard case .proceed = Lazarus.checkCurrent(reviewed: reviewed, local: local, answers: answers) else {
            Issue.record("expected .proceed")
            return
        }
    }

    /// A later-second local copy is still newer, whatever its id.
    @Test func aLocalCopyFromALaterSecondIsChanged() {
        let reviewed = LazarusFixture.event(id: String(repeating: "f", count: 64), createdAt: 2000, tags: [["p", "a"]])
        let local = NostrEvent(
            id: "local-3-2500", pubkey: LazarusFixture.pubkey, kind: 3, createdAt: 2500,
            tags: [["p", "b"]], content: "", sig: ""
        )
        guard case .changed(let current) = Lazarus.checkCurrent(reviewed: reviewed, local: local, answers: []) else {
            Issue.record("expected .changed")
            return
        }
        #expect(current.id == "local-3-2500")
    }
}
