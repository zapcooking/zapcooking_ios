import Foundation
import Observation
import Testing
@testable import wisp

/// `FreshFeedViewModel` driven end to end through the real `FreshRelayClient`
/// on `FakeGroupTransport` (no socket, no relay), with real signed events.
/// Notifications go through a private `NotificationCenter`, so nothing here
/// reaches the rest of the hosted app.
@Suite(.serialized) @MainActor struct FreshFeedViewModelTests {

    // MARK: - Fixtures

    nonisolated static let now = 1_800_000_000
    nonisolated static let floor = now - FreshPosts.freeWindowSeconds
    static let day = 86_400

    struct Author {
        let priv: Data
        let pubkey: String
        init() throws {
            priv = Schnorr.randomPrivkey()
            pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: priv))
        }
        func event(_ createdAt: Int, kind: Int = 1, content: String? = nil, tags: [[String]] = []) throws -> NostrEvent {
            try NostrEvent.sign(privkey32: priv, pubkey: pubkey, kind: kind, createdAt: createdAt,
                                tags: tags, content: content ?? "post \(createdAt) \(UUID().uuidString)")
        }
        func longForm(_ createdAt: Int, d: String, publishedAt: Int? = nil, recipe: Bool = false) throws -> NostrEvent {
            var tags: [[String]] = [["d", d]]
            if let publishedAt { tags.append(["published_at", String(publishedAt)]) }
            if recipe { tags.append(["t", "zapcooking"]) }
            // A recipe carries the recipe template (`RecipeParser.isRecipe`).
            let content = recipe
                ? "## Chef's notes\n\n\(d) \(createdAt)\n\n## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."
                : "long form \(d) \(createdAt)"
            return try event(createdAt, kind: 30023, content: content, tags: tags)
        }
    }

    final class Rules {
        var snapshot: SafetyFilterSnapshot? = nil
        var reportedCoordinates: Set<String> = []
        var privateIds: Set<String> = []
        var own: [NostrEvent] = []
        var ownGate: Gate? = nil
        var persisted: [NostrEvent] = []
    }

    /// Holds `ownLocalPosts` until opened.
    final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// No profile fetches: the live source asks real relays for kind 0s.
    struct NoProfiles: FreshProfileSource {
        func cached(_ pubkey: String) -> ProfileData? { nil }
        func observe(_ events: [NostrEvent]) {}
        func updates() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    }

    final class Store: FreshVisitStorage, @unchecked Sendable {
        var data: [String: String] = [:]
        func freshVisitValue(forKey key: String) throws -> String? { data[key] }
        func setFreshVisitValue(_ value: String, forKey key: String) throws { data[key] = value }
    }

    struct Rig {
        let transport: FakeGroupTransport
        let vm: FreshFeedViewModel
        let center: NotificationCenter
        let rules: Rules
        let store: Store
    }

    func makeRig(pubkey: String = String(repeating: "c", count: 64), rules: Rules = Rules(),
                 store: Store = Store(), retry: [Duration] = [.milliseconds(30)]) -> Rig {
        let transport = FakeGroupTransport()
        let clientCenter = NotificationCenter()
        let client = FreshRelayClient(
            transport: transport, now: { Self.now }, silenceTimeout: 5,
            notificationCenter: clientCenter,
            foregroundNotification: Notification.Name("FreshFeedViewModelTests.fg")
        )
        let center = NotificationCenter()
        let vm = FreshFeedViewModel(
            pubkey: pubkey, client: client, now: { Self.now },
            rules: { rules.snapshot },
            isReportedCoordinate: { rules.reportedCoordinates.contains($0) },
            isPrivate: { rules.privateIds.contains($0) },
            ownLocalPosts: {
                if let gate = rules.ownGate { await gate.wait() }
                return rules.own
            },
            persist: { rules.persisted.append(contentsOf: $0) },
            visitStorage: store, lastVisit: FreshLastVisit(),
            notificationCenter: center, retryDelays: retry,
            profileSource: NoProfiles()
        )
        return Rig(transport: transport, vm: vm, center: center, rules: rules, store: store)
    }

    struct Req {
        let subId: String
        let filter: [String: Any]
        var since: Int? { filter["since"] as? Int }
        var until: Int? { filter["until"] as? Int }
        var kinds: [Int]? { filter["kinds"] as? [Int] }
        var tTags: [String]? { filter["#t"] as? [String] }
        var limit: Int? { filter["limit"] as? Int }
    }

    func reqs(_ socket: FakeGroupSocket?) -> [Req] {
        (socket?.sent ?? []).compactMap { frame in
            guard frame.hasPrefix("[\"REQ\""), let data = frame.data(using: .utf8),
                  let a = try? JSONSerialization.jsonObject(with: data) as? [Any], a.count == 3,
                  let id = a[1] as? String, let f = a[2] as? [String: Any] else { return nil }
            return Req(subId: id, filter: f)
        }
    }

    @discardableResult
    func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func awaitReq(_ t: FakeGroupTransport, _ n: Int) async throws -> Req {
        let ok = await eventually { self.reqs(t.latest).count >= n }
        try #require(ok, "REQ #\(n) never sent")
        return reqs(t.latest)[n - 1]
    }

    func answer(_ t: FakeGroupTransport, _ req: Req, _ events: [NostrEvent], eose: Bool = true) {
        for e in events { t.latest?.feed("[\"EVENT\",\"\(req.subId)\",\(e.toJSON())]") }
        if eose { t.latest?.feed("[\"EOSE\",\"\(req.subId)\"]") }
    }

    /// Activate and answer page 1 with `page`; returns once the tail's REQ is out.
    func start(_ rig: Rig, page: [NostrEvent]) async throws -> (page: Req, tail: Req) {
        rig.vm.activate()
        let pageReq = try await awaitReq(rig.transport, 1)
        answer(rig.transport, pageReq, page)
        // A short page 1 also asks for the recipe row, in either order with
        // the tail: find the tail by its filter, not its position.
        let found = await eventually { self.reqs(rig.transport.latest).contains(where: Self.isTail) }
        try #require(found, "tail REQ never sent")
        return (pageReq, reqs(rig.transport.latest).first(where: Self.isTail)!)
    }

    /// Tail posts wait behind the pill; tap it (what the view does).
    func reveal(_ rig: Rig, count: Int) async {
        let arrived = await eventually { rig.vm.newPostsCount >= count }
        #expect(arrived, "\(count) tail post(s) never reached the pill")
        rig.vm.showNewPosts()
    }

    static func isTail(_ r: Req) -> Bool {
        r.limit == FreshRelayClient.tailBacklogLimit && r.kinds == FreshPosts.feedKinds && r.until == nil
    }

    func rules(blocked: Set<String> = [], words: Set<String> = [], wot: Bool = false) -> SafetyFilterSnapshot {
        SafetyFilterSnapshot(mutedWords: words, blockedPubkeys: blocked, mutedThreads: [],
                             wotEnabled: wot, qualifiedNetwork: [], userPubkey: "")
    }

    // MARK: - Page 1 and filters

    @Test("page 1: since = floor, kinds [1,30023,1068]; mutes, blocks, old edits and reported coordinates dropped; WoT not applied")
    func firstPageFilters() async throws {
        let a = try Author(), muted = try Author(), blocked = try Author()
        let r = Rules()
        // WoT on with an empty network fails closed everywhere else; Fresh ignores it.
        r.snapshot = rules(blocked: [blocked.pubkey], words: ["spoiler"], wot: true)
        let reported = try a.longForm(Self.now - 400, d: "reported")
        r.reportedCoordinates = [RecipeRepository.coordinate(reported)]
        let rig = makeRig(rules: r)

        let keep1 = try a.event(Self.now - 100)
        let keep2 = try muted.event(Self.now - 200)
        let page = [keep1, keep2,
                    try muted.event(Self.now - 250, content: "big SPOILER ahead"),
                    try blocked.event(Self.now - 300),
                    try a.longForm(Self.now - 350, d: "old", publishedAt: Self.now - 400 * Self.day),
                    reported]
        let (pageReq, tailReq) = try await start(rig, page: page)

        #expect(pageReq.since == Self.floor)
        #expect(pageReq.kinds == [1, 30023, 1068])
        #expect(pageReq.until == nil)
        #expect(await eventually { rig.vm.posts.map(\.id) == [keep1.id, keep2.id] })
        #expect(rig.vm.hasLoaded && !rig.vm.loadFailed)
        #expect(tailReq.kinds == [1, 30023, 1068])
        #expect(rig.vm.tailStatus == .live)
        #expect(!rig.transport.opened.flatMap(\.sent).contains { $0.hasPrefix("[\"AUTH\"") || $0.hasPrefix("[\"EVENT\"") })
    }

    @Test("page 1 failing with nothing to show is loadFailed; a refresh that answers clears it")
    func firstPageFailure() async throws {
        let rig = makeRig()
        rig.vm.activate()
        let req = try await awaitReq(rig.transport, 1)
        rig.transport.latest?.feed("[\"CLOSED\",\"\(req.subId)\",\"error: shutting down\"]")
        #expect(await eventually { rig.vm.loadFailed })
        #expect(rig.vm.posts.isEmpty)

        let a = try Author()
        let post = try a.event(Self.now - 10)
        async let refresh: Void = rig.vm.refreshAndWait()
        let again = await eventually { self.reqs(rig.transport.latest).contains { $0.subId != req.subId && $0.until == nil && $0.since == Self.floor } }
        try #require(again)
        let req2 = reqs(rig.transport.latest).last { $0.since == Self.floor && $0.kinds == [1, 30023, 1068] && $0.limit == 30 }!
        answer(rig.transport, req2, [post])
        await refresh
        #expect(!rig.vm.loadFailed)
        #expect(rig.vm.posts.map(\.id) == [post.id])
    }

    // MARK: - Paging and the finish line

    @Test("paging asks until = the previous page's oldest; a short page reaches the end and loads the recipe row")
    func pagingToTheEnd() async throws {
        let a = try Author(), b = try Author()
        let rig = makeRig()
        let page1 = try (0..<30).map { i in try (i % 2 == 0 ? a : b).event(Self.now - 10 - i * 10) }
        _ = try await start(rig, page: page1)
        #expect(await eventually { rig.vm.posts.count == 30 })
        #expect(rig.vm.finishLine == .none)

        async let more: Void = rig.vm.loadMoreAndWait()
        let pageReq = try await awaitReq(rig.transport, 3)
        #expect(pageReq.until == page1.map(\.createdAt).min())
        #expect(pageReq.since == Self.floor)
        let page2 = try [a.event(Self.now - 400), b.event(Self.now - 410)]
        answer(rig.transport, pageReq, page2)
        await more
        #expect(rig.vm.posts.count == 32)
        #expect(rig.vm.finishLine.caughtUp && rig.vm.finishLine.recipeRow)

        // The recipe row: kind 30023 with #t, no since; newest per coordinate,
        // old edits kept, reader's rules applied.
        let recipesReq = try await awaitReq(rig.transport, 4)
        #expect(recipesReq.kinds == [30023])
        #expect(recipesReq.since == nil)
        #expect(Set(recipesReq.tTags ?? []) == ["zapcooking", "nostrcooking"])
        let old = try a.longForm(Self.now - 900 * Self.day, d: "soup", publishedAt: Self.now - 1000 * Self.day, recipe: true)
        let newer = try a.longForm(Self.now - 800 * Self.day, d: "soup", publishedAt: Self.now - 1000 * Self.day, recipe: true)
        let other = try b.longForm(Self.now - 700 * Self.day, d: "bread", recipe: true)
        answer(rig.transport, recipesReq, [old, newer, other])
        #expect(await eventually { rig.vm.recipePicks.map(\.id) == [other.id, newer.id] })
    }

    @Test("the recipe row takes recipes only: an article tagged zapcooking (no recipe template) never appears")
    func recipeRowSkipsTaggedArticles() async throws {
        let a = try Author(), b = try Author()
        let rig = makeRig()
        _ = try await start(rig, page: [])
        let recipesReq = try #require(await eventually { self.reqs(rig.transport.latest).contains { $0.kinds == [30023] } }
                                      ? reqs(rig.transport.latest).first { $0.kinds == [30023] } : nil)
        let recipe = try a.longForm(Self.now - 30 * Self.day, d: "pie", recipe: true)
        // The device-pass case: an announcement tagged zapcooking, badge ARTICLE.
        let article = try b.event(Self.now - 20 * Self.day, kind: 30023,
                                  content: "Arkade.Money and ZapCooking, now running Branta. Read more on our blog.",
                                  tags: [["d", "branta"], ["title", "Now running Branta"], ["t", "zapcooking"]])
        #expect(FreshPosts.isRecipe(kind: article.kind, tags: article.tags), "tag-only rule would take it")
        #expect(!RecipeParser.isRecipe(article))
        answer(rig.transport, recipesReq, [article, recipe])
        #expect(await eventually { rig.vm.recipePicks.map(\.id) == [recipe.id] })
        #expect(!rig.vm.recipePool.contains { $0.id == article.id })
    }

    @Test("auth-required on a page is the floor: the end, not an error")
    func floorEndsTheFeed() async throws {
        let a = try Author()
        let rig = makeRig()
        let page1 = try (0..<30).map { try a.event(Self.now - 10 - $0 * 10) }
        _ = try await start(rig, page: page1)
        _ = await eventually { rig.vm.posts.count == 30 }
        async let more: Void = rig.vm.loadMoreAndWait()
        let req = try await awaitReq(rig.transport, 3)
        rig.transport.latest?.feed("[\"AUTH\",\"challenge\"]")
        rig.transport.latest?.feed("[\"CLOSED\",\"\(req.subId)\",\"auth-required: posts older than 14 days are for Zap Cooking members\"]")
        await more
        #expect(rig.vm.finishLine.caughtUp)
        #expect(!rig.vm.loadFailed)
        #expect(rig.vm.posts.count == 30)
    }

    // MARK: - Block / report instant hide

    @Test("block: .contentHidden pubkeys drop the author at once, and the tail can't bring them back")
    func blockInstantHide() async throws {
        let x = try Author(), y = try Author()
        let rig = makeRig()
        let xPost = try x.event(Self.now - 100), yPost = try y.event(Self.now - 200)
        let (_, tail) = try await start(rig, page: [xPost, yPost])
        _ = await eventually { rig.vm.posts.count == 2 }

        // What MuteRepository.blockUser → ContentHide.broadcast posts.
        rig.center.post(name: .contentHidden, object: nil, userInfo: [
            ContentHideKey.eventIds: [String](), ContentHideKey.pubkeys: [x.pubkey.uppercased()],
            ContentHideKey.coordinates: [String](),
        ])
        #expect(await eventually { rig.vm.posts.map(\.id) == [yPost.id] })

        let xLater = try x.event(Self.now - 5)
        let yLater = try y.event(Self.now - 4)
        answer(rig.transport, tail, [xLater, yLater], eose: false)
        await reveal(rig, count: 1)
        #expect(await eventually { rig.vm.posts.first?.id == yLater.id })
        #expect(!rig.vm.posts.contains { $0.pubkey == x.pubkey })
    }

    @Test("report: a long-form post is hidden by id and coordinate, so its edit stays hidden; recipe picks too")
    func reportHidesLongFormByCoordinate() async throws {
        let z = try Author(), y = try Author()
        let rig = makeRig()
        let article = try z.longForm(Self.now - 100, d: "a1")
        let note = try y.event(Self.now - 200)
        let (_, tail) = try await start(rig, page: [article, note])
        _ = await eventually { rig.vm.posts.count == 2 }

        // What ReportedContent.hide → ContentHide.broadcast posts for a
        // kind-30023 report (ReportTarget.event sets the coordinate).
        let target = ReportTarget.event(article)
        #expect(target.coordinate == "30023:\(z.pubkey):a1")
        rig.center.post(name: .contentHidden, object: nil, userInfo: [
            ContentHideKey.eventIds: [article.id], ContentHideKey.pubkeys: [String](),
            ContentHideKey.coordinates: [target.coordinate!],
        ])
        #expect(await eventually { rig.vm.posts.map(\.id) == [note.id] })

        let edit = try z.longForm(Self.now - 50, d: "a1")
        let fresh = try y.event(Self.now - 40)
        answer(rig.transport, tail, [edit, fresh], eose: false)
        await reveal(rig, count: 1)
        #expect(await eventually { rig.vm.posts.first?.id == fresh.id })
        #expect(!rig.vm.posts.contains { $0.id == edit.id })
    }

    @Test("a coordinate already reported (persisted) is dropped at ingest, whatever the event id")
    func persistedReportedCoordinate() async throws {
        let z = try Author()
        let r = Rules()
        r.reportedCoordinates = ["30023:\(z.pubkey):gone"]
        let rig = makeRig(rules: r)
        let edit = try z.longForm(Self.now - 100, d: "gone")
        let kept = try z.longForm(Self.now - 200, d: "kept")
        _ = try await start(rig, page: [edit, kept])
        #expect(await eventually { rig.vm.posts.map(\.id) == [kept.id] })
    }

    @Test("long-form edits collapse to the newest per coordinate, on the page and from the tail")
    func longFormEditsCollapse() async throws {
        let z = try Author()
        let rig = makeRig()
        let v1 = try z.longForm(Self.now - 300, d: "x")
        let v2 = try z.longForm(Self.now - 200, d: "x")
        let (_, tail) = try await start(rig, page: [v2, v1])
        #expect(await eventually { rig.vm.posts.map(\.id) == [v2.id] })
        let v3 = try z.longForm(Self.now - 100, d: "x")
        answer(rig.transport, tail, [v3], eose: false)
        await reveal(rig, count: 1)
        #expect(await eventually { rig.vm.posts.map(\.id) == [v3.id] })
    }

    // MARK: - Own posts

    @Test("own posts: last 14 days from local sources, in time order, replaced by the relay's copy by id")
    func ownPostsPinned() async throws {
        let me = try Author(), other = try Author()
        let r = Rules()
        let mine = try me.event(Self.now - 150)
        r.own = [mine, try me.event(Self.now - 20 * Self.day), try other.event(Self.now - 10)]
        let rig = makeRig(pubkey: me.pubkey, rules: r)
        let p1 = try other.event(Self.now - 100), p2 = try other.event(Self.now - 200)
        let (_, tail) = try await start(rig, page: [p1, p2])
        #expect(await eventually { rig.vm.posts.map(\.id) == [p1.id, mine.id, p2.id] })

        // A fresh publish is pinned at its time.
        let published = try me.event(Self.now - 5)
        rig.center.post(name: .nostrEventPublished, object: nil, userInfo: ["event": published])
        #expect(await eventually { rig.vm.posts.map(\.id) == [published.id, p1.id, mine.id, p2.id] })

        // The relay later returns it: one copy.
        answer(rig.transport, tail, [published], eose: false)
        await reveal(rig, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.vm.posts.filter { $0.id == published.id }.count == 1)
        #expect(rig.vm.posts.count == 4)
    }

    // MARK: - Tail

    @Test("tail: a new post goes on top; a late-admitted one is placed by its time")
    func tailPlacement() async throws {
        let a = try Author(), b = try Author()
        let rig = makeRig()
        let p1 = try a.event(Self.now - 100), p2 = try b.event(Self.now - 1000)
        let (_, tail) = try await start(rig, page: [p1, p2])
        _ = await eventually { rig.vm.posts.count == 2 }
        let newest = try b.event(Self.now - 10)
        let late = try b.event(Self.now - 500)
        answer(rig.transport, tail, [newest, late], eose: false)
        await reveal(rig, count: 2)
        #expect(await eventually { rig.vm.posts.map(\.id) == [newest.id, p1.id, late.id, p2.id] })
    }

    @Test("tail lost in the foreground is retried after the backoff; not while backgrounded; the foreground hook revives")
    func tailRetryWithBackoff() async throws {
        let a = try Author()
        let rig = makeRig(retry: [.milliseconds(40)])
        _ = try await start(rig, page: [try a.event(Self.now - 100)])

        rig.transport.latest?.dropConnection()
        #expect(await eventually { rig.vm.tailStatus == .lost })
        #expect(await eventually { rig.transport.opened.count == 2 && !self.reqs(rig.transport.latest).isEmpty })
        #expect(await eventually { rig.vm.tailStatus == .live })

        // Backgrounded: a drop is not retried.
        rig.vm.appDidEnterBackground()
        rig.transport.latest?.dropConnection()
        #expect(await eventually { rig.vm.tailStatus == .lost })
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.transport.opened.count == 2)

        // Foreground: revived at once.
        rig.vm.appDidBecomeActive()
        #expect(await eventually { rig.transport.opened.count == 3 && !self.reqs(rig.transport.latest).isEmpty })
        let resumed = reqs(rig.transport.latest)[0]
        #expect(resumed.since == Self.now - 100 - FreshRelayClient.tailResumeOverlapSeconds)
    }

    @Test("leaving Fresh closes the socket and keeps the list; coming back starts a tail, not page 1")
    func deactivateAndReturn() async throws {
        let a = try Author()
        let rig = makeRig()
        let post = try a.event(Self.now - 100)
        _ = try await start(rig, page: [post])
        _ = await eventually { rig.vm.posts.count == 1 }

        await rig.vm.deactivateAndWait()
        #expect(rig.vm.tailStatus == .idle)
        #expect(rig.vm.posts.map(\.id) == [post.id])

        rig.vm.activate()
        #expect(await eventually { rig.transport.opened.count == 2 && !self.reqs(rig.transport.latest).isEmpty })
        // A tail, and (page 1 was short, recipes unanswered) the recipe row
        // again; never page 1.
        _ = await eventually { self.reqs(rig.transport.latest).contains(where: Self.isTail) }
        let reqsAfter = reqs(rig.transport.latest)
        #expect(!reqsAfter.contains { $0.limit == FreshRelayClient.pageSize })
        let tails = reqsAfter.filter(Self.isTail)
        #expect(tails.count == 1)
        #expect(tails.first?.since == Self.now - 100 - FreshRelayClient.tailResumeOverlapSeconds)
    }

    // MARK: - Last visit

    /// The list calls `loadMoreIfNeeded(currentIndex:)` with the row's index
    /// in `rows` (MainView enumerates `rows`), and rows hold the divider.
    /// The prefetch threshold is a count of posts: with the divider above,
    /// the post seven from the end must not page, and the sixth must.
    @Test("paging counts posts, not rows: with the divider above, the 7th post from the end does not page; the 6th does")
    func pagingThresholdCountsPostsNotRows() async throws {
        let a = try Author(), b = try Author()
        let store = Store()
        let pubkey = String(repeating: "e", count: 64)
        // Posts at now-10, now-20, …: the first two are new, so the divider
        // sits after them, above everything the threshold looks at.
        store.data[FreshLastVisit.key(pubkey: pubkey)] = String(Self.now - 25)
        let rig = makeRig(pubkey: pubkey, store: store)
        let page1 = try (0..<30).map { i in try (i % 2 == 0 ? a : b).event(Self.now - 10 - i * 10) }
        _ = try await start(rig, page: page1)
        #expect(await eventually { rig.vm.posts.count == 30 })
        func rowIndex(_ id: String) -> Int? {
            rig.vm.rows.firstIndex { row in
                if case .row(let r) = row { return r.id == id }
                return false
            }
        }
        let prefetch = FreshFeedViewModel.loadMorePrefetch
        let seventh = rig.vm.posts[rig.vm.posts.count - prefetch - 1]
        let sixth = rig.vm.posts[rig.vm.posts.count - prefetch]
        let seventhRow = try #require(rowIndex(seventh.id))
        #expect(seventhRow == rig.vm.posts.count - prefetch, "the divider shifts the row index by one")
        let sent = reqs(rig.transport.latest).count

        rig.vm.loadMoreIfNeeded(currentIndex: seventhRow)
        try await Task.sleep(for: .milliseconds(200))
        #expect(reqs(rig.transport.latest).count == sent, "paged one post early: the row index was compared with the post count")

        rig.vm.loadMoreIfNeeded(currentIndex: try #require(rowIndex(sixth.id)))
        #expect(await eventually { self.reqs(rig.transport.latest).count == sent + 1 }, "the 6th post from the end pages")
    }

    @Test("last visit: the divider sits before the first post already seen; the newest shown is stored")
    func lastVisitDivider() async throws {
        let a = try Author(), b = try Author()
        let store = Store()
        let pubkey = String(repeating: "d", count: 64)
        store.data[FreshLastVisit.key(pubkey: pubkey)] = String(Self.now - 150)
        let rig = makeRig(pubkey: pubkey, store: store)
        let posts = try [a.event(Self.now - 50), b.event(Self.now - 100), a.event(Self.now - 200), b.event(Self.now - 300)]
        _ = try await start(rig, page: posts)
        _ = await eventually { rig.vm.posts.count == 4 }
        let shape = rig.vm.rows.map { row -> String in
            switch row {
            case .row(let r): return r.id
            case .divider(let n): return "divider:\(n)"
            }
        }
        #expect(shape == [posts[0].id, posts[1].id, "divider:2", posts[2].id, posts[3].id])
        #expect(store.data[FreshLastVisit.key(pubkey: pubkey)] == String(Self.now - 50))
    }

    // MARK: - Kind plumbing

    @Test("FeedKind.fresh: stored as FRESH, restored only while the flag is on; routed to its own body")
    func kindPlumbing() {
        let name = "FreshFeedViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let pk = String(repeating: "e", count: 64)
        FeedKindStore.persist(.fresh, pubkey: pk, defaults: defaults)
        #expect(defaults.string(forKey: FeedKindStore.typeKey(pk)) == "FRESH")
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults, freshEnabled: true) { _ in nil } == .fresh)
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults, freshEnabled: false) { _ in nil } == FeedKindStore.legacyDefaultKind)
        #expect(FeedTabRouting.body(for: .fresh) == .fresh)
        #expect(FeedTabRouting.composeSuggestions(for: .fresh).isEmpty)
        #expect(FeedKind.fresh.displayName == "Fresh")
        var tracker = FeedKindSwitchTracker()
        _ = FeedTabRouting.repinTarget(afterObserving: .follows, tracker: &tracker)
        #expect(FeedTabRouting.repinTarget(afterObserving: .fresh, tracker: &tracker) == nil)
    }

    @Test("ships on: Fresh is in the picker and the default for new sign-ins")
    func shipsOn() {
        #expect(FeatureFlags.freshFeedEnabled == true)
        #expect(FeedKindStore.defaultKind == .fresh)
    }

    @Test("account wipe removes the Fresh last-visit mark")
    func wipeListHasLastVisit() {
        let pk = String(repeating: "0", count: 63) + "f"
        UserDefaults.standard.set("123", forKey: FreshLastVisit.key(pubkey: pk))
        NostrKey.deleteAccount(pubkey: pk)
        #expect(UserDefaults.standard.string(forKey: FreshLastVisit.key(pubkey: pk)) == nil)
    }

    // MARK: - Review fixes (PR #205)

    @Test("private replies never show: a cached synthetic and a broadcast one are both excluded")
    func privateRepliesExcluded() async throws {
        let me = try Author(), other = try Author()
        let r = Rules()
        let signed = try me.event(Self.now - 150)
        let cachedPrivate = try me.event(Self.now - 120)
        let unsigned = NostrEvent(id: UUID().uuidString, pubkey: me.pubkey, kind: 1,
                                  createdAt: Self.now - 110, tags: [], content: "private reply", sig: "")
        r.privateIds = [cachedPrivate.id]
        r.own = [signed, cachedPrivate, unsigned]
        let rig = makeRig(pubkey: me.pubkey, rules: r)
        let p = try other.event(Self.now - 300)
        _ = try await start(rig, page: [p])
        #expect(await eventually { rig.vm.posts.map(\.id) == [signed.id, p.id] })

        // What PrivateReplyPublisher posts.
        let synthetic = NostrEvent(id: UUID().uuidString, pubkey: me.pubkey, kind: 1,
                                   createdAt: Self.now - 5, tags: [], content: "private", sig: "")
        rig.center.post(name: .nostrEventPublished, object: nil, userInfo: ["event": synthetic, "isPrivate": true])
        let flagged = try me.event(Self.now - 4)
        rig.center.post(name: .nostrEventPublished, object: nil, userInfo: ["event": flagged, "isPrivate": true])
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.vm.posts.map(\.id) == [signed.id, p.id])
    }

    @Test("an empty answered page reaches the end: the list (caught up + recipe row) shows, not the empty message")
    func emptyWindowShowsTheFinishLine() async throws {
        let a = try Author()
        let rig = makeRig()
        _ = try await start(rig, page: [])
        #expect(await eventually { rig.vm.finishLine.caughtUp })
        #expect(rig.vm.isEmpty)
        #expect(!rig.vm.showsEmptyMessage)
        let recipes = try #require(await eventually { self.reqs(rig.transport.latest).contains { $0.kinds == [30023] } } ? reqs(rig.transport.latest).first { $0.kinds == [30023] } : nil)
        let recipe = try a.longForm(Self.now - 30 * Self.day, d: "pie", recipe: true)
        answer(rig.transport, recipes, [recipe])
        #expect(await eventually { rig.vm.recipePicks.map(\.id) == [recipe.id] })
    }

    @Test("foreground is forwarded while another kind is selected, so retries work after Fresh is picked")
    func foregroundForwardedWhileInactive() async throws {
        let a = try Author()
        let rig = makeRig(retry: [.milliseconds(30)])
        rig.vm.appDidEnterBackground()
        FeedTabRouting.freshDidBecomeActive(fresh: rig.vm)   // Fresh not selected yet
        _ = try await start(rig, page: [try a.event(Self.now - 100)])
        rig.transport.latest?.dropConnection()
        #expect(await eventually { rig.transport.opened.count == 2 && !self.reqs(rig.transport.latest).isEmpty })
    }

    @Test("leaving Fresh while page 1 is still loading sends nothing; coming back loads page 1")
    func deactivateDuringFirstLoad() async throws {
        let a = try Author()
        let r = Rules()
        let gate = Gate()
        r.ownGate = gate
        let rig = makeRig(rules: r)
        rig.vm.activate()
        try await Task.sleep(for: .milliseconds(20))
        rig.vm.deactivate()
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.transport.opened.flatMap(\.sent).isEmpty)
        #expect(!rig.vm.hasLoaded && !rig.vm.isLoading)

        let post = try a.event(Self.now - 10)
        _ = try await start(rig, page: [post])
        #expect(await eventually { rig.vm.posts.map(\.id) == [post.id] })
    }

    @Test("coming to the foreground while page 1 is pending starts no tail before the page")
    func foregroundDuringFirstPage() async throws {
        let a = try Author()
        let rig = makeRig()
        rig.vm.activate()
        let pageReq = try await awaitReq(rig.transport, 1)
        rig.vm.appDidBecomeActive()
        try await Task.sleep(for: .milliseconds(50))
        #expect(reqs(rig.transport.latest).count == 1)
        answer(rig.transport, pageReq, [try a.event(Self.now - 10)])
        #expect(await eventually { self.reqs(rig.transport.latest).contains(where: Self.isTail) })
        #expect(reqs(rig.transport.latest).filter(Self.isTail).count == 1)
    }

    @Test("refresh stops the tail before resetting seen, reloads page 1, then restarts the tail with the overlap")
    func refreshOrdersTheTail() async throws {
        let a = try Author()
        let rig = makeRig()
        let first = try a.event(Self.now - 100)
        let (_, tail) = try await start(rig, page: [first])
        _ = await eventually { rig.vm.posts.count == 1 }

        async let refresh: Void = rig.vm.refreshAndWait()
        let closed = await eventually { rig.transport.latest?.sent.contains("[\"CLOSE\",\"\(tail.subId)\"]") ?? false }
        #expect(closed)
        let pageReq = try #require(await eventually { self.reqs(rig.transport.latest).filter { $0.limit == 30 }.count == 2 } ? reqs(rig.transport.latest).filter { $0.limit == 30 }.last : nil)
        let sent = rig.transport.latest?.sent ?? []
        let closeIndex = sent.firstIndex(of: "[\"CLOSE\",\"\(tail.subId)\"]")!
        let pageIndex = sent.firstIndex { $0.contains(pageReq.subId) }!
        #expect(closeIndex < pageIndex)
        // The page returns the post the old tail could have delivered: it is
        // not lost to the seen-set.
        let during = try a.event(Self.now - 20)
        answer(rig.transport, pageReq, [during, first])
        await refresh
        #expect(rig.vm.posts.map(\.id) == [during.id, first.id])
        let restarted = await eventually { self.reqs(rig.transport.latest).contains { Self.isTail($0) && $0.subId != tail.subId } }
        try #require(restarted)
        let newTail = try #require(reqs(rig.transport.latest).last(where: Self.isTail))
        #expect(newTail.since == Self.now - 20 - FreshRelayClient.tailResumeOverlapSeconds)
    }

    @Test("a full page that is all filtered out fetches the next page without a scroll")
    func emptyFullPageHops() async throws {
        let muted = try Author(), a = try Author()
        let r = Rules()
        r.snapshot = rules(blocked: [muted.pubkey])
        let rig = makeRig(rules: r)
        let hiddenPage = try (0..<30).map { try muted.event(Self.now - 10 - $0 * 10) }
        rig.vm.activate()
        let req1 = try await awaitReq(rig.transport, 1)
        answer(rig.transport, req1, hiddenPage)
        let req2 = try #require(await eventually { self.reqs(rig.transport.latest).contains { $0.until != nil } } ? reqs(rig.transport.latest).first { $0.until != nil } : nil)
        #expect(req2.until == hiddenPage.map(\.createdAt).min())
        let visible = try a.event(Self.now - 400)
        answer(rig.transport, req2, [visible])
        #expect(await eventually { rig.vm.posts.map(\.id) == [visible.id] })
    }

    @Test("a post dated days ahead is dropped, so it can't anchor the tail; the anchor stays clamped to now + 30 s")
    func futureDatedAnchorClamped() async throws {
        let a = try Author()
        let rig = makeRig()
        let (_, tail) = try await start(rig, page: [try a.event(Self.now + 86_400), try a.event(Self.now - 100)])
        #expect(tail.since == Self.now - 100)
        await rig.vm.deactivateAndWait()
        rig.vm.activate()
        let resumed = try #require(await eventually { rig.transport.opened.count == 2 && !self.reqs(rig.transport.latest).isEmpty } ? reqs(rig.transport.latest).first(where: Self.isTail) : nil)
        #expect(resumed.since == Self.now - 100 - FreshRelayClient.tailResumeOverlapSeconds)

        // Within the skew, a post is kept and anchors at most now + 30 s.
        let rig2 = makeRig()
        let (_, tail2) = try await start(rig2, page: [try a.event(Self.now + 30)])
        #expect(tail2.since == Self.now + FreshRelayClient.futureSkewSeconds)
    }

    @Test("a long-form edit from the tail is persisted as well as shown")
    func tailEditPersisted() async throws {
        let z = try Author()
        let r = Rules()
        let rig = makeRig(rules: r)
        let (_, tail) = try await start(rig, page: [try z.longForm(Self.now - 300, d: "x")])
        let edit = try z.longForm(Self.now - 100, d: "x")
        answer(rig.transport, tail, [edit], eose: false)
        await reveal(rig, count: 1)
        #expect(await eventually { rig.vm.posts.map(\.id) == [edit.id] })
        #expect(r.persisted.contains { $0.id == edit.id })
    }

    @Test("own long-form keeps one row per coordinate: own edits collapse, and the newer of own and relay wins")
    func ownLongFormByCoordinate() async throws {
        let me = try Author()
        let r = Rules()
        let ownOld = try me.longForm(Self.now - 500, d: "a")
        let ownNew = try me.longForm(Self.now - 400, d: "a")
        let ownNewerThanRelay = try me.longForm(Self.now - 50, d: "b")
        r.own = [ownOld, ownNew, ownNewerThanRelay]
        let rig = makeRig(pubkey: me.pubkey, rules: r)
        let relayB = try me.longForm(Self.now - 200, d: "b")
        let relayNote = try me.event(Self.now - 600)
        _ = try await start(rig, page: [relayB, relayNote])
        #expect(await eventually { rig.vm.posts.map(\.id) == [ownNewerThanRelay.id, ownNew.id, relayNote.id] })
    }

    @Test("the visit mark records the newest row shown, own posts included")
    func visitMarkIncludesOwnPosts() async throws {
        let me = try Author(), other = try Author()
        let r = Rules()
        let mine = try me.event(Self.now - 10)
        r.own = [mine]
        let store = Store()
        let rig = makeRig(pubkey: me.pubkey, rules: r, store: store)
        _ = try await start(rig, page: [try other.event(Self.now - 100)])
        _ = await eventually { rig.vm.posts.count == 2 }
        #expect(store.data[FreshLastVisit.key(pubkey: me.pubkey)] == String(Self.now - 10))
    }

    @Test("a recipe published from the editor (persisted, no notification) appears on refresh")
    func ownRecipeArrivesOnRefresh() async throws {
        let me = try Author(), other = try Author()
        let r = Rules()
        let rig = makeRig(pubkey: me.pubkey, rules: r)
        let p = try other.event(Self.now - 100)
        _ = try await start(rig, page: [p])
        _ = await eventually { rig.vm.posts.count == 1 }
        let recipe = try me.longForm(Self.now - 30, d: "stew", recipe: true)
        r.own = [recipe]
        async let refresh: Void = rig.vm.refreshAndWait()
        let pageReq = try #require(await eventually { self.reqs(rig.transport.latest).filter { $0.limit == 30 }.count == 2 } ? reqs(rig.transport.latest).filter { $0.limit == 30 }.last : nil)
        answer(rig.transport, pageReq, [p])
        await refresh
        #expect(rig.vm.posts.map(\.id) == [recipe.id, p.id])
    }

    // MARK: - Fresh UI PR (rulings 2026-11-10)

    nonisolated final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() { lock.lock(); _value = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    }

    final class DeletedIds {
        var ids: Set<String> = []
    }

    func makeRig(pubkey: String = String(repeating: "c", count: 64), rules: Rules = Rules(),
                 deleted: DeletedIds) -> Rig {
        let transport = FakeGroupTransport()
        let client = FreshRelayClient(
            transport: transport, now: { Self.now }, silenceTimeout: 5,
            notificationCenter: NotificationCenter(),
            foregroundNotification: Notification.Name("FreshFeedViewModelTests.fg")
        )
        let center = NotificationCenter()
        let store = Store()
        let vm = FreshFeedViewModel(
            pubkey: pubkey, client: client, now: { Self.now },
            rules: { rules.snapshot },
            isReportedCoordinate: { rules.reportedCoordinates.contains($0) },
            isPrivate: { rules.privateIds.contains($0) },
            isDeleted: { deleted.ids.contains($0.id) },
            ownLocalPosts: { rules.own },
            persist: { rules.persisted.append(contentsOf: $0) },
            visitStorage: store, lastVisit: FreshLastVisit(),
            notificationCenter: center, retryDelays: [.milliseconds(30)],
            profileSource: NoProfiles()
        )
        return Rig(transport: transport, vm: vm, center: center, rules: rules, store: store)
    }

    @Test("pill: tail posts wait behind it and the list does not move; tapping inserts them by time")
    func pillHoldsTailPosts() async throws {
        let a = try Author(), b = try Author()
        let rig = makeRig()
        let p1 = try a.event(Self.now - 100), p2 = try b.event(Self.now - 1000)
        let (_, tail) = try await start(rig, page: [p1, p2])
        _ = await eventually { rig.vm.posts.count == 2 }
        let newest = try b.event(Self.now - 10)
        let late = try b.event(Self.now - 500)
        answer(rig.transport, tail, [newest, late, newest], eose: false)   // a repeat counts once
        #expect(await eventually { rig.vm.newPostsCount == 2 })
        #expect(rig.vm.showsNewPostsPill)
        #expect(rig.vm.posts.map(\.id) == [p1.id, p2.id])

        // Close: the pill hides, the posts keep waiting, the list stays.
        rig.vm.dismissNewPostsPill()
        #expect(!rig.vm.showsNewPostsPill)
        #expect(rig.vm.posts.map(\.id) == [p1.id, p2.id])
        // Another arrival brings the pill back.
        let third = try a.event(Self.now - 5)
        answer(rig.transport, tail, [third], eose: false)
        #expect(await eventually { rig.vm.showsNewPostsPill && rig.vm.newPostsCount == 3 })

        rig.vm.showNewPosts()
        #expect(rig.vm.posts.map(\.id) == [third.id, newest.id, p1.id, late.id, p2.id])
        #expect(!rig.vm.showsNewPostsPill)
        #expect(rig.vm.newPostsCount == 0)
    }

    @Test("a blocked author's waiting posts leave the pill too")
    func hideClearsWaitingPosts() async throws {
        let x = try Author(), y = try Author()
        let rig = makeRig()
        let (_, tail) = try await start(rig, page: [try y.event(Self.now - 100)])
        answer(rig.transport, tail, [try x.event(Self.now - 10), try y.event(Self.now - 9)], eose: false)
        #expect(await eventually { rig.vm.newPostsCount == 2 })
        rig.center.post(name: .contentHidden, object: nil, userInfo: [
            ContentHideKey.eventIds: [String](), ContentHideKey.pubkeys: [x.pubkey],
            ContentHideKey.coordinates: [String](),
        ])
        #expect(await eventually { rig.vm.newPostsCount == 1 })
    }

    @Test("a failed or timed-out pull-to-refresh keeps the list (and the finish line)")
    func failedRefreshKeepsTheList() async throws {
        let a = try Author()
        let rig = makeRig()
        let shown = try [a.event(Self.now - 100), a.event(Self.now - 200)]
        _ = try await start(rig, page: shown)
        _ = await eventually { rig.vm.posts.count == 2 && rig.vm.finishLine.caughtUp }

        async let refresh: Void = rig.vm.refreshAndWait()
        let pageReq = try #require(await eventually { self.reqs(rig.transport.latest).filter { $0.limit == 30 }.count == 2 } ? reqs(rig.transport.latest).filter { $0.limit == 30 }.last : nil)
        rig.transport.latest?.feed("[\"CLOSED\",\"\(pageReq.subId)\",\"error: overloaded\"]")
        await refresh
        #expect(rig.vm.posts.map(\.id) == shown.map(\.id))
        #expect(rig.vm.finishLine.caughtUp)
        #expect(!rig.vm.loadFailed)

        // A dropped connection during the refresh: same.
        async let again: Void = rig.vm.refreshAndWait()
        let sent = await eventually { self.reqs(rig.transport.latest).filter { $0.limit == 30 }.count == 3 }
        try #require(sent)
        rig.transport.latest?.dropConnection()
        await again
        #expect(rig.vm.posts.map(\.id) == shown.map(\.id))
    }

    @Test("own posts: replies are never pinned; top-level notes, long-form and polls are")
    func ownRepliesNotPinned() async throws {
        let me = try Author(), other = try Author()
        let r = Rules()
        let topLevel = try me.event(Self.now - 150)
        let reply = try me.event(Self.now - 140, tags: [["e", String(repeating: "a", count: 64), "", "root"]])
        let legacyReply = try me.event(Self.now - 130, tags: [["e", String(repeating: "b", count: 64)]])
        let mentionOnly = try me.event(Self.now - 120, tags: [["e", String(repeating: "c", count: 64), "", "mention"]])
        r.own = [topLevel, reply, legacyReply, mentionOnly]
        let rig = makeRig(pubkey: me.pubkey, rules: r)
        let p = try other.event(Self.now - 300)
        _ = try await start(rig, page: [p])
        #expect(await eventually { rig.vm.posts.map(\.id) == [mentionOnly.id, topLevel.id, p.id] })
        // A reply published now is not pinned either.
        let published = try me.event(Self.now - 5, tags: [["e", p.id, "", "reply"]])
        rig.center.post(name: .nostrEventPublished, object: nil, userInfo: ["event": published])
        try await Task.sleep(for: .milliseconds(50))
        #expect(!rig.vm.posts.contains { $0.id == published.id })
    }

    @Test("deleted posts are hidden at ingest and when a deletion is recorded, own pinned posts included")
    func deletedPostsHidden() async throws {
        let me = try Author(), other = try Author()
        let r = Rules()
        let deleted = DeletedIds()
        let mine = try me.event(Self.now - 150)
        let gone = try other.event(Self.now - 120)
        deleted.ids = [gone.id]
        r.own = [mine]
        let rig = makeRig(pubkey: me.pubkey, rules: r, deleted: deleted)
        let keep = try other.event(Self.now - 100)
        _ = try await start(rig, page: [keep, gone])
        #expect(await eventually { rig.vm.posts.map(\.id) == [keep.id, mine.id] })

        // The user deletes their own post (DeletionSender records it, then
        // posts .eventDeletionRecorded).
        deleted.ids.insert(mine.id)
        rig.center.post(name: .eventDeletionRecorded, object: nil, userInfo: ["eventIds": [mine.id]])
        #expect(await eventually { rig.vm.posts.map(\.id) == [keep.id] })
    }

    @Test("posts dated more than 30 s ahead are dropped; within the skew they stay")
    func futureDatedDropped() async throws {
        let a = try Author()
        let rig = makeRig()
        let ahead = try a.event(Self.now + 31)
        let within = try a.event(Self.now + 30)
        let past = try a.event(Self.now - 10)
        let (_, tail) = try await start(rig, page: [ahead, within, past])
        #expect(await eventually { rig.vm.posts.map(\.id) == [within.id, past.id] })
        answer(rig.transport, tail, [try a.event(Self.now + 3600)], eose: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.vm.newPostsCount == 0)
    }

    @Test("DeletionSender announces a recorded deletion with the target ids")
    func deletionAnnouncementName() {
        #expect(Notification.Name.eventDeletionRecorded.rawValue == "WispEventDeletionRecorded")
    }

    // MARK: - Review fixes (PR #206)

    @Test("page 1 failed: posts arriving on the tail show the list with the pill, not the error message")
    func failedFirstPageThenTailShowsPill() async throws {
        let a = try Author()
        let rig = makeRig()
        rig.vm.activate()
        let req = try await awaitReq(rig.transport, 1)
        rig.transport.latest?.feed("[\"CLOSED\",\"\(req.subId)\",\"error: down\"]")
        #expect(await eventually { rig.vm.showsFailureMessage })
        let tail = try #require(await eventually { self.reqs(rig.transport.latest).contains(where: Self.isTail) } ? reqs(rig.transport.latest).first(where: Self.isTail) : nil)
        answer(rig.transport, tail, [try a.event(Self.now - 5)], eose: false)
        #expect(await eventually { rig.vm.newPostsCount == 1 })
        #expect(!rig.vm.showsFailureMessage)
        #expect(!rig.vm.showsEmptyMessage)
        #expect(rig.vm.showsNewPostsPill)
    }

    @Test("closing the pill is observed (the overlay updates at once)")
    func dismissIsObserved() async throws {
        let a = try Author()
        let rig = makeRig()
        let (_, tail) = try await start(rig, page: [try a.event(Self.now - 100)])
        answer(rig.transport, tail, [try a.event(Self.now - 5)], eose: false)
        #expect(await eventually { rig.vm.showsNewPostsPill })
        let fired = Fired()
        withObservationTracking { _ = rig.vm.showsNewPostsPill } onChange: { fired.set() }
        rig.vm.dismissNewPostsPill()
        #expect(fired.value, "dismissing must invalidate views reading showsNewPostsPill")
        #expect(!rig.vm.showsNewPostsPill)
    }

    @Test("a refresh that fails after some posts arrived keeps the list and puts those posts behind the pill")
    func partialFailedRefreshGoesToPill() async throws {
        let a = try Author()
        let rig = makeRig()
        let shown = try [a.event(Self.now - 100)]
        _ = try await start(rig, page: shown)
        _ = await eventually { rig.vm.posts.count == 1 }
        async let refresh: Void = rig.vm.refreshAndWait()
        let pageReq = try #require(await eventually { self.reqs(rig.transport.latest).filter { $0.limit == 30 }.count == 2 } ? reqs(rig.transport.latest).filter { $0.limit == 30 }.last : nil)
        let arrived = try a.event(Self.now - 10)
        answer(rig.transport, pageReq, [arrived], eose: false)
        try await Task.sleep(for: .milliseconds(30))
        rig.transport.latest?.feed("[\"CLOSED\",\"\(pageReq.subId)\",\"error: overloaded\"]")
        await refresh
        #expect(rig.vm.posts.map(\.id) == shown.map(\.id))
        #expect(rig.vm.newPostsCount == 1)
        rig.vm.showNewPosts()
        #expect(rig.vm.posts.map(\.id) == [arrived.id] + shown.map(\.id))
    }

    @Test("a failed refresh that keeps the finish line restarts an unfinished recipe load")
    func failedRefreshRestartsRecipes() async throws {
        let a = try Author()
        let rig = makeRig()
        _ = try await start(rig, page: [try a.event(Self.now - 100)])   // short page: end + recipes asked
        _ = await eventually { self.reqs(rig.transport.latest).contains { $0.kinds == [30023] } }
        async let refresh: Void = rig.vm.refreshAndWait()
        let pageReq = try #require(await eventually { self.reqs(rig.transport.latest).filter { $0.limit == 30 }.count == 2 } ? reqs(rig.transport.latest).filter { $0.limit == 30 }.last : nil)
        rig.transport.latest?.feed("[\"CLOSED\",\"\(pageReq.subId)\",\"error: overloaded\"]")
        await refresh
        #expect(rig.vm.finishLine.caughtUp)
        let recipeReqs = await eventually { self.reqs(rig.transport.latest).filter { $0.kinds == [30023] }.count == 2 }
        #expect(recipeReqs, "the recipe row is asked for again")
        let recipe = try a.longForm(Self.now - 40 * Self.day, d: "soup", recipe: true)
        answer(rig.transport, reqs(rig.transport.latest).filter { $0.kinds == [30023] }.last!, [recipe])
        #expect(await eventually { rig.vm.recipePicks.map(\.id) == [recipe.id] })
    }

    @Test("the recipe row drops deleted and far-future recipes, and keeps old edits")
    func recipeRowGuards() async throws {
        let a = try Author()
        let deleted = DeletedIds()
        let rig = makeRig(deleted: deleted)
        _ = try await start(rig, page: [try a.event(Self.now - 100)])
        let recipesReq = try #require(await eventually { self.reqs(rig.transport.latest).contains { $0.kinds == [30023] } } ? reqs(rig.transport.latest).first { $0.kinds == [30023] } : nil)
        let gone = try a.longForm(Self.now - 30 * Self.day, d: "gone", recipe: true)
        let future = try a.longForm(Self.now + 3600, d: "future", recipe: true)
        let oldEdit = try a.longForm(Self.now - 20 * Self.day, d: "classic", publishedAt: Self.now - 900 * Self.day, recipe: true)
        deleted.ids = [gone.id]
        answer(rig.transport, recipesReq, [gone, future, oldEdit])
        #expect(await eventually { rig.vm.recipePicks.map(\.id) == [oldEdit.id] })
    }

    @Test("the optimistic row shows only for kinds Fresh keeps")
    func pendingRowKinds() {
        for kind in [1, 30023, 1068] { #expect(FreshFeedViewModel.showsPendingRow(kind: kind)) }
        for kind in [20, 21, 22, 6] { #expect(!FreshFeedViewModel.showsPendingRow(kind: kind)) }
    }

    // MARK: - #209 follow-ups

    @Test("the recipe row leaves out recipes the feed already shows, by id and by coordinate")
    func recipeRowExcludesFeedRecipes() async throws {
        let a = try Author(), b = try Author()
        let rig = makeRig()
        let inFeed = try a.longForm(Self.now - 100, d: "bisque", recipe: true)
        _ = try await start(rig, page: [inFeed, try b.event(Self.now - 200)])
        let recipesReq = try #require(await eventually { self.reqs(rig.transport.latest).contains { $0.kinds == [30023] } } ? reqs(rig.transport.latest).first { $0.kinds == [30023] } : nil)
        let olderEdit = try a.longForm(Self.now - 30 * Self.day, d: "bisque", recipe: true)   // same coordinate
        let other = try b.longForm(Self.now - 40 * Self.day, d: "bread", recipe: true)
        answer(rig.transport, recipesReq, [inFeed, olderEdit, other])
        #expect(await eventually { rig.vm.recipePicks.map(\.id) == [other.id] })
        #expect(rig.vm.recipePool.count == 2, "the pool keeps one per coordinate; the row filters")
    }
}
