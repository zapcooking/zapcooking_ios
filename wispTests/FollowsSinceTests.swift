import Foundation
import Testing
@testable import wisp

/// Issue #188: the Follows feed's `since` must come from what Follows itself
/// has synced, not from the newest note any feature happened to store.
///
/// The three view-model tests drive the real `FeedViewModel` down both load
/// paths and read the `since` on the REQ it would send, through the
/// `openFollowsSubscription` seam. They put one far-future note in the
/// hosted app's `EventStore` (what OnlyFood does on the default landing)
/// under throwaway keys, and remove it again.
@Suite(.serialized) @MainActor struct FollowsSinceTests {

    // MARK: - Pure decision

    @Test func window_shrinksAsTheFollowListGrows() {
        let day = 24 * 3600
        #expect(FollowsSince.window(followCount: 0) == 7 * day)
        #expect(FollowsSince.window(followCount: 10) == 7 * day)
        #expect(FollowsSince.window(followCount: 11) == 5 * day)
        #expect(FollowsSince.window(followCount: 30) == 5 * day)
        #expect(FollowsSince.window(followCount: 75) == 3 * day)
        #expect(FollowsSince.window(followCount: 150) == 2 * day)
        #expect(FollowsSince.window(followCount: 300) == 36 * 3600)
        #expect(FollowsSince.window(followCount: 301) == day)
    }

    @Test func coldStart_fromTheAnchorWithOverlap_neverPastTheWindow() {
        let now = 2_000_000_000
        let window = FollowsSince.window(followCount: 50)
        #expect(FollowsSince.coldStart(anchor: nil, followCount: 50, now: now) == now - window)
        #expect(FollowsSince.coldStart(anchor: 0, followCount: 50, now: now) == now - window)
        #expect(FollowsSince.coldStart(anchor: now - 3600, followCount: 50, now: now) == now - 3600 - 300)
        // An anchor older than the window: the window wins.
        #expect(FollowsSince.coldStart(anchor: now - 30 * 24 * 3600, followCount: 50, now: now) == now - window)
    }

    @Test func refresh_withNotesInTheList_startsFromTheNewestOfThem() {
        let now = 2_000_000_000
        #expect(FollowsSince.refresh(listNewest: now - 500, anchor: now - 10, followCount: 50, now: now) == now - 560)
    }

    // MARK: - Through the view model

    /// Every REQ a load would have sent.
    @MainActor private final class Captured {
        private(set) var loads: [[RelayQuery]] = []
        private(set) var observers: [RelayBacklogObserver?] = []
        func record(_ queries: [RelayQuery], observer: RelayBacklogObserver?) {
            loads.append(queries)
            observers.append(observer)
        }
        /// The `since` values of the most recent load's filters.
        var latestSinces: [Int?] { loads.last?.flatMap { $0.filters.map(\.since) } ?? [] }
    }

    private func hex32() -> String {
        (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }

    /// An account with one follow, routed to one relay, and nothing from
    /// that follow in the store.
    private struct Account {
        let me: String
        let follow: String
        let keypair: Keypair
    }

    private func makeAccount(follow: String? = nil) -> Account {
        let me = hex32(), follow = follow ?? hex32()
        FollowsCache.shared.update(pubkey: me, follows: [follow], createdAt: 1)
        let board = RelayScoreBoard()
        board.build(follows: [follow], writeRelaysByAuthor: [follow: ["wss://relay.example.com"]])
        board.save(pubkey: me)
        return Account(me: me, follow: follow,
                       keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: me))
    }

    private func tearDown(_ account: Account, stranger: String) async {
        _ = await EventStore.shared.removeByAuthor(stranger)
        let defaults = UserDefaults.standard
        for key in ["follow_pubkeys_", "follow_pubkeys_ts_", "relay_scoreboard_v1_"] {
            defaults.removeObject(forKey: key + account.me)
        }
        defaults.removeObject(forKey: FeedKindStore.typeKey(account.me))
        FollowsCache.shared.invalidate(pubkey: account.me)
    }

