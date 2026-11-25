import Foundation
import Testing
@testable import wisp

// The Scheduled tab's rules, on a scripted scheduler: nothing here reaches
// the network or publishes anything.

/// Lets a test hold a scripted call open and release it later.
nonisolated final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// A scheduler that answers from a script and records what it was asked.
nonisolated final class FakeScheduledListing: ScheduledListing, @unchecked Sendable {
    typealias ListResult = Result<[ScheduledPost], ScheduleFailure>
    typealias CancelResult = Result<ScheduleCancellation, ScheduleFailure>

    private let lock = NSLock()
    private var pending: [ListResult]
    private var failed: [ListResult]
    private var cancelResult: CancelResult?
    private var _listCalls: [ScheduleStatus] = []
    private var _cancelCalls: [String] = []
    var failedGate: TestGate?
    var cancelGate: TestGate?

    /// Each list answers with the next scripted result; the last one repeats.
    init(pending: [ListResult] = [.success([])], failed: [ListResult] = [.success([])],
         cancel: CancelResult? = nil) {
        self.pending = pending
        self.failed = failed
        self.cancelResult = cancel
    }

    var listCalls: [ScheduleStatus] { lock.withLock { _listCalls } }
    var cancelCalls: [String] { lock.withLock { _cancelCalls } }

    func list(status: ScheduleStatus, keypair: Keypair) async -> ListResult {
        if status == .failed, let failedGate { await failedGate.wait() }
        return lock.withLock {
            _listCalls.append(status)
            switch status {
            case .pending: return pending.count > 1 ? pending.removeFirst() : pending[0]
            case .failed: return failed.count > 1 ? failed.removeFirst() : failed[0]
            default: return .failure(.badStatus)
            }
        }
    }

    func cancel(id: String, keypair: Keypair) async -> CancelResult {
        lock.withLock { _cancelCalls.append(id) }
        if let cancelGate { await cancelGate.wait() }
        return lock.withLock { cancelResult } ?? .success(ScheduleCancellation(id: id, alreadyCancelled: false))
    }
}

@MainActor
@Suite(.serialized)
struct ScheduledListTests {

    static let now = 1_800_000_000

    @MainActor private struct Author {
        let privkey = Schnorr.randomPrivkey()
        let keypair: Keypair

