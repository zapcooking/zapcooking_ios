import Foundation
import Testing
@testable import wisp

/// Concern C-H — optimistic insert of the user's own published kind-1 into
/// the OnlyFood cache. Hermetic: injected query, no sockets. The insert must
/// mirror the relay's own rule (food `t` tag + mute filter) and must never
/// issue a REQ (§7.4). Single-mode since unified-feed PR 3.
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
        mutedWords: Set<String> = [],
        query: @escaping (OnlyFoodQueryRequest) async -> OnlyFoodQueryResult
    ) -> OnlyFoodFeedViewModel {
        OnlyFoodFeedViewModel(
            pubkey: me,
            filter: filter(mutedWords: mutedWords),
            query: query,
            seedCache: { [] },
            persist: { _ in }
        )
    }

    @Test func ownFoodNote_landsAtTop_withNoQuery() async {
        var calls = 0
        let vm = vm { _ in
            calls += 1
            return self.loaded([self.note(id: "old", author: self.follow, createdAt: 100)])
        }
        await vm.startAndWait()
        #expect(vm.notes.map(\.id) == ["old"])

        let mine = note(id: "mine", author: me, createdAt: 200)
        #expect(vm.insertOwnPublished(mine))
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
        #expect(vm.insertOwnPublished(untagged) == false)
        #expect(vm.notes.map(\.id) == ["old"])
    }

    @Test func ownNote_overStructuralCap_isNotInserted() async {
        let vm = vm { _ in self.loaded([]) }
        await vm.startAndWait()
        let tags = ["foodstr", "soup", "stew", "dinner", "homemade", "cooking"].map { ["t", $0] }
        let spammy = note(id: "six", author: me, createdAt: 200, tags: tags)
        #expect(vm.insertOwnPublished(spammy) == false)
        #expect(vm.notes.isEmpty)
    }

    @Test func ownNote_withMutedWord_isNotInserted() async {
        let vm = vm(mutedWords: ["cilantro"]) { _ in self.loaded([]) }
        await vm.startAndWait()
        let muted = note(id: "m", author: me, createdAt: 200, content: "cilantro soup")
        #expect(vm.insertOwnPublished(muted) == false)
    }

    @Test func otherAuthorOrOtherKind_isIgnored() async {
        let vm = vm { _ in self.loaded([]) }
        await vm.startAndWait()
        #expect(vm.insertOwnPublished(note(id: "theirs", author: follow, createdAt: 200)) == false)
        let repost = NostrEvent(
            id: "k6", pubkey: me, kind: 6, createdAt: 200,
            tags: [["t", "foodstr"]], content: "", sig: String(repeating: "0", count: 128)
        )
        #expect(vm.insertOwnPublished(repost) == false)
        #expect(vm.notes.isEmpty)
    }

    @Test func duplicateInsert_isIdempotent() async {
        let vm = vm { _ in self.loaded([]) }
        await vm.startAndWait()
        let mine = note(id: "mine", author: me, createdAt: 200)
        #expect(vm.insertOwnPublished(mine))
        #expect(vm.insertOwnPublished(mine) == false)
        #expect(vm.notes.map(\.id) == ["mine"])
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
        #expect(vm.insertOwnPublished(note(id: "mine", author: me, createdAt: 200)))
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
