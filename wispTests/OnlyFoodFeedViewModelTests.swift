import Foundation
import Testing
@testable import wisp

/// Gate for Concern 3.3 — per-mode cache, mute-only ingest, empty follows.
/// Hermetic: every VM is constructed with an injected query, so a cache miss
/// cannot open a socket.
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
            follows: { [] },
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

    @Test func toggle_globalFollowingGlobal_doesNotRequeryGlobal() async {
        var calls: [String] = []
        let globalNote = food(id: "g1", author: String(repeating: "c", count: 64), createdAt: 200)
        let followNote = food(id: "f1", createdAt: 150)
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { [follow] },
            query: { req in
                let key = req.filter.authors == nil ? "global" : "following"
                calls.append(key)
                if key == "global" { return self.result([globalNote]) }
                return self.result([followNote])
            },
            seedCache: { [] },
            persist: { _ in }
        )

        await vm.startAndWait()
        #expect(calls == ["global"])
        #expect(vm.notes.map(\.id) == ["g1"])
        #expect(vm.cachedCount(.global) == 1)

        vm.setMode(.following)
        await vm.inFlight?.value
        #expect(calls == ["global", "following"])
        #expect(vm.notes.map(\.id) == ["f1"])
        #expect(vm.cachedCount(.following) == 1)

        vm.setMode(.global)
        #expect(calls == ["global", "following"])
        #expect(vm.queryCount == 2)
        #expect(vm.notes.map(\.id) == ["g1"])
        #expect(!vm.isLoading)
    }

    @Test func emptyFollows_doesNotQuery_andIsNotASpinner() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { [] },
            query: { _ in
                calls += 1
                return self.result([])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(calls == 1)

        vm.setMode(.following)
        #expect(calls == 1)
        #expect(vm.queryCount == 1)
        #expect(vm.emptyFollows)
        #expect(vm.isLoaded(.following))
        #expect(!vm.isLoading)
        #expect(!vm.isAwaitingFirstPaint)
        #expect(!vm.isLoadFailed)
        #expect(vm.notes.isEmpty)
    }

    @Test func emptyFollows_unlatchesWhenFollowsArrive() async {
        var followList: [String] = []
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { followList },
            query: { _ in
                calls += 1
                return self.result([self.food(id: "f1", createdAt: 100)])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        vm.setMode(.following)
        #expect(vm.emptyFollows)
        #expect(vm.isLoaded(.following))
        #expect(calls == 1)

        followList = [follow]
        vm.setMode(.global)
        vm.setMode(.following)
        await vm.inFlight?.value
        #expect(!vm.emptyFollows)
        #expect(calls == 2)
        #expect(vm.notes.map(\.id) == ["f1"])
    }

    @Test func emptyFollows_resyncOnVisibleModeQueries() async {
        var followList: [String] = []
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { followList },
            query: { _ in
                calls += 1
                return self.result([self.food(id: "f1", createdAt: 100)])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        vm.setMode(.following)
        #expect(calls == 1)

        followList = [follow]
        vm.resyncFollowingIfNeeded()
        await vm.inFlight?.value
        #expect(!vm.emptyFollows)
        #expect(calls == 2)
        #expect(vm.notes.map(\.id) == ["f1"])
    }

    @Test func zeroEvents_stillLatches_soToggleDoesNotRequery() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { [follow] },
            query: { _ in
                calls += 1
                return self.result([])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(calls == 1)
        #expect(vm.isLoaded(.global))
        #expect(vm.isEmpty)
        #expect(!vm.isLoadFailed)
        #expect(!vm.isAwaitingFirstPaint)

        vm.setMode(.following)
        await vm.inFlight?.value
        #expect(calls == 2)
        vm.setMode(.global)
        #expect(calls == 2)
    }

    @Test func timeout_doesNotLatch() async {
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { [] },
            query: { _ in
                OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: false)
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(!vm.isLoaded(.global))
        #expect(!vm.isLoading)
        #expect(vm.isLoadFailed)
        #expect(!vm.isEmpty)
        #expect(!vm.isAwaitingFirstPaint)
    }

    @Test func connectMiss_isLoadFailedNotEmpty() async {
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { [] },
            query: { _ in
                OnlyFoodQueryResult(events: [], connected: false, anySent: false, eoseFired: false)
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(!vm.isLoaded(.global))
        #expect(vm.isLoadFailed)
        #expect(!vm.isEmpty)
        #expect(!vm.isAwaitingFirstPaint)
    }

    @Test func refreshAfterTimeout_clearsLoadFailedOnSuccess() async {
        var fail = true
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { [] },
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
        #expect(vm.isLoaded(.global))
        #expect(vm.notes.map(\.id) == ["ok"])
    }

    @Test func timeout_withSeededNotes_doesNotFlagLoadFailed() async {
        let cached = food(id: "cache", createdAt: 50)
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { [] },
            query: { _ in
                OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: false)
            },
            seedCache: { [cached] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(!vm.isLoaded(.global))
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
            follows: { [] },
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
            follows: { [] },
            query: { _ in
                calls += 1
                return self.result([self.food(id: "aa", createdAt: 100)])
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        vm.setMode(.following)
        vm.setMode(.global)
        #expect(calls == 1)
        await vm.refreshAndWait()
        #expect(calls == 2)
    }

    @Test func cacheSeed_paintsBeforeQuery_andDoesNotLatch() async {
        let cached = food(id: "cache", createdAt: 50)
        let live = food(id: "live", createdAt: 80)
        var queried = false
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            follows: { [] },
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
        #expect(vm.isLoaded(.global))
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
            follows: { [] },
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