        init() throws {
            let pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: privkey))
            keypair = Keypair(privkey: Hex.encode(privkey), pubkey: pubkey)
        }

        func event(kind: Int = 1, at: Int, _ content: String = "note", tags: [[String]] = []) throws -> NostrEvent {
            try NostrEvent.sign(privkey32: privkey, pubkey: keypair.pubkey, kind: kind,
                                createdAt: at, tags: tags, content: content)
        }

        func post(kind: Int = 1, in seconds: Int, _ content: String = "note", tags: [[String]] = [],
                  status: ScheduleStatus = .pending, attempts: Int = 0, lastError: String? = nil) throws -> ScheduledPost {
            let at = ScheduledListTests.now + seconds
            let event = try event(kind: kind, at: at, content, tags: tags)
            return ScheduledPost(id: event.id, publishAt: at, relayMode: .all, relays: [], status: status,
                                 attempts: attempts, lastError: lastError, sentAt: nil, event: event)
        }

        func viewModel(_ listing: FakeScheduledListing) -> DraftsViewModel {
            let vm = DraftsViewModel(keypair: keypair)
            vm.scheduledListing = listing
            return vm
        }
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    // MARK: - Loading

    @Test func loadsPendingAndFailed_pendingSoonestFirst_thenFailedNewestFirst() async throws {
        let author = try Author()
        let later = try author.post(in: 86_400, "later")
        let soon = try author.post(in: 600, "soon")
        let middle = try author.post(in: 3_600, "middle")
        let oldFailure = try author.post(in: -5 * 86_400, "old", status: .failed)
        let newFailure = try author.post(in: -86_400, "new", status: .failed)
        // The server's order: newest publish time first.
        let listing = FakeScheduledListing(pending: [.success([later, middle, soon])],
                                           failed: [.success([newFailure, oldFailure])])
        let vm = author.viewModel(listing)

        await vm.loadScheduledPosts()

        #expect(vm.pendingPosts.map(\.id) == [soon.id, middle.id, later.id])
        #expect(vm.failedPosts.map(\.id) == [newFailure.id, oldFailure.id])
        #expect(vm.scheduledPosts.map(\.id) == [soon.id, middle.id, later.id, newFailure.id, oldFailure.id])
        #expect(vm.scheduledLoadError == nil)
        #expect(!vm.isLoadingScheduled)
        // Exactly the two filtered calls: pending and failed.
        #expect(Set(listing.listCalls) == [.pending, .failed])
        #expect(listing.listCalls.count == 2)
    }

    @Test func pendingIsShownAsSoonAsItReturns_withoutWaitingForFailed() async throws {
        let author = try Author()
        let soon = try author.post(in: 600)
        let failure = try author.post(in: -86_400, status: .failed)
        let listing = FakeScheduledListing(pending: [.success([soon])], failed: [.success([failure])])
        let gate = TestGate()
        listing.failedGate = gate
        let vm = author.viewModel(listing)

        let load = Task { await vm.loadScheduledPosts() }
        // The failed request is still held open…
        try await settle { vm.pendingPosts.count == 1 }
        #expect(!vm.isLoadingScheduled)
        #expect(vm.failedPosts.isEmpty)
        #expect(!listing.listCalls.contains(.failed))

        gate.open()
        await load.value
        #expect(vm.failedPosts.map(\.id) == [failure.id])
    }

    @Test func ifTheFailedCallErrors_pendingIsShownAnyway() async throws {
        let author = try Author()
        let soon = try author.post(in: 600)
        let listing = FakeScheduledListing(pending: [.success([soon])], failed: [.failure(.network)])
        let vm = author.viewModel(listing)

        await vm.loadScheduledPosts()

        #expect(vm.pendingPosts.map(\.id) == [soon.id])
        #expect(vm.failedPosts.isEmpty)
        #expect(vm.scheduledLoadError == nil)
    }

    @Test func aFailedCallThatErrorsLeavesTheFailedRowsAlreadyShown() async throws {
        let author = try Author()
        let failure = try author.post(in: -86_400, status: .failed)
        let listing = FakeScheduledListing(failed: [.success([failure]), .failure(.internal)])
        let vm = author.viewModel(listing)

        await vm.loadScheduledPosts()
        await vm.loadScheduledPosts()

        #expect(vm.failedPosts.map(\.id) == [failure.id])
    }

    @Test(arguments: [
        (ScheduleFailure.network, "Couldn't reach Zap Cooking. Check your connection, then pull down to try again."),
        (.signedOut, "Sign in with an account that can sign to see your scheduled posts."),
        (.authFailed, "Couldn't verify your account. Check your device's date and time, then try again."),
        (.notConfigured, "Scheduling is unavailable right now."),
        (.internal, "Couldn't load your scheduled posts. Pull down to try again."),
        (.unknown, "Couldn't load your scheduled posts. Pull down to try again."),
    ])
    func ifThePendingCallErrors_theListSaysWhy(_ failure: ScheduleFailure, _ message: String) async throws {
        let author = try Author()
        let failedPost = try author.post(in: -86_400, status: .failed)
        let listing = FakeScheduledListing(pending: [.failure(failure)], failed: [.success([failedPost])])
        let vm = author.viewModel(listing)

        await vm.loadScheduledPosts()

        #expect(vm.scheduledLoadError == message)
        #expect(vm.pendingPosts.isEmpty)
        #expect(!vm.isLoadingScheduled)
        // The failed posts did load, and are still shown.
        #expect(vm.failedPosts.map(\.id) == [failedPost.id])
    }

    @Test func aLoadThatFailsKeepsTheRowsAlreadyOnScreen_andALaterOneClearsTheError() async throws {
        let author = try Author()
        let soon = try author.post(in: 600)
        let listing = FakeScheduledListing(pending: [.success([soon]), .failure(.network), .success([soon])])
        let vm = author.viewModel(listing)

        await vm.loadScheduledPosts()
        await vm.loadScheduledPosts()
        #expect(vm.pendingPosts.map(\.id) == [soon.id])
        #expect(vm.scheduledLoadError != nil)

        await vm.loadScheduledPosts()
        #expect(vm.scheduledLoadError == nil)
    }

    /// Nothing is cached: opening the list again after scheduling from the
    /// composer shows the new post.
    @Test func everyLoadIsTheServersCurrentAnswer() async throws {
        let author = try Author()
        let first = try author.post(in: 600, "first")
        let justScheduled = try author.post(in: 7_200, "just scheduled")
        let listing = FakeScheduledListing(pending: [.success([first]), .success([justScheduled, first])])

        let opened = author.viewModel(listing)
        await opened.loadScheduledPosts()
        #expect(opened.pendingPosts.map(\.id) == [first.id])

        // The screen is opened again: a new view model, a new fetch.
        let reopened = author.viewModel(listing)
        await reopened.loadScheduledPosts()
        #expect(reopened.pendingPosts.map(\.id) == [first.id, justScheduled.id])
        #expect(listing.listCalls.filter { $0 == .pending }.count == 2)
    }

    @Test func everySchedulableKindIsListed() async throws {
        let author = try Author()
        let kinds = [1, 20, 21, 22, 1068, 1111, 6969, 30023]
        let posts = try kinds.enumerated().map { index, kind in
            try author.post(kind: kind, in: 600 * (index + 1), "kind \(kind)")
        }
        let listing = FakeScheduledListing(pending: [.success(posts.reversed())])
        let vm = author.viewModel(listing)

        await vm.loadScheduledPosts()

        #expect(vm.pendingPosts.map(\.event.kind) == kinds)
    }

    @Test func rowsOfAnotherStatusAreNotShownAsPendingOrFailed() async throws {
        let author = try Author()
        let pending = try author.post(in: 600)
        let sent = try author.post(in: -600, "sent", status: .sent)
        let cancelled = try author.post(in: 900, "cancelled", status: .cancelled)
        let listing = FakeScheduledListing(pending: [.success([pending, sent, cancelled])],
                                           failed: [.success([sent, cancelled])])
        let vm = author.viewModel(listing)

        await vm.loadScheduledPosts()

        #expect(vm.pendingPosts.map(\.id) == [pending.id])
        #expect(vm.failedPosts.isEmpty)
    }

    // MARK: - Cancel

    @Test func cancelKeepsTheRowUntilTheServerAnswers_thenRemovesIt() async throws {
        let author = try Author()
        let first = try author.post(in: 600, "first")
        let second = try author.post(in: 1_200, "second")
        let listing = FakeScheduledListing(pending: [.success([first, second])])
        let gate = TestGate()
        listing.cancelGate = gate
        let vm = author.viewModel(listing)
        await vm.loadScheduledPosts()

        let cancel = Task { await vm.cancelScheduledPost(id: first.id) }
        try await settle { listing.cancelCalls == [first.id] }
        // The DELETE is in flight: the row is still there, marked.
        #expect(vm.pendingPosts.map(\.id) == [first.id, second.id])
        #expect(vm.cancellingIds == [first.id])

        // A second tap while it is in flight does not send a second DELETE.
        await vm.cancelScheduledPost(id: first.id)
        #expect(listing.cancelCalls == [first.id])

        gate.open()
        await cancel.value
        #expect(vm.pendingPosts.map(\.id) == [second.id])
        #expect(vm.cancellingIds.isEmpty)
        #expect(vm.scheduledNotice == nil)
    }

    @Test func aPostThatWasAlreadyCancelledIsRemoved() async throws {
        let author = try Author()
        let post = try author.post(in: 600)
        let listing = FakeScheduledListing(pending: [.success([post])],
                                           cancel: .success(ScheduleCancellation(id: post.id, alreadyCancelled: true)))
        let vm = author.viewModel(listing)
        await vm.loadScheduledPosts()

        await vm.cancelScheduledPost(id: post.id)

        #expect(vm.pendingPosts.isEmpty)
        #expect(vm.scheduledNotice == nil)
    }

    @Test(arguments: [
        (ScheduleStatus.publishing, "This post is being published right now and can't be cancelled."),
        (.sent, "This post has already been published."),
        (.failed, "This post already failed and won't be sent."),
    ])
    func aPostThatCanNoLongerBeCancelledSaysWhatHappened_andTheListRefreshes(
        _ status: ScheduleStatus, _ message: String
    ) async throws {
        let author = try Author()
        let post = try author.post(in: 30)
        let other = try author.post(in: 600, "other")
        // After the refusal the server no longer lists it as pending.
        let listing = FakeScheduledListing(pending: [.success([other, post]), .success([other])],
                                           cancel: .failure(.notCancellable(status: status)))
        let vm = author.viewModel(listing)
        await vm.loadScheduledPosts()
        #expect(listing.listCalls.count == 2)

        await vm.cancelScheduledPost(id: post.id)

        #expect(vm.scheduledNotice == message)
        // Refreshed: both lists fetched again, and the row reflects the truth.
        #expect(listing.listCalls.count == 4)
        #expect(vm.pendingPosts.map(\.id) == [other.id])
        #expect(vm.cancellingIds.isEmpty)
    }

    @Test func aPostThatNoLongerExistsSaysSo_andTheListRefreshes() async throws {
        let author = try Author()
        let post = try author.post(in: 600)
        let listing = FakeScheduledListing(pending: [.success([post]), .success([])], cancel: .failure(.notFound))
        let vm = author.viewModel(listing)
        await vm.loadScheduledPosts()

        await vm.cancelScheduledPost(id: post.id)

        #expect(vm.scheduledNotice == "This scheduled post no longer exists.")
        #expect(vm.pendingPosts.isEmpty)
        #expect(listing.listCalls.count == 4)
    }

    @Test(arguments: [ScheduleFailure.network, .internal, .authFailed, .unknown, .signedOut])
    func aCancelThatDidNotGetThroughLeavesTheRow_andSaysSo(_ failure: ScheduleFailure) async throws {
        let author = try Author()
        let post = try author.post(in: 600)
        let listing = FakeScheduledListing(pending: [.success([post])], cancel: .failure(failure))
        let vm = author.viewModel(listing)
        await vm.loadScheduledPosts()

        await vm.cancelScheduledPost(id: post.id)

        // Still scheduled as far as anyone knows: the row must not vanish.
        #expect(vm.pendingPosts.map(\.id) == [post.id])
        #expect(vm.scheduledNotice == failure.message)
        #expect(vm.cancellingIds.isEmpty)
        #expect(listing.listCalls.count == 2)
    }

    // MARK: - Order and status words

    @Test func statusWords() throws {
        let author = try Author()
        let now = Self.now
        #expect(ScheduledList.statusLabel(for: try author.post(in: 600), now: now) == "Scheduled")
        #expect(ScheduledList.statusLabel(for: try author.post(in: -20), now: now) == "Posting soon")
        #expect(ScheduledList.statusLabel(for: try author.post(in: -20, attempts: 2), now: now) == "Trying again")
        #expect(ScheduledList.statusLabel(for: try author.post(in: -20, status: .publishing), now: now) == "Posting now")
        #expect(ScheduledList.statusLabel(for: try author.post(in: -20, status: .failed), now: now) == "Didn't post")
        #expect(ScheduledList.statusLabel(for: try author.post(in: -20, status: .sent), now: now) == "Posted")
        #expect(ScheduledList.statusLabel(for: try author.post(in: 600, status: .cancelled), now: now) == "Cancelled")
        // Plain words for a failure: no codes, no relay talk.
        #expect(!ScheduledList.failedExplanation.contains("_"))
        #expect(!ScheduledList.failedExplanation.lowercased().contains("relay"))
    }

    // MARK: - Previews, one per schedulable kind

    @Test func preview_note_takesThePictureOutOfTheText() throws {
        let author = try Author()
        let preview = ScheduledPostPreview(event: try author.event(
            at: Self.now, "Sunday roast.\n\nhttps://img.example.com/roast.JPG\nhttps://img.example.com/gravy.png",
            tags: [["imeta", "url https://img.example.com/roast.JPG", "m image/jpeg"]]
        ))
        #expect(preview.kindLabel == nil)
        #expect(preview.text == "Sunday roast.")
        #expect(preview.imageUrl == "https://img.example.com/roast.JPG")
        #expect(preview.moreMediaCount == 1)
        #expect(!preview.hasVideo)
        #expect(preview.pollOptions.isEmpty)
    }

    @Test func preview_reply_isLabelled_butAQuoteIsNot() throws {
        let author = try Author()
        let id = String(repeating: "a", count: 64)
        let reply = ScheduledPostPreview(event: try author.event(at: Self.now, "agreed", tags: [["e", id, "", "root"]]))
        #expect(reply.kindLabel == "Reply")
        #expect(reply.text == "agreed")
        let quote = ScheduledPostPreview(event: try author.event(at: Self.now, "look", tags: [["e", id, "", "mention"], ["q", id]]))
        #expect(quote.kindLabel == nil)
    }

    @Test func preview_comment() throws {
        let author = try Author()
        let preview = ScheduledPostPreview(event: try author.event(kind: 1111, at: Self.now, "nice loaf"))
        #expect(preview.kindLabel == "Comment")
        #expect(preview.text == "nice loaf")
    }

    @Test func preview_picture_readsItsImetaTags() throws {
        let author = try Author()
        let preview = ScheduledPostPreview(event: try author.event(
            kind: 20, at: Self.now, "Sourdough, day three",
            tags: [["imeta", "url https://img.example.com/blob/abc123", "m image/jpeg", "dim 800x600"],
                   ["imeta", "url https://img.example.com/crumb.jpg"]]
        ))
        #expect(preview.kindLabel == "Picture")
        #expect(preview.text == "Sourdough, day three")
        // The first has no file extension: its mime type says it is a picture.
        #expect(preview.imageUrl == "https://img.example.com/blob/abc123")
        #expect(preview.moreMediaCount == 1)
    }

    @Test(arguments: [21, 22])
    func preview_video(_ kind: Int) throws {
        let author = try Author()
        let preview = ScheduledPostPreview(event: try author.event(
            kind: kind, at: Self.now, "Knife skills",
            tags: [["imeta", "url https://v.example.com/knife.mp4", "m video/mp4"]]
        ))
        #expect(preview.kindLabel == "Video")
        #expect(preview.text == "Knife skills")
        #expect(preview.imageUrl == nil)
        #expect(preview.hasVideo)
        #expect(preview.moreMediaCount == 1)
    }

    @Test func preview_noteWithAVideoLink() throws {
        let author = try Author()
        let preview = ScheduledPostPreview(event: try author.event(
            at: Self.now, "watch this https://v.example.com/a.mov",
            tags: [["imeta", "url https://v.example.com/a.mov", "m video/quicktime"]]
        ))
        #expect(preview.text == "watch this")
        #expect(preview.hasVideo)
        #expect(preview.imageUrl == nil)
        // In the text and in imeta: one video, not two.
        #expect(preview.moreMediaCount == 1)
    }

    @Test func preview_poll_listsItsOptionsInOrder() throws {
        let author = try Author()
        let preview = ScheduledPostPreview(event: try author.event(
            kind: 1068, at: Self.now, "Brisket or ribs?",
            tags: [["option", "x1", "Brisket"], ["option", "x2", "Ribs"], ["polltype", "singlechoice"],
                   ["endsAt", "1900000000"]]
        ))
        #expect(preview.kindLabel == "Poll")
        #expect(preview.text == "Brisket or ribs?")
        #expect(preview.pollOptions == ["Brisket", "Ribs"])
    }

    @Test func preview_zapPoll_listsItsOptionsInOrder() throws {
        let author = try Author()
        let preview = ScheduledPostPreview(event: try author.event(
            kind: 6969, at: Self.now, "Which sauce?",
            tags: [["poll_option", "0", "Red"], ["poll_option", "1", "Green"], ["closed_at", "1900000000"]]
        ))
        #expect(preview.kindLabel == "Zap poll")
        #expect(preview.pollOptions == ["Red", "Green"])
    }

    @Test func preview_article_showsItsTitle() throws {
        let author = try Author()
        let titled = ScheduledPostPreview(event: try author.event(
            kind: 30023, at: Self.now, "# Heading\n\nA very long body of markdown…",
            tags: [["d", "roast"], ["title", "The Sunday Roast"]]
        ))
        #expect(titled.kindLabel == "Article")
        #expect(titled.text == "The Sunday Roast")
        let untitled = ScheduledPostPreview(event: try author.event(kind: 30023, at: Self.now, "Body only"))
        #expect(untitled.text == "Body only")
    }

    @Test func preview_aPostThatIsOnlyAPictureHasNoText() throws {
        let author = try Author()
        let preview = ScheduledPostPreview(event: try author.event(at: Self.now, "https://img.example.com/a.webp?x=1"))
        #expect(preview.text.isEmpty)
        #expect(preview.imageUrl == "https://img.example.com/a.webp?x=1")
        #expect(preview.moreMediaCount == 0)
    }
}

