import Foundation
import Testing
@testable import wisp

/// Port of web `src/lib/freshFeed/lastVisit.test.ts`, one case for one. Web's
/// module-level session mark is a `FreshLastVisit` instance here (a new one
/// per test stands in for `resetVisitForTests`), keyed per account.
@MainActor
struct FreshLastVisitTests {
    nonisolated final class Store: FreshVisitStorage, @unchecked Sendable {
        var data: [String: String] = [:]
        func freshVisitValue(forKey key: String) throws -> String? { data[key] }
        func setFreshVisitValue(_ value: String, forKey key: String) throws { data[key] = value }
    }

    nonisolated struct Failing: FreshVisitStorage {
        struct Denied: Error {}
        func freshVisitValue(forKey key: String) throws -> String? { throw Denied() }
        func setFreshVisitValue(_ value: String, forKey key: String) throws { throw Denied() }
    }

    /// Thread-safe, with a pause between a read and the caller's write so
    /// an unlocked read-compare-write in `recordNewest` loses updates.
    nonisolated final class SlowStore: FreshVisitStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var data: [String: String] = [:]
        func freshVisitValue(forKey key: String) throws -> String? {
            lock.lock(); let v = data[key]; lock.unlock()
            usleep(200)
            return v
        }
        func setFreshVisitValue(_ value: String, forKey key: String) throws {
            lock.lock(); data[key] = value; lock.unlock()
        }
    }

    static let pk = String(repeating: "a", count: 64)
    static var key: String { FreshLastVisit.key(pubkey: pk) }

    // MARK: the visit mark

    @Test func isNilOnAFirstVisit() {
        #expect(FreshLastVisit().beginVisit(pubkey: Self.pk, storage: Store()) == nil)
    }

    @Test func readsThePreviousVisitOnce_andKeepsItForTheSession() {
        let s = Store()
        s.data[Self.key] = "1000"
        let visit = FreshLastVisit()
        #expect(visit.beginVisit(pubkey: Self.pk, storage: s) == 1000)
        visit.recordNewest(2000, pubkey: Self.pk, storage: s)
        // A refresh in the same session keeps the divider where it was.
        #expect(visit.beginVisit(pubkey: Self.pk, storage: s) == 1000)
        visit.resetSession()
        #expect(visit.beginVisit(pubkey: Self.pk, storage: s) == 2000)
    }

    @Test func neverMovesTheStoredMarkBack() {
        let s = Store()
        let visit = FreshLastVisit()
        visit.recordNewest(2000, pubkey: Self.pk, storage: s)
        visit.recordNewest(1500, pubkey: Self.pk, storage: s)
        #expect(s.data[Self.key] == "2000")
    }

    @Test func ignoresGarbageAndFailingStorage() {
        let s = Store()
        s.data[Self.key] = "soon"
        #expect(FreshLastVisit().beginVisit(pubkey: Self.pk, storage: s) == nil)
        #expect(FreshLastVisit().beginVisit(pubkey: Self.pk, storage: nil) == nil)
        let visit = FreshLastVisit()
        #expect(visit.beginVisit(pubkey: Self.pk, storage: Failing()) == nil)
        visit.recordNewest(5, pubkey: Self.pk, storage: Failing()) // does not throw
    }

    // MARK: review fixes (PR #201)

    @Test func concurrentRecords_leaveTheNewestStored() throws {
        let s = SlowStore()
        let visit = FreshLastVisit()
        let times = Array(1...200).shuffled()
        DispatchQueue.concurrentPerform(iterations: times.count) { i in
            visit.recordNewest(times[i], pubkey: Self.pk, storage: s)
        }
        #expect(try s.freshVisitValue(forKey: Self.key) == "200")
    }

    @Test func outOfRangeStoredMark_readsAsNoMark_andIsReplaced() {
        for raw in ["1e100", "9.3e18", "\(Double.greatestFiniteMagnitude)"] {
            let s = Store()
            s.data[Self.key] = raw
            #expect(FreshLastVisit().beginVisit(pubkey: Self.pk, storage: s) == nil, "\(raw)")
            FreshLastVisit().recordNewest(1000, pubkey: Self.pk, storage: s)
            #expect(s.data[Self.key] == "1000", "\(raw)")
        }
    }

    @Test func specialCardsAboveTheFirstSeenPost_withNothingNew_placeNoDivider() {
        let rows = [Self.row("r", 10, box: true), Self.row("c", 100), Self.row("d", 50)]
        #expect(Self.keys(FreshDivider.withDivider(rows, mark: 200)) == ["box:r", "c", "d"])
    }

    // MARK: withDivider

    nonisolated struct Row: FreshDividable, Equatable {
        let key: String
        let createdAt: Int
        let box: Bool
        var isSpecialCard: Bool { box }
        var dividerCreatedAt: Int { createdAt }
    }

    static func row(_ id: String, _ t: Int, box: Bool = false) -> Row {
        Row(key: box ? "box:\(id)" : id, createdAt: t, box: box)
    }

    static func keys(_ rows: [FreshDividedRow<Row>]) -> [String] {
        rows.map {
            switch $0 {
            case .row(let r): return r.key
            case .divider: return "divider"
            }
        }
    }

    static let rows = [row("a", 300), row("b", 250), row("r", 10, box: true), row("c", 200), row("d", 100)]

    @Test func goesBeforeTheFirstPostAlreadySeen_countingNewPostsNotPicks() {
        let out = FreshDivider.withDivider(Self.rows, mark: 200)
        #expect(Self.keys(out) == ["a", "b", "box:r", "divider", "c", "d"])
        guard case .divider(let n) = out[3] else {
            Issue.record("no divider at 3")
            return
        }
        #expect(n == 2)
    }

    @Test func noneOnAFirstVisit_whenAllIsNew_orWhenNothingIs() {
        #expect(Self.keys(FreshDivider.withDivider(Self.rows, mark: nil)) == Self.rows.map(\.key))
        #expect(!FreshDivider.withDivider(Self.rows, mark: 50).contains { $0.isDivider })
        #expect(!FreshDivider.withDivider(Self.rows, mark: 999).contains { $0.isDivider })
    }

    @Test func aRecipeRowPickNeverPlacesTheDivider() {
        let picksFirst = [Self.row("r", 10, box: true), Self.row("a", 300), Self.row("c", 100)]
        #expect(Self.keys(FreshDivider.withDivider(picksFirst, mark: 200)) == ["box:r", "a", "divider", "c"])
    }

    // MARK: iOS-only

    @Test func eachAccountHasItsOwnMark() {
        let s = Store()
        let other = String(repeating: "b", count: 64)
        let visit = FreshLastVisit()
        visit.recordNewest(1000, pubkey: Self.pk, storage: s)
        #expect(visit.beginVisit(pubkey: other, storage: s) == nil)
        #expect(visit.beginVisit(pubkey: Self.pk, storage: s) == 1000)
    }

    @Test func userDefaultsIsTheDeviceStore() throws {
        let suite = "FreshLastVisitTests-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        FreshLastVisit().recordNewest(1234, pubkey: Self.pk, storage: d)
        #expect(d.string(forKey: Self.key) == "1234")
        #expect(FreshLastVisit().beginVisit(pubkey: Self.pk, storage: d) == 1234)
    }
}
