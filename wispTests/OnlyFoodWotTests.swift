import Foundation
import Testing
@testable import wisp

/// Unified-feed PR 5 gates (§3.4, §4): the OnlyFood web-of-trust predicate with
/// all four Android guards plus the seed fail-open, the drop counter, the
/// toggle reload, and the four-state truth table. Hermetic: the predicate is
/// pure, the VM takes injected query / filter / gate closures.
@MainActor
struct OnlyFoodWotTests {

    private let me = String(repeating: "a", count: 64)
    private let follow = String(repeating: "b", count: 64)
    private let qualified = String(repeating: "c", count: 64)
    private let seedAuthor = String(repeating: "d", count: 64)
    private let stranger = String(repeating: "e", count: 64)
    private let stranger2 = String(repeating: "f", count: 64)

    private var now: Int { Int(Date().timeIntervalSince1970) }

    private func cache(computedAt: Int, first: [String], qualified: [String]) -> SocialGraphCache {
        SocialGraphCache(
            computedAt: computedAt,
            firstDegreePubkeys: first,
            qualifiedPubkeys: qualified,
            relayUrls: [],
            stats: ComputeStats(followListsFetched: 0, totalFollows: 0, secondDegreeUnique: 0, qualifiedCount: 0, relayCount: 0, durationMs: 0),
            secondDegreeFollowerCount: [:],
            firstDegreeFollowerCount: [:]
        )
    }

    private func snapshot(enabled: Bool, ready: Bool, seedLoaded: Bool = true) -> OnlyFoodWotSnapshot {
        OnlyFoodWotSnapshot(
            enabled: enabled, networkReady: ready, seedLoaded: seedLoaded, currentUser: me,
            network: [follow, qualified], seed: seedLoaded ? [seedAuthor] : []
        )
    }

    // MARK: - Predicate

    @Test func toggleOff_dropsNobody() {
        let s = snapshot(enabled: false, ready: true)
        for pk in [me, follow, qualified, seedAuthor, stranger] {
            #expect(!s.isFiltered(pk), "\(pk.prefix(4)) must pass with the gate off")
        }
    }

    @Test func toggleOn_networkNotReady_dropsNobody() {
        let s = snapshot(enabled: true, ready: false)
        for pk in [me, follow, qualified, seedAuthor, stranger] {
            #expect(!s.isFiltered(pk), "\(pk.prefix(4)) must pass while the network is not ready")
        }
    }

    @Test func toggleOn_networkReady_dropsStranger_keepsSelfNetworkAndSeed() {
        let s = snapshot(enabled: true, ready: true)
        #expect(s.isFiltered(stranger))
        #expect(!s.isFiltered(me))
        #expect(!s.isFiltered(follow))
        #expect(!s.isFiltered(qualified))
        #expect(!s.isFiltered(seedAuthor))
    }

    @Test func toggleOn_seedNotLoaded_failsOpen() {
        let s = snapshot(enabled: true, ready: true, seedLoaded: false)
        #expect(!s.isFiltered(seedAuthor), "a seed author must not be dropped before the seed has loaded")
        #expect(!s.isFiltered(stranger), "nobody is dropped while seed membership is unknown")
        #expect(!s.isFiltered(me))
    }

    // MARK: - Readiness (Android isNetworkReady on SocialGraphCache)

    @Test func networkReady_requiresFreshNonEmptyCache() {
        let follows = [follow]
        #expect(!OnlyFoodWotSnapshot.networkIsReady(nil, currentFollows: follows), "no cache")
        let fresh = cache(computedAt: now - 60, first: [follow], qualified: [qualified])
        #expect(OnlyFoodWotSnapshot.networkIsReady(fresh, currentFollows: follows))
        let stale = cache(computedAt: now - 25 * 3600, first: [follow], qualified: [qualified])
        #expect(!OnlyFoodWotSnapshot.networkIsReady(stale, currentFollows: follows), "older than 24 h")
        let drifted = cache(computedAt: now - 60, first: [follow], qualified: [qualified])
        #expect(!OnlyFoodWotSnapshot.networkIsReady(drifted, currentFollows: [stranger, stranger2, qualified]), "follow list drifted > 10 %")
        let empty = cache(computedAt: now - 60, first: [], qualified: [])
        #expect(!OnlyFoodWotSnapshot.networkIsReady(empty, currentFollows: []), "a computed-but-empty network is not a trust set")
    }