// The real list and cancel, on the request suite's stubbed session.
extension ScheduleApiRequestTests {

    @Test func scheduledPostsApi_listsByStatus_andCancelsById() async throws {
        let privkey = Schnorr.randomPrivkey()
        let pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: privkey))
        let keypair = Keypair(privkey: Hex.encode(privkey), pubkey: pubkey)
        let event = try NostrEvent.sign(privkey32: privkey, pubkey: pubkey, kind: 1068, createdAt: 1_900_000_000,
                                        tags: [["option", "a", "Yes"]], content: "poll?")
        let api = ScheduledPostsApi(session: ScheduleStubProtocol.session())

        ScheduleStubProtocol.script([.http(200, """
        {"items":[{"id":"\(event.id)","publish_at":\(event.createdAt),"relay_mode":"all","relays":[],
          "status":"failed","attempts":10,"last_error":"no_relay_accepted","sent_at":null,"event":\(event.toJSON())}]}
        """)])
        let posts = try await api.list(status: .failed, keypair: keypair).get()
        let post = try #require(posts.first)
        #expect(post.status == .failed)
        #expect(post.lastError == "no_relay_accepted")
        #expect(post.event.kind == 1068)
        #expect(ScheduleStubProtocol.requests.first?.method == "GET")
        #expect(ScheduleStubProtocol.requests.first?.url == Self.url + "?status=failed")

        ScheduleStubProtocol.script([.http(409, "{\"error\":\"not_cancellable\",\"status\":\"publishing\"}")])
        let refused = await api.cancel(id: event.id, keypair: keypair)
        if case .failure(let failure) = refused {
            #expect(failure == .notCancellable(status: .publishing))
        } else {
            Issue.record("a publishing post was reported cancelled")
        }
        #expect(ScheduleStubProtocol.requests.first?.method == "DELETE")
        #expect(ScheduleStubProtocol.requests.first?.url == Self.url + "/" + event.id)
    }
}
