import Foundation
import Testing
@testable import wisp

/// Unified-feed PR 4 gates (§3.1–3.3): three relays as one logical load,
/// kind-6 / poll ingest at parity with Android `addHashtagFeedEvent`, and the
/// resume paint. Hermetic: injected query and seed cache, no sockets.
@MainActor
struct OnlyFoodIngestParityTests {

    private let me = String(repeating: "a", count: 64)
    private let alice = String(repeating: "b", count: 64)
    private let bob = String(repeating: "c", count: 64)
    private let carol = String(repeating: "d", count: 64)

    private func note(
        id: String,
        author: String,
        createdAt: Int,
        content: String = "yummy",
        tags: [[String]] = [["t", "foodstr"]]
    ) -> NostrEvent {
        NostrEvent(
            id: id, pubkey: author, kind: 1, createdAt: createdAt,
            tags: tags, content: content, sig: String(repeating: "0", count: 128)
        )
    }

    private func poll(id: String, author: String, createdAt: Int, extraTags: [[String]] = []) -> NostrEvent {
        NostrEvent(
            id: id, pubkey: author, kind: Nip88.kindPoll, createdAt: createdAt,
            tags: [["t", "foodstr"], ["option", "a", "Soup"], ["option", "b", "Salad"]] + extraTags,
            content: "Soup or salad?", sig: String(repeating: "0", count: 128)
        )
    }

