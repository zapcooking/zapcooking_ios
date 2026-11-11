import Foundation
import Testing
@testable import wisp

/// Special cards in the Fresh list (S3): `FreshFeedViewModel` with
/// `specialsEnabled`, driven through the real `FreshRelayClient` on
/// `FakeGroupTransport` (no socket, no relay) with real signed events. Topic
/// previews go over the same fake socket, except where a test scripts
/// them. The topic list is injected (no NIP-11 request); the shown stores
/// live in a throwaway `UserDefaults` suite.
@Suite(.serialized) @MainActor struct FreshSpecialsListTests {
    typealias Base = FreshFeedViewModelTests

    nonisolated static let now = Base.now
    static let day = 86_400

    /// One author per post, so author spacing never reorders the page.
    static func page(_ count: Int, newest: Int = now - 60, step: Int = 600) throws -> [NostrEvent] {
        try (0..<count).map { try Base.Author().event(newest - $0 * step) }
    }

    /// Recipes first published more than 14 days ago (box candidates).
    static func oldRecipes(_ count: Int) throws -> [NostrEvent] {
        try (0..<count).map { i in
            try Base.Author().longForm(now - (20 + i) * day, d: "old-\(i)", recipe: true)
        }
    }

    static let groups: [FreshTopicGroup] = FreshSpotlightLoaderTests.twoGroups

    final class Scripted {
        var previews: [String: [NostrEvent]] = [:]
        var asked: [String] = []
        var topicsAsked = 0
    }

    struct Rig {
        let base: Base.Rig
        let defaults: UserDefaults
        let store: FreshSpecialsStore
        let scripted: Scripted
        let deleted: Base.DeletedIds
        var vm: FreshFeedViewModel { base.vm }
        var transport: FakeGroupTransport { base.transport }
    }

    /// `previewsOverSocket`: topic previews go to the fake relay (answered by
    /// `answerTopics`); otherwise `scripted.previews` answers them.
    func makeRig(enabled: Bool = true, previewsOverSocket: Bool = false,
                 pubkey: String = String(repeating: "c", count: 64),
                 visitStore: Base.Store = Base.Store(),
                 profiles: FreshProfileSource? = nil) -> Rig {
        let transport = FakeGroupTransport()
        let client = FreshRelayClient(
            transport: transport, now: { Self.now }, silenceTimeout: 5,
            notificationCenter: NotificationCenter(),
            foregroundNotification: Notification.Name("FreshSpecialsListTests.fg")
        )
        let rules = Base.Rules()
        let deleted = Base.DeletedIds()
        let defaults = UserDefaults(suiteName: "FreshSpecialsListTests-\(UUID().uuidString)")!
        let store = FreshSpecialsStore(pubkey: pubkey, defaults: defaults)
        let scripted = Scripted()
        let seeded = FreshSpecialsTests.Seeded(11)
        let center = NotificationCenter()
        let vm = FreshFeedViewModel(
            pubkey: pubkey, client: client, now: { Self.now },
            rules: { rules.snapshot },
            isReportedCoordinate: { rules.reportedCoordinates.contains($0) },
            isPrivate: { _ in false },
            isDeleted: { deleted.ids.contains($0.id) },
            ownLocalPosts: { [] },
            persist: { _ in },
            visitStorage: visitStore, lastVisit: FreshLastVisit(),
            notificationCenter: center, retryDelays: [.milliseconds(30)],
            profileSource: profiles ?? Base.NoProfiles(),
            specialsEnabled: enabled,
            specialsStore: store,
            specialsRng: seeded.rng,
            topicGroups: { scripted.topicsAsked += 1; return Self.groups },
            topicPreview: previewsOverSocket ? nil : { slug in
                scripted.asked.append(slug)
                return FreshAnswer(events: scripted.previews[slug] ?? [], outcome: .answered)
            },
            specialsSchedule: { _, _ in {} }
        )
        let base = Base.Rig(transport: transport, vm: vm, center: center, rules: rules, store: visitStore)
        return Rig(base: base, defaults: defaults, store: store, scripted: scripted, deleted: deleted)
    }

    let t = Base()

    func reqs(_ rig: Rig) -> [Base.Req] { t.reqs(rig.transport.latest) }

    static func isRecipes(_ r: Base.Req) -> Bool { r.tTags != nil }
    static func isTopic(_ r: Base.Req) -> Bool { (r.filter["search"] as? String)?.hasPrefix("topic:") == true }

