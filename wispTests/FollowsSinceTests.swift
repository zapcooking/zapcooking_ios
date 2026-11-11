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
        /// Pubkeys the view model asked to fetch profiles for: the seam
        /// keeps these off the production indexers.
        var profileFetches: [[String]] = []
        /// The subscriptions handed back, so a test can push events down
        /// the stream the view model consumes.
        private(set) var subscriptions: [RelaySubscription] = []
        func record(_ queries: [RelayQuery], observer: RelayBacklogObserver?) {
            loads.append(queries)
            observers.append(observer)
        }
        func opened(_ sub: RelaySubscription) -> RelaySubscription {
            subscriptions.append(sub)
            return sub
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
                return captured.opened(RelaySubscription(id: id))
            },
            ensureProfiles: { pks in
                captured.profileFetches.append(pks)
                return [:]
            },
            observeMissingProfiles: { _ in }
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
        #expect(await eventually { captured.profileFetches.contains { $0.contains(follow) } },
                "the uncached author's profile goes through the injected fetch, not the indexers")

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

    // MARK: - The fix: Follows' own cursor

    private func scratchDefaults() -> UserDefaults {
        let name = "FollowsSinceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func note(at createdAt: Int, by pubkey: String = String(repeating: "a", count: 64)) -> NostrEvent {
        NostrEvent(id: UUID().uuidString, pubkey: pubkey, kind: 1, createdAt: createdAt,
                   tags: [], content: "", sig: "")
    }

    @Test func refresh_emptyList_loadsLikeAColdStart() {
        let now = 2_000_000_000
        let window = FollowsSince.window(followCount: 50)
        #expect(FollowsSince.refresh(listNewest: nil, anchor: nil, followCount: 50, now: now) == now - window)
        #expect(FollowsSince.refresh(listNewest: nil, anchor: now - 3600, followCount: 50, now: now) == now - 3600 - 300)
    }

    /// The list's newest note may have been stored by another feed: when it
    /// is newer than the sync point, the sync point decides.
    @Test func refresh_listNewerThanTheSyncPoint_startsFromTheSyncPoint() {
        let now = 2_000_000_000
        let window = FollowsSince.window(followCount: 50)
        #expect(FollowsSince.refresh(listNewest: now - 10, anchor: now - 7200, followCount: 50, now: now) == now - 7200 - 300)
        #expect(FollowsSince.refresh(listNewest: now - 10, anchor: nil, followCount: 50, now: now) == now - window)
    }

    @Test func cursor_absentUntilRecorded_thenRoundTrips() {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil)
        FollowsSyncCursor.record(now - 500, pubkey: pk, now: now, defaults: defaults)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now - 500)
        #expect(FollowsSyncCursor.load(pubkey: hex32(), now: now, defaults: defaults) == nil, "per account")
        FollowsSyncCursor.clear(pubkey: pk, defaults: defaults)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil)
    }

    /// Rider 1: a future-dated note cannot push `since` into the future,
    /// whether it arrives now or was stored by an earlier run.
    @Test func cursor_futureDatedNote_cannotPushSinceIntoTheFuture() {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let skew = OnlyFoodFilter.futureSkewSeconds

        FollowsSyncCursor.record(now + 10 * 365 * 86400, pubkey: pk, now: now, defaults: defaults)
        #expect(defaults.integer(forKey: FollowsSyncCursor.key(pk)) == now + skew, "clamped when written")
        let anchor = FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults)
        #expect(anchor == now + skew)
        #expect(FollowsSince.coldStart(anchor: anchor, followCount: 50, now: now) <= now)
        #expect(FollowsSince.refresh(listNewest: nil, anchor: anchor, followCount: 50, now: now) <= now)

        // A raw future value already on disk is clamped when read.
        defaults.set(now + 999_999, forKey: FollowsSyncCursor.key(pk))
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now + skew)

        // And a clamped cursor does not stay ahead once the clock is read
        // again later: it is at most `skew` past the time it was written.
        #expect(FollowsSyncCursor.clamped(now + 999_999, now: now + 3600) == now + 3600 + skew)
    }

    @Test func cursor_neverMovesBack() {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        FollowsSyncCursor.record(now - 100, pubkey: pk, now: now, defaults: defaults)
        FollowsSyncCursor.record(now - 5000, pubkey: pk, now: now, defaults: defaults)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now - 100)
    }

    /// Rider 2: nothing is persisted per event. A load that is killed
    /// before its slowest relay answers leaves the cursor untouched.
    @Test func settle_recordsOnlyWhenEveryAskedRelayHasAnswered() {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let fast = "wss://fast.example.com", slow = "wss://slow.example.com"
        let settle = FollowsLoadSettle(pubkey: pk, askedRelays: [fast, slow], now: { now }, defaults: defaults)

        settle.delivered(note(at: now - 100), from: fast)
        settle.answered(relayUrl: fast, streamCount: 0)
        settle.answered(relayUrl: fast, streamCount: 0)                       // a reconnect's second EOSE
        settle.answered(relayUrl: "wss://unasked.example.com", streamCount: 0)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil,
                "the slow relay has not answered: a kill here must not skip what it holds")

        settle.delivered(note(at: now - 4000), from: slow)
        settle.answered(relayUrl: slow, streamCount: 0)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now - 100)

        // Settled once: later live deliveries do not move it.
        settle.delivered(note(at: now - 1), from: fast)
        settle.answered(relayUrl: fast, streamCount: 0)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now - 100)
    }

    @Test func settle_withNothingDelivered_orNothingAsked_recordsNothing() {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let quiet = FollowsLoadSettle(pubkey: pk, askedRelays: ["wss://a.example.com"], now: { now }, defaults: defaults)
        quiet.answered(relayUrl: "wss://a.example.com", streamCount: 0)
        let nobody = FollowsLoadSettle(pubkey: pk, askedRelays: [], now: { now }, defaults: defaults)
        nobody.delivered(note(at: now - 5), from: "wss://a.example.com")
        nobody.answered(relayUrl: "wss://a.example.com", streamCount: 0)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil)
    }

    @Test func settle_clampsAFutureDatedDelivery() {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let settle = FollowsLoadSettle(pubkey: pk, askedRelays: ["wss://a.example.com"], now: { now }, defaults: defaults)
        settle.delivered(note(at: now + 86400), from: "wss://a.example.com")
        settle.answered(relayUrl: "wss://a.example.com", streamCount: 0)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now + OnlyFoodFilter.futureSkewSeconds)
    }

    /// Rider 3: a changed follow list clears the cursor, and a load that
    /// was already running for the old list cannot put it back.
    @Test func followListChange_clearsTheCursor_andStaleLoadsCannotRestoreIt() {
        let pk = hex32(), a = hex32(), b = hex32(), now = Int(Date().timeIntervalSince1970)
        defer {
            for key in ["follow_pubkeys_", "follow_pubkeys_ts_"] { UserDefaults.standard.removeObject(forKey: key + pk) }
            FollowsSyncCursor.clear(pubkey: pk)
            FollowsCache.shared.invalidate(pubkey: pk)
        }
        FollowsCache.shared.update(pubkey: pk, follows: [a], createdAt: 10)
        FollowsSyncCursor.record(now - 500, pubkey: pk, now: now)

        // The same set again (a re-publish) keeps it.
        FollowsCache.shared.update(pubkey: pk, follows: [a], createdAt: 10)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now) == now - 500)

        // A load opens for [a]; then the list changes.
        let stale = FollowsLoadSettle(pubkey: pk, askedRelays: ["wss://a.example.com"])
        FollowsCache.shared.update(pubkey: pk, follows: [a, b], createdAt: 11)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now) == nil, "next load uses the default window")

        stale.delivered(note(at: now - 60), from: "wss://a.example.com")
        stale.answered(relayUrl: "wss://a.example.com", streamCount: 0)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now) == nil)

        // Unfollowing clears it too.
        FollowsSyncCursor.record(now - 500, pubkey: pk, now: now)
        FollowsCache.shared.update(pubkey: pk, follows: [b], createdAt: 12)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now) == nil)
    }

    // MARK: - Review fixes (#194)

    nonisolated final class PersistGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [[NostrEvent]] = []
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        var batches: [[NostrEvent]] { lock.lock(); defer { lock.unlock() }; return _batches }
        /// Persistence that does not finish until `open()`.
        func persist(_ batch: [NostrEvent]) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                _batches.append(batch)
                if opened { lock.unlock(); c.resume() } else { waiter = c; lock.unlock() }
            }
        }
        func open() {
            lock.lock(); opened = true; let w = waiter; waiter = nil; lock.unlock()
            w?.resume()
        }
    }

    /// A load settles while two backlog notes are still on the stream: the
    /// cursor waits for the consumer to take both, then for the accepted
    /// one to be written, and only then moves.
    @Test func settle_commitsOnlyAfterTheBacklogIsConsumedAndPersisted() async {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let relay = "wss://a.example.com", gate = PersistGate()
        let settle = FollowsLoadSettle(pubkey: pk, askedRelays: [relay], now: { now }, defaults: defaults,
                                       persist: { await gate.persist($0) })
        let kept = note(at: now - 100), dropped = note(at: now - 200)
        settle.delivered(kept, from: relay)
        settle.delivered(dropped, from: relay)
        settle.answered(relayUrl: relay, streamCount: 2)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil,
                "settled, but the consumer has not taken the backlog: a feed switch now would discard it")

        settle.consumed(kept, accepted: true)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil)
        settle.consumed(dropped, accepted: false)
        #expect(await eventually { gate.batches.count == 1 })
        #expect(gate.batches.first?.map(\.id) == [kept.id], "only what the feed accepted is written")
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil,
                "persistence has not finished")

        gate.open()
        #expect(await eventually { FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now - 100 })
        // Live notes after the barrier are not part of the load.
        settle.consumed(note(at: now - 1), accepted: true)
        #expect(gate.batches.count == 1)
    }

    /// The consumer may be ahead of the socket's answer: everything was
    /// consumed before the last relay's EOSE.
    @Test func settle_consumerAlreadyCaughtUp_commitsAtSettle() async {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let relay = "wss://a.example.com"
        let settle = FollowsLoadSettle(pubkey: pk, askedRelays: [relay], now: { now }, defaults: defaults,
                                       persist: { _ in })
        let n = note(at: now - 300)
        settle.delivered(n, from: relay)
        settle.consumed(n, accepted: true)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil, "not settled")
        settle.answered(relayUrl: relay, streamCount: 1)
        #expect(await eventually { FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now - 300 })
    }

    /// A load that ended (feed switched, replaced, stopped) cannot settle or
    /// commit from a late EOSE: its unflushed notes were discarded.
    @Test func endedLoad_ignoresLateAnswers_andUncommittedBacklog() async {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let relay = "wss://a.example.com"
        let early = FollowsLoadSettle(pubkey: pk, askedRelays: [relay], now: { now }, defaults: defaults)
        early.delivered(note(at: now - 100), from: relay)
        early.end()
        early.answered(relayUrl: relay, streamCount: 0)
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil, "ended before its EOSE")

        let mid = FollowsLoadSettle(pubkey: pk, askedRelays: [relay], now: { now }, defaults: defaults,
                                    persist: { _ in })
        let n = note(at: now - 100)
        mid.delivered(n, from: relay)
        mid.answered(relayUrl: relay, streamCount: 1)
        mid.end()                              // switched away before the consumer took it
        mid.consumed(n, accepted: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil, "ended before commit")
    }

    /// A relay that refuses the REQ delivered nothing. A transient refusal
    /// keeps the load unsettled (its notes may come next time); a final one
    /// counts as an answer, since asking again gets the same refusal.
    @Test func rejectedRequest_settlesOnlyOnAFinalRefusal() {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let good = "wss://good.example.com", bad = "wss://bad.example.com"
        for reason in ["rate-limited: slow down", "error: internal", "", "shutting down"] {
            let settle = FollowsLoadSettle(pubkey: pk, askedRelays: [good, bad], now: { now }, defaults: defaults)
            settle.delivered(note(at: now - 100), from: good)
            settle.answered(relayUrl: good, streamCount: 0)
            settle.rejected(relayUrl: bad, reason: reason, streamCount: 0)
            #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil,
                    "'\(reason)' must not let the good relay's note advance past what bad holds")
        }
        for reason in ["blocked: not on the allow list", "restricted: paid relay", "INVALID: too many filters"] {
            FollowsSyncCursor.clear(pubkey: pk, defaults: defaults)
            let settle = FollowsLoadSettle(pubkey: pk, askedRelays: [good, bad], now: { now }, defaults: defaults)
            settle.delivered(note(at: now - 100), from: good)
            settle.answered(relayUrl: good, streamCount: 0)
            settle.rejected(relayUrl: bad, reason: reason, streamCount: 0)
            #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == now - 100, "'\(reason)'")
        }
    }

    @Test func settle_holdingTooMuchBacklog_givesUpOnTheCursor() async {
        let defaults = scratchDefaults(), pk = hex32(), now = 2_000_000_000
        let relay = "wss://a.example.com"
        let settle = FollowsLoadSettle(pubkey: pk, askedRelays: [relay], now: { now }, defaults: defaults,
                                       persist: { _ in })
        let count = FollowsLoadSettle.maxHeldEvents + 1
        for i in 0..<count {
            let n = note(at: now - 1000 + i % 500)
            settle.delivered(n, from: relay)
            settle.consumed(n, accepted: true)
        }
        settle.answered(relayUrl: relay, streamCount: count)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(FollowsSyncCursor.load(pubkey: pk, now: now, defaults: defaults) == nil)
    }

    /// The stamp check and the cursor write happen under the follow cache's
    /// lock: once `update` has replaced the list, a write for the old
    /// stamp does not run.
    @Test func ifFollowListUnchanged_runsOnlyForTheCurrentList() {
        let pk = hex32()
        defer {
            for key in ["follow_pubkeys_", "follow_pubkeys_ts_"] { UserDefaults.standard.removeObject(forKey: key + pk) }
            FollowsCache.shared.invalidate(pubkey: pk)
        }
        FollowsCache.shared.update(pubkey: pk, follows: [hex32()], createdAt: 20)
        #expect(FollowsCache.shared.ifFollowListUnchanged(pubkey: pk, stamp: 20) {})
        FollowsCache.shared.update(pubkey: pk, follows: [hex32()], createdAt: 21)
        var ran = false
        #expect(!FollowsCache.shared.ifFollowListUnchanged(pubkey: pk, stamp: 20) { ran = true })
        #expect(!ran)
        FollowsCache.shared.invalidate(pubkey: pk)   // cold cache reads the stored stamp
        #expect(FollowsCache.shared.ifFollowListUnchanged(pubkey: pk, stamp: 21) {})
    }

    /// `RelaySubscription` counts exactly what it yields: duplicates and
    /// post-cancel deliveries are not stream elements.
    @Test func subscription_yieldedCount_countsStreamElements() {
        let sub = RelaySubscription(id: "count-test")
        let a = note(at: 1), b = note(at: 2)
        sub.deliver(event: a, relayUrl: "wss://x.example.com")
        sub.deliver(event: a, relayUrl: "wss://y.example.com")
        sub.deliver(event: b, relayUrl: "wss://x.example.com")
        #expect(sub.yieldedCount == 2)
        sub.cancel()
        sub.deliver(event: note(at: 3), relayUrl: "wss://x.example.com")
        #expect(sub.yieldedCount == 2)
    }

    /// End to end through the view model: a settled load records the
    /// cursor, and the next cold start resumes from it with the overlap.
    @Test func settledLoad_recordsTheCursor_andTheNextColdStartResumesFromIt() async throws {
        let account = makeAccount()
        FeedKindStore.persist(.follows, pubkey: account.me)
        defer { FollowsSyncCursor.clear(pubkey: account.me) }
        let now = Int(Date().timeIntervalSince1970)

        let first = Captured()
        let vm = makeVM(account, captured: first)
        await vm.start()
        #expect(await eventually { !first.loads.isEmpty })
        let observer = try #require(first.observers.first ?? nil, "loadFeed passes its settle observer")
        let relay = try #require(RelayPool.wsURL(first.loads[0][0].relayUrl)?.absoluteString)

        let sub = try #require(first.subscriptions.first)

        // What the pool's sink does: observe, yield, then EOSE with the
        // stream position. The view model's consumer takes it from there.
        let backlog = note(at: now - 1000, by: account.follow)
        observer.delivered(backlog, from: relay)
        sub.deliver(event: backlog, relayUrl: relay)
        #expect(FollowsSyncCursor.load(pubkey: account.me, now: now) == nil, "not per event")
        observer.answered(relayUrl: relay, streamCount: sub.yieldedCount)
        #expect(await eventually { FollowsSyncCursor.load(pubkey: account.me, now: now) == now - 1000 },
                "consumed, persisted, then recorded")
        #expect(!(await EventStore.shared.eventsByIds([backlog.id])).isEmpty, "on disk before the cursor moved")
        vm.stop()

        let second = Captured()
        let relaunched = makeVM(account, captured: second)
        await relaunched.start()
        #expect(await eventually { !second.loads.isEmpty })
        #expect(second.latestSinces == [now - 1000 - FollowsSince.overlapSeconds])
        relaunched.stop()

        await tearDown(account, stranger: account.follow)
    }
}