    private func json(_ e: NostrEvent) -> String {
        let obj: [String: Any] = [
            "id": e.id, "pubkey": e.pubkey, "kind": e.kind, "created_at": e.createdAt,
            "tags": e.tags, "content": e.content, "sig": e.sig,
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    /// NIP-18 repost of `inner` by `reposter`, carrying a food `t` tag (that is
    /// what the relay `#t` filter returns).
    private func repost(id: String, reposter: String, of inner: NostrEvent, createdAt: Int, content: String? = nil) -> NostrEvent {
        NostrEvent(
            id: id, pubkey: reposter, kind: 6, createdAt: createdAt,
            tags: [["t", "foodstr"], ["e", inner.id], ["p", inner.pubkey]],
            content: content ?? json(inner), sig: String(repeating: "0", count: 128)
        )
    }

    private func filter(blocked: Set<String> = [], mutedWords: Set<String> = []) -> OnlyFoodFilter {
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

    private func loaded(_ events: [NostrEvent]) -> OnlyFoodQueryResult {
        OnlyFoodQueryResult(events: events, connected: true, anySent: true, eoseFired: true)
    }

    private func vm(
        blocked: Set<String> = [],
        mutedWords: Set<String> = [],
        seedCache: @escaping () async -> [NostrEvent] = { [] },
        query: @escaping (OnlyFoodQueryRequest) async -> OnlyFoodQueryResult
    ) -> OnlyFoodFeedViewModel {
        OnlyFoodFeedViewModel(
            pubkey: me,
            filter: filter(blocked: blocked, mutedWords: mutedWords),
            query: query,
            seedCache: seedCache,
            persist: { _ in }
        )
    }

    // MARK: - §3.1 relays: one logical load across three sockets

    @Test func threeRelays_oneLogicalLoad_latchHolds_refreshRequeries() async {
        var requests: [OnlyFoodQueryRequest] = []
        let vm = vm { req in
            requests.append(req)
            return self.loaded([self.note(id: "n1", author: self.alice, createdAt: 100)])
        }
        await vm.startAndWait()
        #expect(requests.count == 1)
        #expect(vm.queryCount == 1)
        #expect(requests[0].relays == ["wss://search.nostrarchives.com", "wss://nos.lol", "wss://relay.primal.net"])
        #expect(Set(requests[0].filter.kinds ?? []) == [1, 6, Nip88.kindPoll])
        #expect(vm.hasLoaded)

        vm.start()
        await vm.inFlight?.value
        #expect(requests.count == 1)
        #expect(vm.queryCount == 1)

        await vm.refreshAndWait()
        #expect(requests.count == 2)
        #expect(vm.queryCount == 2)
    }

    // MARK: - §3.2 kind 6

    @Test func repost_insertsInnerNote_sortedByRepostTimestamp() async {
        let old = note(id: "inner", author: alice, createdAt: 50)     // the reposted note is old…
        let mid = note(id: "mid", author: bob, createdAt: 200)
        let rp = repost(id: "rp", reposter: carol, of: old, createdAt: 300)  // …the repost is new
        let vm = vm { _ in self.loaded([mid, rp]) }
        await vm.startAndWait()

        #expect(vm.notes.map(\.id) == ["inner", "mid"], "inner note sorts at the REPOST's time, above mid")
        #expect(vm.notes.first?.kind == 1)
        #expect(vm.notes.first?.pubkey == alice, "the INNER note is the list entry")
        #expect(vm.repostAuthors(for: "inner") == [carol])
        #expect(!vm.hasUserReposted("inner"))
        #expect(vm.repostAuthors(for: "mid").isEmpty)
    }

    @Test func repost_byCurrentUser_marksUserReposts() async {
        let inner = note(id: "inner", author: alice, createdAt: 50)
        let rp = repost(id: "rp", reposter: me, of: inner, createdAt: 300)
        let vm = vm { _ in self.loaded([rp]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["inner"])
        #expect(vm.hasUserReposted("inner"))
        #expect(vm.repostAuthors(for: "inner") == [me])
    }

    @Test func repost_dropped_whenInnerAuthorBlocked() async {
        let appBlocked = OnlyFoodFilter.blockedPubkeys.first!
        let byApp = repost(id: "r1", reposter: carol, of: note(id: "i1", author: appBlocked, createdAt: 50), createdAt: 300)
        let byUser = repost(id: "r2", reposter: carol, of: note(id: "i2", author: bob, createdAt: 50), createdAt: 301)
        let ok = repost(id: "r3", reposter: carol, of: note(id: "i3", author: alice, createdAt: 50), createdAt: 302)
        let vm = vm(blocked: [bob]) { _ in self.loaded([byApp, byUser, ok]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["i3"])
        #expect(vm.repostAuthors(for: "i1").isEmpty)
        #expect(vm.repostAuthors(for: "i2").isEmpty)
    }

    @Test func repost_dropped_whenInnerContentHitsMutedWord() async {
        let muted = repost(id: "r1", reposter: carol, of: note(id: "i1", author: alice, createdAt: 50, content: "cilantro soup"), createdAt: 300)
        let ok = repost(id: "r2", reposter: carol, of: note(id: "i2", author: alice, createdAt: 50, content: "tomato soup"), createdAt: 301)
        let vm = vm(mutedWords: ["cilantro"]) { _ in self.loaded([muted, ok]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["i2"])
    }

    @Test func repost_dropped_whenInnerNoteIsReply() async {
        let reply = note(id: "i1", author: alice, createdAt: 50, tags: [["t", "foodstr"], ["e", String(repeating: "e", count: 64), "", "reply"]])
        let rp = repost(id: "r1", reposter: carol, of: reply, createdAt: 300)
        let vm = vm { _ in self.loaded([rp]) }
        await vm.startAndWait()
        #expect(vm.notes.isEmpty)
        #expect(vm.isEmpty)
    }

    @Test func repost_dropped_whenInnerIsStructuralSpam_orUnparseable() async {
        let tags = [["t", "foodstr"]] + ["soup", "stew", "dinner", "homemade", "cooking"].map { ["t", $0] }
        let spammy = repost(id: "r1", reposter: carol, of: note(id: "i1", author: alice, createdAt: 50, tags: tags), createdAt: 300)
        let blank = repost(id: "r2", reposter: carol, of: note(id: "i2", author: alice, createdAt: 50), createdAt: 301, content: "")
        let junk = repost(id: "r3", reposter: carol, of: note(id: "i3", author: alice, createdAt: 50), createdAt: 302, content: "{not json")
        let vm = vm { _ in self.loaded([spammy, blank, junk]) }
        await vm.startAndWait()
        #expect(vm.notes.isEmpty)
    }

    @Test func repost_sameInnerByTwoAuthors_oneEntry_bothAttributed() async {
        let inner = note(id: "inner", author: alice, createdAt: 50)
        let first = repost(id: "r1", reposter: bob, of: inner, createdAt: 300)
        let second = repost(id: "r2", reposter: carol, of: inner, createdAt: 400)
        let dupOfFirst = first  // the same kind-6 arrives from a second relay
        let vm = vm { _ in self.loaded([first, second, dupOfFirst]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["inner"])
        #expect(vm.repostAuthors(for: "inner") == [bob, carol])
    }

    @Test func repost_ofNoteAlreadyInList_addsAttributionOnly_keepsPosition() async {
        let own = note(id: "n1", author: alice, createdAt: 100)
        let newer = note(id: "n2", author: bob, createdAt: 200)
        let rp = repost(id: "r1", reposter: carol, of: own, createdAt: 300)
        let vm = vm { _ in self.loaded([own, newer, rp]) }
        await vm.startAndWait()
        // n1 was seen on its own first; the later repost attributes it but does
        // not move it above n2 (same as Android's dedup by id on insert).
        #expect(vm.notes.map(\.id) == ["n2", "n1"])
        #expect(vm.repostAuthors(for: "n1") == [carol])
    }

    /// Parity note: the relay `#t` filter and Android's cache paint both gate on a
    /// food tag on the OUTER event; a repost without one is never ingested.
    @Test func repost_withoutFoodTagOnOuter_isNotIngested() async {
        let inner = note(id: "inner", author: alice, createdAt: 50)
        let bare = NostrEvent(
            id: "r1", pubkey: carol, kind: 6, createdAt: 300,
            tags: [["e", inner.id], ["p", inner.pubkey]], content: json(inner),
            sig: String(repeating: "0", count: 128)
        )
        let vm = vm { _ in self.loaded([bare]) }
        await vm.startAndWait()
        #expect(vm.notes.isEmpty)
    }

    @Test func cachePaint_replaysRepostAttribution_fromOuterEvent() async {
        let inner = note(id: "inner", author: alice, createdAt: 50)
        let rp = repost(id: "r1", reposter: bob, of: inner, createdAt: 300)
        let vm = vm(seedCache: { [rp] }) { _ in self.loaded([]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["inner"])
        #expect(vm.repostAuthors(for: "inner") == [bob])
    }

    /// Copilot review on #70: an inner note that carries no food tag of its
    /// own (the repost did) must still move the paging cursor, at the
    /// repost's time — otherwise a feed made of such entries can't page.
    @Test func paging_cursorCountsRepostInsertedInner_evenWithoutItsOwnFoodTag() async {
        var requests: [OnlyFoodQueryRequest] = []
        let untagged = note(id: "inner", author: alice, createdAt: 50, tags: [])
        let rp = repost(id: "r1", reposter: carol, of: untagged, createdAt: 300)
        let vm = vm { req in
            requests.append(req)
            return requests.count == 1 ? self.loaded([rp]) : self.loaded([])
        }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["inner"])

        vm.loadMore()
        await vm.inFlight?.value
        #expect(requests.count == 2, "paging issued")
        #expect(requests[1].filter.until == 299, "cursor is the REPOST's time, not the inner note's 50")
    }

    @Test func hiddenReposter_losesAttribution_entryKeptWhileOtherReposterRemains() async {
        let inner = note(id: "inner", author: alice, createdAt: 50)
        let byBob = repost(id: "r1", reposter: bob, of: inner, createdAt: 300)
        let byCarol = repost(id: "r2", reposter: carol, of: inner, createdAt: 400)
        let vm = vm { _ in self.loaded([byBob, byCarol]) }
        await vm.startAndWait()
        #expect(vm.repostAuthors(for: "inner") == [bob, carol])

        NotificationCenter.default.post(
            name: .contentHidden, object: nil,
            userInfo: [ContentHideKey.pubkeys: [bob], ContentHideKey.eventIds: [String]()]
        )
        for _ in 0..<50 where vm.repostAuthors(for: "inner").count == 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.repostAuthors(for: "inner") == [carol])
        #expect(vm.notes.map(\.id) == ["inner"], "entry stays: another reposter remains")

        NotificationCenter.default.post(
            name: .contentHidden, object: nil,
            userInfo: [ContentHideKey.pubkeys: [carol], ContentHideKey.eventIds: [String]()]
        )
        for _ in 0..<50 where !vm.repostAuthors(for: "inner").isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.repostAuthors(for: "inner").isEmpty)
        #expect(vm.notes.map(\.id) == ["inner"], "the inner author is not hidden; the note itself stays")
    }

    // MARK: - §3.2 polls

    @Test func poll_isAccepted_andStructuralCapApplies() async {
        let ok = poll(id: "p1", author: alice, createdAt: 200)
        let spammy = poll(id: "p2", author: alice, createdAt: 201,
                          extraTags: ["soup", "stew", "dinner", "homemade", "cooking"].map { ["t", $0] })
        let vm = vm { _ in self.loaded([ok, spammy]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["p1"])
        #expect(vm.notes.first?.kind == Nip88.kindPoll)
    }

    @Test func poll_dropped_onMutedWord_andBlockedAuthor() async {
        let muted = NostrEvent(
            id: "p1", pubkey: alice, kind: Nip88.kindPoll, createdAt: 200,
            tags: [["t", "foodstr"]], content: "cilantro or not?", sig: String(repeating: "0", count: 128)
        )
        let blocked = poll(id: "p2", author: bob, createdAt: 201)
        let ok = poll(id: "p3", author: alice, createdAt: 202)
        let vm = vm(blocked: [bob], mutedWords: ["cilantro"]) { _ in self.loaded([muted, blocked, ok]) }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["p3"])
    }

    // MARK: - §3.3 resume paint

    @Test func resume_withNonEmptyList_doesNotRepaint_andNeverClears() async {
        var seedCalls = 0
        var queries = 0
        let vm = vm(seedCache: { seedCalls += 1; return [] }) { _ in
            queries += 1
            return queries == 1
                ? self.loaded([self.note(id: "n1", author: self.alice, createdAt: 100)])
                : self.loaded([])   // nothing new on resume
        }
        await vm.startAndWait()
        #expect(seedCalls == 1, "the first load paints once")
        #expect(vm.notes.map(\.id) == ["n1"])

        vm.resume()
        #expect(vm.notes.map(\.id) == ["n1"], "no blank while the merge is in flight")
        await vm.inFlight?.value
        #expect(seedCalls == 1, "non-empty list: no repaint")
        #expect(queries == 2, "fresh merged on top")
        #expect(vm.notes.map(\.id) == ["n1"])
        #expect(vm.hasLoaded)
    }

    @Test func resume_withEmptyList_paintsFromCache_thenMerges() async {
        var seedCalls = 0
        var cache: [NostrEvent] = []
        var queries = 0
        let vm = vm(seedCache: { seedCalls += 1; return cache }) { _ in
            queries += 1
            return queries == 1
                ? self.loaded([])
                : self.loaded([self.note(id: "fresh", author: self.bob, createdAt: 500)])
        }
        await vm.startAndWait()
        #expect(vm.notes.isEmpty)
        #expect(vm.isEmpty)
        #expect(seedCalls == 1)

        cache = [note(id: "cached", author: alice, createdAt: 100)]
        vm.resume()
        await vm.inFlight?.value
        #expect(seedCalls == 2, "empty list: painted from cache")
        #expect(queries == 2)
        #expect(vm.notes.map(\.id) == ["fresh", "cached"], "painted, then fresh merged on top")
    }

    @Test func resume_beforeStart_orDuringInitialLoad_isANoOp() async {
        var queries = 0
        let gate = AsyncStream<Void>.makeStream()
        let vm = vm { _ in
            queries += 1
            for await _ in gate.stream { break }
            return self.loaded([])
        }
        vm.resume()
        #expect(queries == 0, "never starts work before start()")

        vm.start()
        // The query runs inside the load task after the cache paint; wait
        // until it is actually in flight before resuming on top of it.
        for _ in 0..<200 where queries == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(queries == 1)
        #expect(vm.isLoading)
        vm.resume()
        #expect(queries == 1, "does not overlap the in-flight initial load")
        gate.continuation.yield(())
        await vm.inFlight?.value
        #expect(queries == 1)
        #expect(vm.hasLoaded)
    }
}
