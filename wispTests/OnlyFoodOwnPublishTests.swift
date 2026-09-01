import Foundation
import Testing
@testable import wisp

/// Concern C-H — optimistic insert of the user's own published kind-1 into
/// the OnlyFood caches. Hermetic: injected query, no sockets. The insert must
/// mirror the relay's own rule (food `t` tag + mute filter + Following author
/// gate) and must never issue a REQ (§7.4).
@MainActor
struct OnlyFoodOwnPublishTests {

    private let me = String(repeating: "c", count: 64)
    private let follow = String(repeating: "b", count: 64)

    private func note(
        id: String,
        author: String,
        createdAt: Int,
        tags: [[String]] = [["t", "foodstr"]],
        content: String = "soup"
    ) -> NostrEvent {
        NostrEvent(
            id: id, pubkey: author, kind: 1, createdAt: createdAt,
            tags: tags, content: content, sig: String(repeating: "0", count: 128)
        )
    }

    private func filter(mutedWords: Set<String> = []) -> OnlyFoodFilter {
        OnlyFoodFilter(
            nowSeconds: { 2_000_000 },
            blockedPubkeys: OnlyFoodFilter.blockedPubkeys,
            isUserBlocked: { _ in false },
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
        follows: [String] = [],
        mutedWords: Set<String> = [],
        query: @escaping (OnlyFoodQueryRequest) async -> OnlyFoodQueryResult
    ) -> OnlyFoodFeedViewModel {
        OnlyFoodFeedViewModel(
            pubkey: me,
            filter: filter(mutedWords: mutedWords),
            follows: { follows },
            query: query,
            seedCache: { [] },
            persist: { _ in }
        )
    }

    @Test func ownFoodNote_landsAtTopOfGlobal_withNoQuery() async {
        var calls = 0
        let vm = vm { _ in
            calls += 1
            return self.loaded([self.note(id: "old", author: self.follow, createdAt: 100)])
        }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["old"])

        let mine = note(id: "mine", author: me, createdAt: 200)
        let inserted = vm.insertOwnPublished(mine)
        #expect(inserted == [.global])
        #expect(vm.notes.map(\.id) == ["mine", "old"])
        #expect(calls == 1)
        #expect(vm.queryCount == 1)
    }

    /// The honest mirror: a note without a food `t` tag would not come back
    /// from the relay, so it is not painted either.
    @Test func ownNoteWithoutFoodTag_isNotInserted() async {
        let vm = vm { _ in self.loaded([self.note(id: "old", author: self.follow, createdAt: 100)]) }
        await vm.startAndWait()
        let untagged = note(id: "untagged", author: me, createdAt: 200, tags: [], content: "dinner was great")
        #expect(vm.insertOwnPublished(untagged).isEmpty)
        #expect(vm.notes.map(\.id) == ["old"])
    }

    @Test func ownNote_overStructuralCap_isNotInserted() async {
        let vm = vm { _ in self.loaded([]) }
        await vm.startAndWait()
        let tags = ["foodstr", "soup", "stew", "dinner", "homemade", "cooking"].map { ["t", $0] }
        let spammy = note(id: "six", author: me, createdAt: 200, tags: tags)
        #expect(vm.insertOwnPublished(spammy).isEmpty)
        #expect(vm.notes.isEmpty)
    }

    @Test func ownNote_withMutedWord_isNotInserted() async {
        let vm = vm(mutedWords: ["cilantro"]) { _ in self.loaded([]) }
        await vm.startAndWait()
        let muted = note(id: "m", author: me, createdAt: 200, content: "cilantro soup")
        #expect(vm.insertOwnPublished(muted).isEmpty)
    }

    @Test func otherAuthorOrOtherKind_isIgnored() async {
        let vm = vm { _ in self.loaded([]) }
        await vm.startAndWait()
        #expect(vm.insertOwnPublished(note(id: "theirs", author: follow, createdAt: 200)).isEmpty)
        let repost = NostrEvent(
            id: "k6", pubkey: me, kind: 6, createdAt: 200,
            tags: [["t", "foodstr"]], content: "", sig: String(repeating: "0", count: 128)
        )
        #expect(vm.insertOwnPublished(repost).isEmpty)
        #expect(vm.notes.isEmpty)
    }

