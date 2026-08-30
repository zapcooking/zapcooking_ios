import Foundation
import Testing
@testable import wisp

/// Pure helpers ported from Android `OnlyFoodLatchTest` / `OnlyFoodPagingTest`
/// / `OnlyFoodOrderTest` / `OnlyFoodIngestTest`.
struct OnlyFoodHelpersTests {

    private func ev(_ id: String, createdAt: Int, foodTag: Bool = true) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: "pk",
            kind: 1,
            createdAt: createdAt,
            tags: foodTag ? [["t", "foodstr"]] : [],
            content: "",
            sig: ""
        )
    }

    @Test func genuineEose_latches_evenWithZeroEvents() {
        #expect(shouldLatchLoaded(connected: true, anySent: true, eoseFired: true))
    }

    @Test func eoseTimeout_doesNotLatch() {
        #expect(!shouldLatchLoaded(connected: true, anySent: true, eoseFired: false))
    }

    @Test func droppedSend_doesNotLatch() {
        #expect(!shouldLatchLoaded(connected: true, anySent: false, eoseFired: false))
        #expect(!shouldLatchLoaded(connected: true, anySent: false, eoseFired: true))
    }

    @Test func connectTimeout_doesNotLatch() {
        #expect(!shouldLatchLoaded(connected: false, anySent: false, eoseFired: false))
    }

    @Test func pageBounds_haveNoSinceFloor_andExcludeBoundarySecond() {
        let bounds = pageBoundsBehind(1_000)
        #expect(bounds.since == nil)
        #expect(bounds.until == 999)
    }

    @Test func paging_endsOnlyOnGenuineZeroOlderEvents() {
        #expect(pageEndReached(0))
        #expect(!pageEndReached(1))
        #expect(!pageEndReached(42))
    }

    @Test func cursor_ignoresOlderKeywordOnlyEvent() {
        let seen = [ev("a", createdAt: 3_000), ev("b", createdAt: 1_000), ev("k", createdAt: 500, foodTag: false)]
        #expect(oldestPageableCreatedAt(seen) == 1_000)
    }

    @Test func cursor_isNullWhenNoHashtagReachableEvent() {
        #expect(oldestPageableCreatedAt([ev("k", createdAt: 900, foodTag: false)]) == nil)
        #expect(oldestPageableCreatedAt([NostrEvent]()) == nil)
    }

    @Test func unsettled_rebuildsFromSeen_discardingStaleCache() {
        var ordered = [ev("stale", createdAt: 999)]
        var placed: Set<String> = ["stale"]
        let seen = [
            ev("a", createdAt: 100),
            ev("b", createdAt: 300),
            ev("c", createdAt: 200),
        ]
        let out = mergeFeedOrder(ordered: &ordered, placedIds: &placed, seen: seen, settled: false)
        #expect(out.map(\.id) == ["b", "c", "a"])
        #expect(ordered.map(\.id) == ["b", "c", "a"])
        #expect(placed == ["a", "b", "c"])
    }

    @Test func settled_appendsNewerStragglerAtTail() {
        var ordered = [ev("b", createdAt: 300), ev("c", createdAt: 200), ev("a", createdAt: 100)]
        var placed: Set<String> = ["a", "b", "c"]
        let seen = ordered + [ev("straggler", createdAt: 999)]
        let out = mergeFeedOrder(ordered: &ordered, placedIds: &placed, seen: seen, settled: true)
        #expect(out.map(\.id) == ["b", "c", "a", "straggler"])
    }

    @Test func ingest_dedupsAndHonorsAccept() {
        var seen: [String: NostrEvent] = [:]
        var flushes = 0
        let a = ev("e1", createdAt: 1)
        let blocked = NostrEvent(id: "b1", pubkey: "blocked", kind: 1, createdAt: 2, tags: [], content: "", sig: "")
        #expect(ingestEvent(a, seen: &seen, accept: { $0.pubkey != "blocked" }, onAccepted: { _ in }, signalFlush: { flushes += 1 }))
        #expect(!ingestEvent(a, seen: &seen, accept: { $0.pubkey != "blocked" }, onAccepted: { _ in }, signalFlush: { flushes += 1 }))
        #expect(!ingestEvent(blocked, seen: &seen, accept: { $0.pubkey != "blocked" }, onAccepted: { _ in }, signalFlush: { flushes += 1 }))
        #expect(seen.count == 1)
        #expect(flushes == 1)
    }
}