    /// Page 1, then the recipe download (answered with `recipes`).
    func start(_ rig: Rig, page: [NostrEvent], recipes: [NostrEvent]) async throws {
        _ = try await t.start(rig.base, page: page)
        let found = await t.eventually { self.reqs(rig).contains(where: Self.isRecipes) }
        try #require(found, "recipe REQ never sent")
        t.answer(rig.transport, reqs(rig).first(where: Self.isRecipes)!, recipes)
        _ = await t.eventually { !rig.vm.placedSlots.isEmpty }
    }

    func cards(_ vm: FreshFeedViewModel) -> [(after: String, special: FreshSpecial)] {
        var out: [(String, FreshSpecial)] = []
        var lastPost: String?
        for row in vm.rows {
            guard case .row(let r) = row else { continue }
            if let e = r.event { lastPost = e.id }
            if let s = r.special, let lastPost { out.append((lastPost, s)) }
        }
        return out
    }

    /// The reader's list showed the post at `position` (what `onAppear` does).
    func scroll(_ vm: FreshFeedViewModel, to position: Int) {
        let target = vm.posts[min(position, vm.posts.count - 1)].id
        if let i = vm.rows.firstIndex(where: { if case .row(let r) = $0 { return r.event?.id == target }; return false }) {
            vm.postAppeared(rowIndex: i)
        }
    }

    static func spotlightPosts(_ s: FreshSpecial) -> [NostrEvent] {
        if case .spotlight(_, let ps) = s { return ps }
        return []
    }

    // MARK: - Flag off

    @Test("flag off: no slots, no topic list, no preview, no early recipe download; rows are the posts")
    func flagOffIsUnchanged() async throws {
        let rig = makeRig(enabled: false)
        let page = try Self.page(FreshRelayClient.pageSize)
        _ = try await t.start(rig.base, page: page)
        _ = await t.eventually { rig.vm.posts.count == page.count }
        for p in stride(from: 0, to: page.count, by: 3) { scroll(rig.vm, to: p) }
        #expect(rig.vm.placedSlots.isEmpty)
        #expect(rig.vm.rows.count == page.count)
        #expect(rig.vm.rows.allSatisfy { if case .row(let r) = $0 { return !r.isSpecialCard }; return true })
        #expect(rig.scripted.topicsAsked == 0)
        #expect(rig.scripted.asked.isEmpty)
        #expect(!reqs(rig).contains(where: Self.isRecipes), "a full page 1 asks for no recipes with the flag off")
        #expect(!reqs(rig).contains(where: Self.isTopic))
    }

    // MARK: - Placement

    @Test("a recipe-box card after post 5–7, then a spotlight 7–9 posts later; no frame starts with [\"AUTH\"")
    func placesRecipeThenSpotlight() async throws {
        let rig = makeRig(previewsOverSocket: true)
        let page = try Self.page(FreshRelayClient.pageSize)
        let recipes = try Self.oldRecipes(6)
        try await start(rig, page: page, recipes: recipes)

        // The first slot: a recipe from the box, after post 5, 6 or 7.
        var placed = cards(rig.vm)
        try #require(placed.count == 1)
        guard case .recipe(let recipe) = placed[0].special else {
            Issue.record("first card is not a recipe")
            return
        }
        #expect(recipes.map(\.id).contains(recipe.id))
        let firstAt = try #require(rig.vm.posts.firstIndex { $0.id == placed[0].after })
        #expect((4...6).contains(firstAt))

        // The relay answers the spotlight's topic preview, through an AUTH
        // challenge, with three posts from three authors.
        let topicReq = try #require(await t.eventually { self.reqs(rig).contains(where: Self.isTopic) }
                                    ? reqs(rig).first(where: Self.isTopic) : nil)
        rig.transport.latest?.feed("[\"AUTH\",\"challenge\"]")
        let spot = try Self.page(3, newest: Self.now - 3_000, step: 60)
        t.answer(rig.transport, topicReq, spot)
        _ = await t.eventually { rig.vm.placedSlots.count >= 1 }

        // The reader scrolls past the first card: the next slot comes within reach.
        scroll(rig.vm, to: firstAt + 2)
        _ = await t.eventually { self.cards(rig.vm).count == 2 }
        placed = cards(rig.vm)
        try #require(placed.count == 2)
        #expect(Set(Self.spotlightPosts(placed[1].special).map(\.id)) == Set(spot.map(\.id)))
        let secondAt = try #require(rig.vm.posts.firstIndex { $0.id == placed[1].after })
        #expect((7...9).contains(secondAt - firstAt))

