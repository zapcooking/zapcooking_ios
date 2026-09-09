import Foundation
import Testing
@testable import wisp

/// Gate for Concern 3.3 — one-shot cache (§7.4), mute-only ingest, and the
/// three derived states. Single-mode since unified-feed PR 3 dropped
/// Following. Hermetic: every VM is constructed with an injected query, so a
/// cache miss cannot open a socket.
@MainActor
struct OnlyFoodFeedViewModelTests {

    private let pubkey = String(repeating: "a", count: 64)
    private let follow = String(repeating: "b", count: 64)

    private func food(
        id: String,
        author: String? = nil,
        createdAt: Int,
        content: String = "yummy",
        extraTags: [[String]] = []
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: author ?? follow,
            kind: 1,
            createdAt: createdAt,
            tags: [["t", "foodstr"]] + extraTags,
            content: content,
            sig: String(repeating: "0", count: 128)
        )
    }

    private func muteOnlyFilter(
        blocked: Set<String> = [],
        mutedWords: Set<String> = []
    ) -> OnlyFoodFilter {
        OnlyFoodFilter(
            nowSeconds: { 2_000_000 },
            blockedPubkeys: OnlyFoodFilter.blockedPubkeys,
            isUserBlocked: { blocked.contains($0) },
            containsMutedWord: { content in
                let lower = content.lowercased()
                return mutedWords.contains { lower.contains($0) }
            },
            isThreadMuted: { _ in false },
            isDeleted: { _ in false },
            isWotFiltered: { _ in false }
        )
    }

    private func result(_ events: [NostrEvent]) -> OnlyFoodQueryResult {
        OnlyFoodQueryResult(events: events, connected: true, anySent: true, eoseFired: true)
    }

    @Test func start_isOneShot() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                calls += 1
                return self.result([self.food(id: "aa", createdAt: 100)])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(calls == 1)
        vm.start()
        #expect(calls == 1)
        #expect(vm.queryCount == 1)
    }

    /// §7.4 in single-mode form: the feed tab calls `start()` on appear and on
    /// every feed-kind change; after the first load every later call is a
    /// no-op and the cached list stays on screen.
    @Test func repeatedStart_afterLoad_keepsCacheAndIssuesNoREQ() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                calls += 1
                return self.result([self.food(id: "g1", createdAt: 200)])
            },
            seedCache: { [] },
            persist: { _ in }
        )

        await vm.startAndWait()
        #expect(calls == 1)
        #expect(vm.notes.map(\.id) == ["g1"])
        #expect(vm.hasLoaded)

        vm.start()
        vm.start()
        await vm.inFlight?.value
        #expect(calls == 1)
        #expect(vm.queryCount == 1)
        #expect(vm.notes.map(\.id) == ["g1"])
        #expect(!vm.isLoading)
    }

    @Test func zeroEvents_stillLatches_soSecondStartDoesNotRequery() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                calls += 1
                return self.result([])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(calls == 1)
        #expect(vm.hasLoaded)
        #expect(vm.isEmpty)
        #expect(!vm.isLoadFailed)
        #expect(!vm.isAwaitingFirstPaint)

        vm.start()
        await vm.inFlight?.value
        #expect(calls == 1)
        #expect(vm.queryCount == 1)
    }

    @Test func timeout_doesNotLatch() async {
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: false)
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(!vm.hasLoaded)
        #expect(!vm.isLoading)
        #expect(vm.isLoadFailed)
        #expect(!vm.isEmpty)
        #expect(!vm.isAwaitingFirstPaint)
    }

    @Test func connectMiss_isLoadFailedNotEmpty() async {
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                OnlyFoodQueryResult(events: [], connected: false, anySent: false, eoseFired: false)
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(!vm.hasLoaded)
        #expect(vm.isLoadFailed)
        #expect(!vm.isEmpty)
        #expect(!vm.isAwaitingFirstPaint)
    }

    @Test func refreshAfterTimeout_clearsLoadFailedOnSuccess() async {
        var fail = true
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                if fail {
                    return OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: false)
                }
                return self.result([self.food(id: "ok", createdAt: 100)])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(vm.isLoadFailed)
        fail = false
        await vm.refreshAndWait()
        #expect(!vm.isLoadFailed)
        #expect(vm.hasLoaded)
        #expect(vm.notes.map(\.id) == ["ok"])
    }

    @Test func timeout_withSeededNotes_doesNotFlagLoadFailed() async {
        let cached = food(id: "cache", createdAt: 50)
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: false)
            },
            seedCache: { [cached] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(!vm.hasLoaded)
        #expect(!vm.isLoadFailed)
        #expect(!vm.isEmpty)
        #expect(vm.notes.map(\.id) == ["cache"])
    }

    @Test func mute_dropsBlockedAndMutedWord_notViaSpamScorer() async {
        let blocked = String(repeating: "d", count: 64)
        let good = food(id: "ok", createdAt: 300)
        let mutedAuthor = food(id: "ma", author: blocked, createdAt: 200)
        let mutedWord = food(id: "mw", createdAt: 100, content: "this is spamword here")
        let reply = food(id: "re", createdAt: 250, extraTags: [["e", "root", "", "reply"]])
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(blocked: [blocked], mutedWords: ["spamword"]),
            query: { _ in
                self.result([good, mutedAuthor, mutedWord, reply])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["ok"])
    }

    @Test func refresh_isTheOnlyRequeryPath() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                calls += 1
                return self.result([self.food(id: "aa", createdAt: 100)])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        vm.start()
        vm.start()
        #expect(calls == 1)
        await vm.refreshAndWait()
        #expect(calls == 2)
        #expect(vm.queryCount == 2)
    }

    /// The three derived states with the `emptyFollows` term gone: for every
    /// reachable input the truth table is unchanged, because on the surviving
    /// (Global) path `emptyFollows` was always false. Exactly one state holds
    /// while the list is empty; none holds once a note is on screen.
    @Test func derivedStates_truthTable_unchangedWithoutEmptyFollows() async {
        // awaiting: started, nothing resolved yet.
        let gate = AsyncStream<Void>.makeStream()
        let pending = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                for await _ in gate.stream { break }
                return self.result([])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        pending.start()
        #expect(pending.isAwaitingFirstPaint)
        #expect(!pending.isEmpty)
        #expect(!pending.isLoadFailed)
        gate.continuation.yield(())
        await pending.inFlight?.value
        // genuine empty: EOSE, zero accepted.
        #expect(!pending.isAwaitingFirstPaint)
        #expect(pending.isEmpty)
        #expect(!pending.isLoadFailed)

        // relay miss: no EOSE, nothing on screen.
        let missed = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: false) },
            seedCache: { [] },
            persist: { _ in }
        )
        await missed.startAndWait()
        #expect(!missed.isAwaitingFirstPaint)
        #expect(!missed.isEmpty)
        #expect(missed.isLoadFailed)

        // a note on screen: none of the three, whether the load latched or not.
        let seededMiss = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: false) },
            seedCache: { [self.food(id: "cache", createdAt: 50)] },
            persist: { _ in }
        )
        await seededMiss.startAndWait()
        #expect(!seededMiss.isAwaitingFirstPaint && !seededMiss.isEmpty && !seededMiss.isLoadFailed)

        let loaded = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in self.result([self.food(id: "ok", createdAt: 100)]) },
            seedCache: { [] },
            persist: { _ in }
        )
        await loaded.startAndWait()
        #expect(!loaded.isAwaitingFirstPaint && !loaded.isEmpty && !loaded.isLoadFailed)
    }

    @Test func cacheSeed_paintsBeforeQuery_andDoesNotLatch() async {
        let cached = food(id: "cache", createdAt: 50)
        let live = food(id: "live", createdAt: 80)
        var queried = false
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                queried = true
                return self.result([live])
            },
            seedCache: { [cached] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(queried)
        #expect(Set(vm.notes.map(\.id)) == ["cache", "live"])
        #expect(vm.hasLoaded)
    }

    @Test func subIds_comeFromProcessWideSequence() {
        let a = OnlyFoodFeedViewModel.nextSubId()
        let b = OnlyFoodFeedViewModel.nextSubId()
        #expect(a.hasPrefix("onlyfood-"))
        #expect(b.hasPrefix("onlyfood-"))
        #expect(a != b)
    }

    @Test func appBlocklist_dropsCurationPubkeys() async {
        let blocked = OnlyFoodFilter.blockedPubkeys.first!
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                self.result([
                    self.food(id: "ok", createdAt: 2),
                    self.food(id: "no", author: blocked, createdAt: 3),
                ])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["ok"])
    }
}