    @Test func make_buildsNetworkFromBothDegrees_andSeedLoadedFromSeed() {
        let c = cache(computedAt: now - 60, first: [follow], qualified: [qualified])
        let loaded = OnlyFoodWotSnapshot.make(enabled: true, cache: c, currentFollows: [follow], currentUser: me, seed: [seedAuthor])
        #expect(loaded.networkReady)
        #expect(loaded.network == [follow, qualified])
        #expect(loaded.seedLoaded)
        #expect(loaded.isFiltered(stranger))
        let unloaded = OnlyFoodWotSnapshot.make(enabled: true, cache: c, currentFollows: [follow], currentUser: me, seed: [])
        #expect(!unloaded.seedLoaded)
        #expect(!unloaded.isFiltered(stranger), "fails open until the seed loads")
    }

    // MARK: - VM: reposts, counter, reload, truth table

    private func note(id: String, author: String, createdAt: Int, tags: [[String]] = [["t", "foodstr"]]) -> NostrEvent {
        NostrEvent(id: id, pubkey: author, kind: 1, createdAt: createdAt, tags: tags, content: "soup", sig: String(repeating: "0", count: 128))
    }

    private func repost(id: String, reposter: String, of inner: NostrEvent, createdAt: Int) -> NostrEvent {
        let obj: [String: Any] = [
            "id": inner.id, "pubkey": inner.pubkey, "kind": inner.kind, "created_at": inner.createdAt,
            "tags": inner.tags, "content": inner.content, "sig": inner.sig,
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        return NostrEvent(
            id: id, pubkey: reposter, kind: 6, createdAt: createdAt,
            tags: [["t", "foodstr"], ["e", inner.id], ["p", inner.pubkey]], content: json,
            sig: String(repeating: "0", count: 128)
        )
    }

    private func poll(id: String, author: String, createdAt: Int) -> NostrEvent {
        NostrEvent(id: id, pubkey: author, kind: Nip88.kindPoll, createdAt: createdAt,
                   tags: [["t", "foodstr"], ["option", "a", "Soup"]], content: "Soup?", sig: String(repeating: "0", count: 128))
    }

    private func filter(filtered: @escaping @Sendable (String) -> Bool) -> OnlyFoodFilter {
        OnlyFoodFilter(
            nowSeconds: { 2_000_000 },
            blockedPubkeys: OnlyFoodFilter.blockedPubkeys,
            isUserBlocked: { _ in false },
            containsMutedWord: { _ in false },
            isThreadMuted: { _ in false },
            isDeleted: { _ in false },
            isWotFiltered: filtered
        )
    }

    private func loaded(_ events: [NostrEvent]) -> OnlyFoodQueryResult {
        OnlyFoodQueryResult(events: events, connected: true, anySent: true, eoseFired: true)
    }

    private func vm(
        wotEnabled: @escaping () -> Bool = { true },
        filtered: @escaping @Sendable (String) -> Bool,
        seedCache: @escaping () async -> [NostrEvent] = { [] },
        query: @escaping (OnlyFoodQueryRequest) async -> OnlyFoodQueryResult
    ) -> OnlyFoodFeedViewModel {
        OnlyFoodFeedViewModel(
            pubkey: me, filter: filter(filtered: filtered), query: query,
            seedCache: seedCache, persist: { _ in }, prepareWot: wotEnabled
        )
    }

    @Test func repost_trustedReposter_ofUntrustedAuthor_isKept() async {
        let strangerNote = note(id: "inner", author: stranger, createdAt: 50)
        let rp = repost(id: "r1", reposter: follow, of: strangerNote, createdAt: 300)
        let s = stranger
        let vm = vm(filtered: { $0 == s }) { _ in self.loaded([rp]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["inner"], "a trusted reposter surfaces a stranger's food note")
        #expect(vm.wotDropped == 0)
    }

    @Test func repost_bothFail_isDropped_andCounted() async {
        let strangerNote = note(id: "inner", author: stranger, createdAt: 50)
        let rp = repost(id: "r1", reposter: stranger2, of: strangerNote, createdAt: 300)
        let bad: Set<String> = [stranger, stranger2]
        let vm = vm(filtered: { bad.contains($0) }) { _ in self.loaded([rp]) }
        await vm.startAndWait()
        #expect(vm.notes.isEmpty)
        #expect(vm.wotDropped == 1)
    }

    @Test func counter_countsKind1_poll_andRepost_branches() async {
        let s = stranger
        let k1 = note(id: "k1", author: stranger, createdAt: 100)
        let p = poll(id: "p1", author: stranger, createdAt: 101)
        let rp = repost(id: "r1", reposter: stranger, of: note(id: "inner", author: stranger, createdAt: 50), createdAt: 102)
        let ok = note(id: "ok", author: follow, createdAt: 103)
        let vm = vm(filtered: { $0 == s }) { _ in self.loaded([k1, p, rp, ok]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["ok"])
        #expect(vm.wotDropped == 3)
    }

    @Test func wotDropped_resetsOnEveryReload() async {
        let s = stranger
        var queries = 0
        let vm = vm(filtered: { $0 == s }) { _ in
            queries += 1
            switch queries {
            case 1: return self.loaded([self.note(id: "s1", author: s, createdAt: 1), self.note(id: "s2", author: s, createdAt: 2)])
            case 2: return self.loaded([])
            default: return self.loaded([self.note(id: "s3", author: s, createdAt: 3)])
            }
        }
        await vm.startAndWait()
        #expect(vm.wotDropped == 2)
        await vm.refreshAndWait()
        #expect(vm.wotDropped == 0, "refresh recounts from zero")
        vm.reloadForWotChange()
        await vm.inFlight?.value
        #expect(vm.wotDropped == 1, "a toggle reload recounts from zero, too")
        #expect(vm.queryCount == 3)
    }

    /// Mutable flag readable from a `@Sendable` predicate.
    private final class Flag: @unchecked Sendable {
        var on = false
    }

    @Test func toggleFlip_reloadsOnce_reFiltersCache_andIsAccounted() async {
        let s = stranger
        let dropStrangers = Flag()
        var queries = 0
        let vm = vm(filtered: { dropStrangers.on && $0 == s }) { _ in
            queries += 1
            return self.loaded([self.note(id: "s1", author: s, createdAt: 1), self.note(id: "f1", author: self.follow, createdAt: 2)])
        }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["f1", "s1"])
        #expect(vm.queryCount == 1)

        dropStrangers.on = true
        NotificationCenter.default.post(name: .onlyFoodWotChanged, object: nil)
        for _ in 0..<100 where vm.queryCount < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await vm.inFlight?.value
        #expect(vm.queryCount == 2, "exactly one accounted REQ, like pull-to-refresh")
        #expect(vm.notes.map(\.id) == ["f1"], "the cached stranger note was re-judged and dropped")
        #expect(vm.wotDropped == 1)
        #expect(vm.hasLoaded)
    }

    @Test func reloadForWotChange_beforeStart_isANoOp() async {
        let vm = vm(filtered: { _ in false }) { _ in self.loaded([]) }
        vm.reloadForWotChange()
        await vm.inFlight?.value
        #expect(vm.queryCount == 0)
    }

    @Test func displayState_truthTable() async {
        let s = stranger
        // WoT removed everything: hidden only while the toggle is on.
        let hidden = vm(filtered: { $0 == s }) { _ in self.loaded([self.note(id: "s1", author: s, createdAt: 1), self.note(id: "s2", author: s, createdAt: 2)]) }
        await hidden.startAndWait()
        #expect(hidden.displayState(wotEnabled: true) == .wotHidden(2))
        #expect(hidden.displayState(wotEnabled: false) == .empty, "stale count with the toggle off is genuine-empty")
        #expect(hidden.isEmpty)
        #expect(!hidden.isLoadFailed)

        // Genuine empty: nothing dropped, nothing accepted.
        let empty = vm(filtered: { _ in false }) { _ in self.loaded([]) }
        await empty.startAndWait()
        #expect(empty.displayState(wotEnabled: true) == .empty)
        #expect(empty.displayState(wotEnabled: false) == .empty)

        // Relay miss wins over both empties, even with drops counted from the cache paint.
        let miss = vm(filtered: { $0 == s }, seedCache: { [self.note(id: "c1", author: s, createdAt: 1)] }) { _ in
            OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: false)
        }
        await miss.startAndWait()
        #expect(miss.wotDropped == 1)
        #expect(miss.displayState(wotEnabled: true) == .relayMiss)
        #expect(miss.displayState(wotEnabled: false) == .relayMiss)

        // Loading, then a list.
        let gate = AsyncStream<Void>.makeStream()
        let pending = vm(filtered: { _ in false }) { _ in
            for await _ in gate.stream { break }
            return self.loaded([self.note(id: "f1", author: self.follow, createdAt: 1)])
        }
        pending.start()
        #expect(pending.displayState(wotEnabled: true) == .loading)
        gate.continuation.yield(())
        await pending.inFlight?.value
        #expect(pending.displayState(wotEnabled: true) == .list)
    }

    @Test func wotEnabled_isCapturedPerLoad() async {
        nonisolated(unsafe) var on = false
        let vm = vm(wotEnabled: { on }, filtered: { _ in false }) { _ in self.loaded([]) }
        await vm.startAndWait()
        #expect(!vm.wotEnabled)
        on = true
        await vm.refreshAndWait()
        #expect(vm.wotEnabled)
    }

    // MARK: - Preference

    /// The flip persists its own key and posts `.onlyFoodWotChanged` — and
    /// nothing else. In particular it must not spawn a
    /// `SafetyFilter.rebuildSnapshot` (Copilot review on #71): that task can
    /// land during a later suite and clobber its installed snapshot, which is
    /// what an earlier draft of this test did to `SafetyTests`. Asserted by
    /// pinning the installed snapshot before the flips and checking it is
    /// still the same object-state afterwards.
    @Test func preference_shipsOff_persistsOwnKey_notifies_andDoesNotRebuildSafetySnapshot() async {
        let pk = (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
        let key = SafetyPreferences.onlyFoodWotKey(pk)
        let previous = SafetyPreferences.shared.activePubkey
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            if let previous { SafetyPreferences.shared.bind(activePubkey: previous) } else { SafetyPreferences.shared.unbind() }
        }
        SafetyPreferences.shared.bind(activePubkey: pk)
        #expect(SafetyPreferences.shared.onlyFoodWotEnabled == false, "ships OFF")
        #expect(key == "onlyfood_wot_enabled_\(pk)")
        #expect(key != SafetyPreferences.wotKey(pk), "separate from the fail-closed global filter")

        // Pin a recognizable snapshot; a stray rebuild would replace it.
        let sentinel = SafetyFilterSnapshot(
            mutedWords: ["sentinel-word"], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: false, qualifiedNetwork: [], userPubkey: pk,
            hellthreadFilterEnabled: false, hellthreadThreshold: NostrEvent.hellthreadThreshold,
            reportedEventIds: [], reportedPubkeys: []
        )
        SafetyFilter.shared.install(sentinel)

        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: .onlyFoodWotChanged, object: nil, queue: .main) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        SafetyPreferences.shared.onlyFoodWotEnabled = true
        #expect(UserDefaults.standard.bool(forKey: key) == true, "own key written")
        SafetyPreferences.shared.onlyFoodWotEnabled = true   // no change → no post
        SafetyPreferences.shared.onlyFoodWotEnabled = false
        for _ in 0..<20 where posts < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(posts == 2)

        // Give any (wrongly) scheduled rebuild every chance to land, then check
        // the sentinel survived.
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(SafetyFilter.shared.snapshot.mutedWords == ["sentinel-word"], "no SafetyFilter rebuild was scheduled by the flip")
    }
}