        for frame in rig.transport.opened.flatMap(\.sent) {
            #expect(frame.hasPrefix("[\"REQ\"") || frame.hasPrefix("[\"CLOSE\""), "sent \(frame)")
        }
    }

    @Test("with no topic list (or nothing to fill a spotlight), the next slot goes to a recipe-box card too")
    func noSpotlightMeansRecipe() async throws {
        let rig = makeRig()  // scripted previews: every topic empty → thin
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: try Self.oldRecipes(6))
        await rig.vm.prepareSpotlightAndWait()
        let firstAt = rig.vm.posts.firstIndex { $0.id == cards(rig.vm).first?.after } ?? 0
        scroll(rig.vm, to: firstAt + 6)
        _ = await t.eventually { self.cards(rig.vm).count == 2 }
        let types = cards(rig.vm).map { $0.special.type }
        #expect(types.count >= 2)
        #expect(types.allSatisfy { $0 == .recipe }, "\(types)")
    }

    @Test("a slot whose anchor the reader already reached is skipped, never filled above them")
    func reachedSlotIsSkipped() async throws {
        let rig = makeRig()
        let page = try Self.page(FreshRelayClient.pageSize)
        _ = try await t.start(rig.base, page: page)
        _ = await t.eventually { rig.vm.posts.count == page.count }
        // The reader is at post 10 before any recipe or spotlight is ready.
        scroll(rig.vm, to: 10)
        // Recipes arrive now: the first slot (5–7) is behind the reader.
        let recipesReq = try #require(await t.eventually { self.reqs(rig).contains(where: Self.isRecipes) }
                                      ? reqs(rig).first(where: Self.isRecipes) : nil)
        t.answer(rig.transport, recipesReq, try Self.oldRecipes(6))
        _ = await t.eventually { !rig.vm.placedSlots.isEmpty }
        let first = try #require(rig.vm.placedSlots.first)
        #expect(first.special == nil)
        let at = try #require(rig.vm.posts.firstIndex { $0.id == first.anchorId })
        #expect(at <= 10)
    }

    // MARK: - Pill, divider, paging

    @Test("pill: new posts go on top; cards stay after their anchor posts and the next slot keeps its spacing")
    func pillKeepsCardsAttached() async throws {
        let rig = makeRig()
        let spot = try Self.page(3, newest: Self.now - 4_000, step: 30)
        for topic in Self.groups.flatMap(\.topics) { rig.scripted.previews[topic.slug] = spot }
        let page = try Self.page(FreshRelayClient.pageSize)
        try await start(rig, page: page, recipes: try Self.oldRecipes(6))
        let before = cards(rig.vm)
        try #require(before.count == 1)
        let tail = try #require(reqs(rig).first(where: Base.isTail))
        let fresh = try Self.page(4, newest: Self.now - 5, step: 1)
        t.answer(rig.transport, tail, fresh, eose: false)
        await t.reveal(rig.base, count: 4)
        #expect(Array(rig.vm.posts.prefix(4)).map(\.id) == fresh.map(\.id))
        let after = cards(rig.vm)
        #expect(after.map { $0.after } == before.map { $0.after })
        #expect(after.map { $0.special } == before.map { $0.special })
        // The next slot is measured from the card above, not from the top.
        let firstAt = try #require(rig.vm.posts.firstIndex { $0.id == after[0].after })
        await rig.vm.prepareSpotlightAndWait()
        scroll(rig.vm, to: firstAt + 2)
        _ = await t.eventually { self.cards(rig.vm).count == 2 }
        let secondAt = try #require(rig.vm.posts.firstIndex { $0.id == self.cards(rig.vm).last?.after })
        #expect((7...9).contains(secondAt - firstAt))
    }

    @Test("divider: its count is posts only, with cards above it")
    func dividerCountsPostsOnly() async throws {
        let visit = Base.Store()
        let pubkey = String(repeating: "d", count: 64)
        // The last visit was before the 12th post: 11 posts are new.
        let page = try Self.page(FreshRelayClient.pageSize)
        visit.data[FreshLastVisit.key(pubkey: pubkey)] = String(page[11].createdAt)
        let rig = makeRig(pubkey: pubkey, visitStore: visit)
        try await start(rig, page: page, recipes: try Self.oldRecipes(6))
        #expect(cards(rig.vm).count == 1)
        let divider = rig.vm.rows.compactMap { row -> Int? in
            if case .divider(let n) = row { return n }
            return nil
        }
        #expect(divider == [11])
        // The divider sits right before the first post already seen.
        let at = try #require(rig.vm.rows.firstIndex { $0.isDivider })
        if case .row(let next) = rig.vm.rows[at + 1] {
            #expect(next.event?.id == page[11].id)
        } else {
            Issue.record("no post after the divider")
        }
    }

    @Test("paging: a post row's position counts posts, not the cards above it")
    func pagingCountsPostsWithCards() async throws {
        let rig = makeRig()
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: try Self.oldRecipes(6))
        try #require(!cards(rig.vm).isEmpty)
        let rows = rig.vm.rows
        for (i, row) in rows.enumerated() {
            guard case .row(let r) = row, let e = r.event else {
                #expect(FreshFeedViewModel.postPosition(ofRow: i, in: rows) == nil)
                continue
            }
            #expect(FreshFeedViewModel.postPosition(ofRow: i, in: rows) == rig.vm.posts.firstIndex { $0.id == e.id })
        }
        // The prefetch threshold (`loadMorePrefetch` = 6): the 6th post from
        // the end pages; the 7th doesn't, cards above or not.
        let pagesBefore = reqs(rig).filter { $0.limit == FreshRelayClient.pageSize }.count
        scroll(rig.vm, to: rig.vm.posts.count - 7)
        #expect(reqs(rig).filter { $0.limit == FreshRelayClient.pageSize }.count == pagesBefore)
        scroll(rig.vm, to: rig.vm.posts.count - 6)
        #expect(await t.eventually { self.reqs(rig).filter { $0.limit == FreshRelayClient.pageSize }.count == pagesBefore + 1 })
    }

    // MARK: - Hiding

    @Test("Report / Block on a spotlight post: that post leaves the card at once; the last one takes the card")
    func hidingUpdatesTheSpotlight() async throws {
        let rig = makeRig()
        let spot = try Self.page(3, newest: Self.now - 3_000, step: 60)
        for topic in Self.groups.flatMap(\.topics) { rig.scripted.previews[topic.slug] = spot }
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: try Self.oldRecipes(6))
        await rig.vm.prepareSpotlightAndWait()
        let firstAt = rig.vm.posts.firstIndex { $0.id == cards(rig.vm).first?.after } ?? 0
        scroll(rig.vm, to: firstAt + 2)
        _ = await t.eventually { self.cards(rig.vm).count == 2 }
        try #require(cards(rig.vm).count == 2)

        // Report (by id) and Block (by author) both arrive as `.contentHidden`.
        rig.base.center.post(name: .contentHidden, object: nil, userInfo: [ContentHideKey.eventIds: [spot[0].id]])
        #expect(await t.eventually { Self.spotlightPosts(self.cards(rig.vm)[1].special).map(\.id) == [spot[1].id, spot[2].id] })
        rig.base.center.post(name: .contentHidden, object: nil, userInfo: [ContentHideKey.pubkeys: [spot[1].pubkey]])
        #expect(await t.eventually { Self.spotlightPosts(self.cards(rig.vm)[1].special).map(\.id) == [spot[2].id] })
        rig.base.center.post(name: .contentHidden, object: nil, userInfo: [ContentHideKey.eventIds: [spot[2].id]])
        #expect(await t.eventually { self.cards(rig.vm).count == 1 }, "the emptied spotlight is gone")
    }

    @Test("blocking a box recipe's author removes the card; blocking an anchor's author moves the card up one post")
    func hidingRecipeAndAnchor() async throws {
        let rig = makeRig()
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: try Self.oldRecipes(6))
        let card = try #require(cards(rig.vm).first)
        let anchorAt = try #require(rig.vm.posts.firstIndex { $0.id == card.after })
        let above = rig.vm.posts[anchorAt - 1].id
        let anchorAuthor = rig.vm.posts[anchorAt].pubkey
        rig.vm.dropHidden(eventIds: [], pubkeys: [anchorAuthor], coordinates: [])
        #expect(cards(rig.vm).first?.after == above)
        #expect(cards(rig.vm).first?.special == card.special)

        guard case .recipe(let recipe) = card.special else { Issue.record("not a recipe"); return }
        rig.vm.dropHidden(eventIds: [], pubkeys: [recipe.pubkey], coordinates: [])
        #expect(cards(rig.vm).isEmpty)
    }

    @Test("deletion: a deleted spotlight post leaves the card, a deleted anchor moves its card up")
    func deletionUpdatesCards() async throws {
        let rig = makeRig()
        let spot = try Self.page(3, newest: Self.now - 3_000, step: 60)
        for topic in Self.groups.flatMap(\.topics) { rig.scripted.previews[topic.slug] = spot }
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: try Self.oldRecipes(6))
        await rig.vm.prepareSpotlightAndWait()
        let firstAt = rig.vm.posts.firstIndex { $0.id == cards(rig.vm).first?.after } ?? 0
        scroll(rig.vm, to: firstAt + 2)
        _ = await t.eventually { self.cards(rig.vm).count == 2 }
        try #require(cards(rig.vm).count == 2)
        let anchor = cards(rig.vm)[0].after
        let anchorAt = try #require(rig.vm.posts.firstIndex { $0.id == anchor })
        rig.deleted.ids = [spot[1].id, anchor]
        rig.vm.dropDeleted()
        #expect(Self.spotlightPosts(cards(rig.vm)[1].special).map(\.id) == [spot[0].id, spot[2].id])
        #expect(cards(rig.vm)[0].after == rig.vm.posts[anchorAt - 1].id)
    }

    // MARK: - Refresh

    @Test("refresh: new slots for the new page, taken recipes go back, the used topics carry on")
    func refreshResetsSlots() async throws {
        let rig = makeRig()
        let spot = try Self.page(3, newest: Self.now - 3_000, step: 60)
        for topic in Self.groups.flatMap(\.topics) { rig.scripted.previews[topic.slug] = spot }
        let page = try Self.page(FreshRelayClient.pageSize)
        try await start(rig, page: page, recipes: try Self.oldRecipes(6))
        await rig.vm.prepareSpotlightAndWait()
        #expect(!rig.vm.boxTaken.isEmpty)
        let usedBefore = rig.vm.spotlightUsedTopics
        #expect(!usedBefore.isEmpty)

        async let refresh: Void = rig.vm.refreshAndWait()
        let ok = await t.eventually { self.reqs(rig).filter { $0.limit == FreshRelayClient.pageSize && $0.until == nil }.count == 2 }
        try #require(ok)
        let pageReq = reqs(rig).filter { $0.limit == FreshRelayClient.pageSize && $0.until == nil }.last!
        // The refresh briefly holds no slots: the new page brings its own.
        t.answer(rig.transport, pageReq, page)
        await refresh
        #expect(rig.vm.placedSlots.allSatisfy { slot in rig.vm.posts.contains { $0.id == slot.anchorId } })
        // The session carries on: topics used before the refresh stay used.
        #expect(rig.vm.spotlightUsedTopics.isSuperset(of: usedBefore))
        #expect(!rig.vm.placedSlots.isEmpty)
    }

    // MARK: - Recipe box and the recipe row

    @Test("the box card and the finish-line row never show the same recipe")
    func boxAndRowExcludeEachOther() async throws {
        let rig = makeRig()
        let recipes = try Self.oldRecipes(3)
        // A short page: the finish line (and its row) come with page 1.
        try await start(rig, page: try Self.page(12), recipes: recipes)
        let card = try #require(cards(rig.vm).first)
        guard case .recipe(let boxed) = card.special else { Issue.record("not a recipe"); return }
        #expect(rig.vm.finishLine.recipeRow)
        #expect(!rig.vm.recipePicks.contains { $0.id == boxed.id })
        #expect(rig.vm.recipePicks.count == 2)
    }

    @Test("a card that appears is recorded: the box recipe as seen; the spotlight's posts and topic as shown")
    func appearanceIsRecorded() async throws {
        let rig = makeRig()
        let spot = try Self.page(3, newest: Self.now - 3_000, step: 60)
        for topic in Self.groups.flatMap(\.topics) { rig.scripted.previews[topic.slug] = spot }
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: try Self.oldRecipes(6))
        await rig.vm.prepareSpotlightAndWait()
        let firstAt = rig.vm.posts.firstIndex { $0.id == cards(rig.vm).first?.after } ?? 0
        scroll(rig.vm, to: firstAt + 2)
        _ = await t.eventually { self.cards(rig.vm).count == 2 }
        for slot in rig.vm.placedSlots where slot.special != nil { rig.vm.cardAppeared(key: slot.key) }

        guard case .recipe(let recipe) = cards(rig.vm)[0].special,
              case .spotlight(let topic, let posts) = cards(rig.vm)[1].special else {
            Issue.record("expected recipe then spotlight")
            return
        }
        #expect(rig.store.loadRecipeBoxSeen(now: Self.now)[FreshRecipeBox.address(recipe)] == Self.now)
        #expect(Set(rig.store.loadShown(now: Self.now).keys) == Set(posts.map(\.id)))
        #expect(rig.store.loadTopicHistory()[topic.slug] == Self.now)
    }

    @Test("a spotlight never repeats a post already in the feed")
    func spotlightSkipsFeedPosts() async throws {
        let rig = makeRig()
        let page = try Self.page(FreshRelayClient.pageSize)
        let extra = try Self.page(2, newest: Self.now - 5_000, step: 60)
        // Every preview: two posts already in the feed plus two new ones (thin).
        for topic in Self.groups.flatMap(\.topics) { rig.scripted.previews[topic.slug] = [page[0], page[1]] + extra }
        try await start(rig, page: page, recipes: try Self.oldRecipes(6))
        await rig.vm.prepareSpotlightAndWait()
        let firstAt = rig.vm.posts.firstIndex { $0.id == cards(rig.vm).first?.after } ?? 0
        scroll(rig.vm, to: firstAt + 6)
        _ = await t.eventually { self.cards(rig.vm).count == 2 }
        #expect(cards(rig.vm).allSatisfy { $0.special.type == .recipe })
    }

    // MARK: - Device-pass fixes (2026-11-11)

    /// A profile source the test drives: a cache, a record of what was asked
    /// for, and the updates stream (a profile arriving later).
    final class Profiles: FreshProfileSource {
        var cache: [String: ProfileData] = [:]
        var observed: [String] = []
        let stream: AsyncStream<String>
        let continuation: AsyncStream<String>.Continuation
        init() { (stream, continuation) = AsyncStream<String>.makeStream() }
        func cached(_ pubkey: String) -> ProfileData? { cache[pubkey] }
        func observe(_ events: [NostrEvent]) { observed += events.flatMap(\.referencedAuthorPubkeys) }
        func updates() -> AsyncStream<String> { stream }
        func arrive(_ pubkey: String, name: String) {
            cache[pubkey] = ProfileData(pubkey: pubkey, json: ["display_name": name])
            continuation.yield(pubkey)
        }
    }

    static func hex(_ s: String) -> [UInt8] { Hex.decode(s).map { Array($0) } ?? [] }

    @Test("tile text: profile mentions read @name (short npub until known); note, event and address references and links are dropped")
    func tileTextRendersMentions() throws {
        let named = try Base.Author(), unnamed = try Base.Author(), quoted = try Base.Author()
        let npub = try #require(Nip19.npubEncode(pubkey: Self.hex(named.pubkey)))
        let nprofile = try #require(Nip19.nprofileEncode(pubkey32: Self.hex(unnamed.pubkey), relays: ["wss://relay.example"]))
        let note = try quoted.event(Self.now - 500)
        let noteRef = try #require(Nip19.noteEncode(eventId: Self.hex(note.id)))
        let neventRef = try #require(Nip19.neventEncode(eventId32: Self.hex(note.id), author32: Self.hex(quoted.pubkey)))
        let naddrRef = try #require(Nip19.naddrEncode(kind: 30023, pubkeyHex: quoted.pubkey, dTag: "pie"))
        let post = try Base.Author().event(Self.now - 100, content:
            "Bread with nostr:\(npub) and nostr:\(nprofile) today nostr:\(noteRef)\nsee nostr:\(neventRef) nostr:\(naddrRef) https://img.example/loaf.jpg #sourdough")
        let profiles = [named.pubkey: ProfileData(pubkey: named.pubkey, json: ["display_name": "Theo  "])]
        let text = FreshSpotlightTile.plainText(post, profiles: profiles)
        #expect(text == "Bread with @Theo and @\(Nip19.shortNpub(hex: unnamed.pubkey)) today see #sourdough")
        #expect(!text.contains("nostr:"))
    }

    @Test("a prepared spotlight asks for its authors' and mentioned people's profiles before it is placed; cached ones show at once")
    func spotlightRequestsProfiles() async throws {
        let source = Profiles()
        let rig = makeRig(profiles: source)
        let mentioned = try Base.Author()
        let npub = try #require(Nip19.npubEncode(pubkey: Self.hex(mentioned.pubkey)))
        var spot = try Self.page(3, newest: Self.now - 3_000, step: 60)
        spot[0] = try Base.Author().event(Self.now - 2_900, content: "Crumb shot for nostr:\(npub)")
        source.cache[spot[1].pubkey] = ProfileData(pubkey: spot[1].pubkey, json: ["display_name": "Cached Cook"])
        for topic in Self.groups.flatMap(\.topics) { rig.scripted.previews[topic.slug] = spot }
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: try Self.oldRecipes(6))
        await rig.vm.prepareSpotlightAndWait()
        // Not placed yet (the slot is out of reach), but already asked for.
        #expect(cards(rig.vm).count == 1)
        let wanted = Set(spot.map(\.pubkey) + [mentioned.pubkey])
        #expect(wanted.isSubset(of: Set(source.observed)))
        #expect(rig.vm.profiles[spot[1].pubkey]?.displayString == "Cached Cook")
    }

    @Test("a tile whose profiles arrive after it is on screen updates: author name and mention resolve")
    func lateProfilesReachTheTile() async throws {
        let source = Profiles()
        let rig = makeRig(profiles: source)
        let mentioned = try Base.Author()
        let npub = try #require(Nip19.npubEncode(pubkey: Self.hex(mentioned.pubkey)))
        var spot = try Self.page(3, newest: Self.now - 3_000, step: 60)
        spot[0] = try Base.Author().event(Self.now - 2_900, content: "Ask nostr:\(npub) about the levain")
        for topic in Self.groups.flatMap(\.topics) { rig.scripted.previews[topic.slug] = spot }
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: try Self.oldRecipes(6))
        await rig.vm.prepareSpotlightAndWait()
        let firstAt = rig.vm.posts.firstIndex { $0.id == cards(rig.vm).first?.after } ?? 0
        scroll(rig.vm, to: firstAt + 2)
        _ = await t.eventually { self.cards(rig.vm).count == 2 }
        let card = try #require(cards(rig.vm).last)
        let posts = Self.spotlightPosts(card.special)
        let tilePost = try #require(posts.first { $0.id == spot[0].id })
        rig.vm.cardAppeared(key: rig.vm.placedSlots.last!.key)
        // On screen with nothing known: short npub for the mention, no author name.
        #expect(rig.vm.profiles[tilePost.pubkey] == nil)
        #expect(FreshSpotlightTile.plainText(tilePost, profiles: rig.vm.profiles)
                == "Ask @\(Nip19.shortNpub(hex: mentioned.pubkey)) about the levain")
        // The profiles arrive.
        source.arrive(tilePost.pubkey, name: "Theo Brandt")
        source.arrive(mentioned.pubkey, name: "June Okafor")
        #expect(await t.eventually { rig.vm.profiles[tilePost.pubkey]?.displayString == "Theo Brandt" })
        #expect(await t.eventually { rig.vm.profiles[mentioned.pubkey] != nil })
        #expect(FreshSpotlightTile.plainText(tilePost, profiles: rig.vm.profiles) == "Ask @June Okafor about the levain")
    }

    @Test("an article tagged zapcooking (no recipe template) never becomes a recipe-box card")
    func boxSkipsTaggedArticles() async throws {
        let rig = makeRig()
        let article = try Base.Author().event(Self.now - 30 * Self.day, kind: 30023,
                                              content: "Arkade.Money and ZapCooking, now running Branta.",
                                              tags: [["d", "branta"], ["t", "zapcooking"]])
        let recipe = try Self.oldRecipes(1)
        try await start(rig, page: try Self.page(FreshRelayClient.pageSize), recipes: [article] + recipe)
        let card = try #require(cards(rig.vm).first)
        guard case .recipe(let boxed) = card.special else { Issue.record("not a recipe"); return }
        #expect(boxed.id == recipe[0].id)
        // Its pool is used up: the next slot can't take the article either.
        let firstAt = rig.vm.posts.firstIndex { $0.id == card.after } ?? 0
        scroll(rig.vm, to: firstAt + 6)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!cards(rig.vm).contains { if case .recipe(let e) = $0.special { return e.id == article.id }; return false })
    }
}