    @Test func duplicateInsert_isIdempotent() async {
        let vm = vm { _ in self.loaded([]) }
        await vm.startAndWait()
        let mine = note(id: "mine", author: me, createdAt: 200)
        #expect(vm.insertOwnPublished(mine) == [.global])
        #expect(vm.insertOwnPublished(mine).isEmpty)
        #expect(vm.notes.map(\.id) == ["mine"])
    }

    /// Following mirrors the relay's `authors ∈ follows` filter: own notes
    /// land there only when the user follows themself.
    @Test func following_insertsOnlyWhenSelfIsFollowed() async {
        let vmNotSelf = vm(follows: [follow]) { _ in self.loaded([]) }
        await vmNotSelf.startAndWait()
        vmNotSelf.setMode(.following)
        await vmNotSelf.inFlight?.value
        #expect(vmNotSelf.insertOwnPublished(note(id: "a", author: me, createdAt: 200)) == [.global])
        #expect(vmNotSelf.notes.isEmpty)

        let vmSelf = vm(follows: [follow, me]) { _ in self.loaded([]) }
        await vmSelf.startAndWait()
        vmSelf.setMode(.following)
        await vmSelf.inFlight?.value
        let inserted = vmSelf.insertOwnPublished(note(id: "b", author: me, createdAt: 200))
        #expect(Set(inserted) == Set([.global, .following]))
        #expect(vmSelf.notes.map(\.id) == ["b"])
    }

    /// Inserted into a mode that is not on screen: the visible list is
    /// untouched now and the note is there after the toggle — still no REQ.
    @Test func insertIntoHiddenMode_showsAfterToggle_withoutRequery() async {
        var calls = 0
        let vm = vm(follows: [follow]) { _ in
            calls += 1
            return self.loaded([self.note(id: "old", author: self.follow, createdAt: 100)])
        }
        await vm.startAndWait()          // global loaded (1)
        vm.setMode(.following)           // following loaded (2)
        await vm.inFlight?.value
        #expect(calls == 2)
        #expect(vm.insertOwnPublished(note(id: "mine", author: me, createdAt: 200)) == [.global])
        #expect(vm.notes.map(\.id) == ["old"])
        vm.setMode(.global)
        #expect(vm.notes.map(\.id) == ["mine", "old"])
        #expect(calls == 2)
    }

    /// Insert while the initial load is still unsettled: the sort on EOSE
    /// puts the newest note first and does not drop it.
    @Test func insertDuringInitialLoad_survivesSettle_onTop() async {
        let gate = AsyncStream<Void>.makeStream()
        let vm = vm { _ in
            for await _ in gate.stream { break }
            return self.loaded([self.note(id: "old", author: self.follow, createdAt: 100)])
        }
        vm.start()
        #expect(vm.insertOwnPublished(note(id: "mine", author: me, createdAt: 200)) == [.global])
        #expect(vm.notes.map(\.id) == ["mine"])
        gate.continuation.yield(())
        await vm.inFlight?.value
        #expect(vm.notes.map(\.id) == ["mine", "old"])
    }

    /// The observer wiring: a `.nostrEventPublished` broadcast reaches the
    /// VM exactly like `PostPublisher` sends it.
    @Test func publishedNotification_reachesTheFeed() async {
        let vm = vm { _ in self.loaded([]) }
        await vm.startAndWait()
        let mine = note(id: "notified", author: me, createdAt: 200)
        NotificationCenter.default.post(name: .nostrEventPublished, object: nil, userInfo: ["event": mine])
        // queue: .main observer — let the runloop deliver it.
        await Task.yield()
        for _ in 0..<20 where vm.notes.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.notes.map(\.id) == ["notified"])
        #expect(vm.queryCount == 1)
    }
}