    private func makeVM(_ account: Account, captured: Captured) -> FeedViewModel {
        let services = FeedViewModel.StartupServices(
            startLiveDiscovery: { _ in },
            registerSweepSource: { _ in UUID() },
            unregisterSweepSource: { _ in },
            bootstrapRelaySets: { _ in },
            pruneEventStore: { _ in },
            queryIndexers: { _ in [] },
            openFollowsSubscription: { queries, id, observer in
                captured.record(queries, observer: observer)
                return RelaySubscription(id: id)
            }
        )
        return FeedViewModel(keypair: account.keypair, services: services)
    }

    /// A note dated five years ahead, so it is the newest in the store
    /// whatever other tests left there: what another feed persisted while
    /// Follows was not syncing. Returns its author.
    private func persistNote(by privkey: Data? = nil) async throws -> String {
        let priv = privkey ?? Schnorr.randomPrivkey()
        let author = Hex.encode(try Schnorr.xonlyPubkey(privkey32: priv))
        let note = try NostrEvent.sign(privkey32: priv, pubkey: author, kind: 1,
                                       createdAt: Int(Date().timeIntervalSince1970) + 5 * 365 * 86400,
                                       tags: [["t", "foodstr"]], content: "a food note, stored by OnlyFood")
        await EventStore.shared.persist([note])
        return author
    }

    private func eventually(_ done: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    /// With nothing synced by Follows, a load must reach back the whole
    /// default window, whatever else is in the store.
    private func expectDefaultWindow(_ captured: Captured, followCount: Int) {
        let expected = Int(Date().timeIntervalSince1970) - FollowsSince.window(followCount: followCount)
        let sinces = captured.latestSinces
        #expect(!sinces.isEmpty, "no REQ captured")
        for since in sinces {
            let value = since ?? Int.max
            #expect(abs(value - expected) <= 30,
                    "since \(value) is \(value - expected)s after the default window's start; follows' notes before it are never requested")
        }
    }

    /// The picker path: land on OnlyFood (the default), which stores
    /// strangers' notes, then pick Follows with no follow notes cached.
    /// `selectFollows` → `reseedFollowsFeed` → `refresh()`.
    @Test func pickingFollowsAfterOnlyFood_asksForTheWholeDefaultWindow() async throws {
        try #require(ObjectBoxSetup.store != nil, "hosted store not set up")
        let account = makeAccount()
        let stranger = try await persistNote()
        let captured = Captured()
        let vm = makeVM(account, captured: captured)
        #expect(vm.currentKind == .onlyFood)

        await vm.start()
        #expect(captured.loads.isEmpty, "an OnlyFood landing opens no Follows subscription")
        vm.selectFollows()
        #expect(await eventually { !captured.loads.isEmpty })

        expectDefaultWindow(captured, followCount: 1)
        vm.stop()
        await tearDown(account, stranger: stranger)
    }

    /// The picker path when a follow's note IS cached, but another feed put
    /// it there (a follow's food post seen in OnlyFood). It seeds the list,
    /// and the list's newest note must not stand in for "synced to here".
    @Test func pickingFollows_withAFollowsNoteCachedByAnotherFeed_asksForTheWholeDefaultWindow() async throws {
        try #require(ObjectBoxSetup.store != nil, "hosted store not set up")
        let followPriv = Schnorr.randomPrivkey()
        let follow = try await persistNote(by: followPriv)
        let account = makeAccount(follow: follow)
        let captured = Captured()
        let vm = makeVM(account, captured: captured)

        await vm.start()
        vm.selectFollows()
        #expect(await eventually { !captured.loads.isEmpty })
        #expect(vm.events.contains { $0.pubkey == follow }, "the cached note seeds the list")

        expectDefaultWindow(captured, followCount: 1)
        vm.stop()
        await tearDown(account, stranger: follow)
    }

    /// The cold-start path: the app launches on Follows after a session
    /// spent on another feed.
    @Test func coldStartOnFollows_afterAnotherFeedStoredNotes_asksForTheWholeDefaultWindow() async throws {
        try #require(ObjectBoxSetup.store != nil, "hosted store not set up")
        let account = makeAccount()
        FeedKindStore.persist(.follows, pubkey: account.me)
        let stranger = try await persistNote()
        let captured = Captured()
        let vm = makeVM(account, captured: captured)
        #expect(vm.currentKind == .follows)

        await vm.start()
        #expect(await eventually { !captured.loads.isEmpty })

        expectDefaultWindow(captured, followCount: 1)
        vm.stop()
        await tearDown(account, stranger: stranger)
    }
}
