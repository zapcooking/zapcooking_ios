import Foundation
import Testing
@testable import wisp

/// Smallest body that passes `RecipeParser.validateMarkdownTemplate`.
private let bookmarkTestRecipeBody = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."

/// Pure-function gate for the cold-cache first-write guard (the bookmark
/// overwrite hazard). Port of Android `RecipeBookmarkRepositoryTest`.
@MainActor
struct RecipeBookmarkRepositoryTests {

    private let author = String(repeating: "bb", count: 32)
    private var coordA: String { "30023:\(author):tuscan-peposo" }
    private var coordB: String { "30023:\(author):shakshuka" }
    private var coordC: String { "30023:\(author):meatloaf" }

    private func listEvent(
        tags: [[String]],
        content: String = "",
        createdAt: Int = 1_700_000_000,
        id: String = String(repeating: "aa", count: 32)
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: author,
            kind: RecipeBookmarkRepository.listKind,
            createdAt: createdAt,
            tags: tags,
            content: content,
            sig: String(repeating: "0", count: 128)
        )
    }

    // MARK: - classifyRelayListCheck

    @Test func classify_streamedEventWinsRegardlessOfEose() {
        let event = listEvent(tags: [["d", RecipeBookmarkRepository.defaultListDTag]])
        #expect(RecipeBookmarkRepository.classifyRelayListCheck(newest: event, eoseCount: 0) == .found(event))
        #expect(RecipeBookmarkRepository.classifyRelayListCheck(newest: event, eoseCount: 3) == .found(event))
    }

    @Test func classify_absenceIsOnlyConfirmedByAtLeastOneEose() {
        #expect(RecipeBookmarkRepository.classifyRelayListCheck(newest: nil, eoseCount: 1) == .confirmedAbsent)
        #expect(RecipeBookmarkRepository.classifyRelayListCheck(newest: nil, eoseCount: 5) == .confirmedAbsent)
    }

    @Test func classify_noEventAndNoEoseIsUnconfirmed() {
        #expect(RecipeBookmarkRepository.classifyRelayListCheck(newest: nil, eoseCount: 0) == .unconfirmed)
    }

    // MARK: - cold cache, list exists on relays

    @Test func coldSave_relayVersionBecomesBase_savedItemAppended_neverCreates() {
        let relayList = listEvent(
            tags: [
                ["d", RecipeBookmarkRepository.defaultListDTag],
                ["title", "Saved"],
                ["summary", "my keepers"],
                ["image", "https://example.com/cover.jpg"],
                ["client", "Zap Cooking Web"],
                ["a", coordA],
                ["a", coordB],
            ],
            content: "web content"
        )
        let plan = RecipeBookmarkRepository.planMutation(
            base: relayList,
            absenceConfirmed: false,
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordC,
            desired: nil,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle
        )
        guard case .publish(let tags, let content, let membership) = plan else {
            Issue.record("expected publish, got \(plan)")
            return
        }
        #expect(tags == [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", "Saved"],
            ["summary", "my keepers"],
            ["image", "https://example.com/cover.jpg"],
            ["a", coordA],
            ["a", coordB],
            ["a", coordC],
        ])
        #expect(content == "web content")
        #expect(membership == true)
    }

    // MARK: - cold cache, relay-confirmed absent

    @Test func coldSave_confirmedAbsent_createsFreshSeededList() {
        let plan = RecipeBookmarkRepository.planMutation(
            base: nil,
            absenceConfirmed: true,
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordA,
            desired: nil,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle
        )
        guard case .publish(let tags, let content, let membership) = plan else {
            Issue.record("expected publish, got \(plan)")
            return
        }
        #expect(tags == [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", RecipeBookmarkRepository.defaultListTitle],
            ["a", coordA],
        ])
        #expect(content == "")
        #expect(membership == true)
    }

    @Test func coldSave_confirmedAbsent_namedCollectionGetsRecipeTTag() {
        let plan = RecipeBookmarkRepository.planMutation(
            base: nil,
            absenceConfirmed: true,
            dTag: "weeknight",
            coord: coordA,
            desired: nil,
            seedTitleIfNew: nil
        )
        guard case .publish(let tags, _, _) = plan else {
            Issue.record("expected publish, got \(plan)")
            return
        }
        #expect(tags == [
            ["d", "weeknight"],
            ["title", "weeknight"],
            ["t", RecipeBookmarkRepository.collectionTag],
            ["a", coordA],
        ])
    }

    // MARK: - cold cache, unconfirmed → rejected

    @Test func coldSave_unconfirmed_isRejected_nothingPublishable() {
        let plan = RecipeBookmarkRepository.planMutation(
            base: nil,
            absenceConfirmed: false,
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordA,
            desired: nil,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle
        )
        #expect(plan == .rejectedUnconfirmed)
    }

    @Test func coldRemove_unconfirmed_isAlsoRejected() {
        let plan = RecipeBookmarkRepository.planMutation(
            base: nil,
            absenceConfirmed: false,
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordA,
            desired: false,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle
        )
        #expect(plan == .rejectedUnconfirmed)
    }

    // MARK: - warm path

    @Test func warmToggle_carryForwardBehaviorUnchanged() {
        let base = listEvent(
            tags: [
                ["d", "soups"],
                ["title", "Soups"],
                ["t", "zapcooking"],
                ["a", coordA],
                ["a", coordB],
            ]
        )
        let plan = RecipeBookmarkRepository.planMutation(
            base: base,
            absenceConfirmed: false,
            dTag: "soups",
            coord: coordA,
            desired: nil,
            seedTitleIfNew: nil
        )
        guard case .publish(let tags, _, let membership) = plan else {
            Issue.record("expected publish, got \(plan)")
            return
        }
        #expect(tags == [
            ["d", "soups"],
            ["title", "Soups"],
            ["t", "zapcooking"],
            ["a", coordB],
        ])
        #expect(membership == false)
    }

    @Test func warmMutation_noOpWhenDesiredStateAlreadyHolds() {
        let base = listEvent(
            tags: [
                ["d", RecipeBookmarkRepository.defaultListDTag],
                ["title", "Saved"],
                ["a", coordA],
            ]
        )
        #expect(
            RecipeBookmarkRepository.planMutation(
                base: base,
                absenceConfirmed: false,
                dTag: RecipeBookmarkRepository.defaultListDTag,
                coord: coordA,
                desired: true,
                seedTitleIfNew: nil
            ) == .noOp(membership: true)
        )
        #expect(
            RecipeBookmarkRepository.planMutation(
                base: base,
                absenceConfirmed: false,
                dTag: RecipeBookmarkRepository.defaultListDTag,
                coord: coordB,
                desired: false,
                seedTitleIfNew: nil
            ) == .noOp(membership: false)
        )
    }

    // MARK: - mutateList uses the planner (nothing signed on reject)

    @Test func mutateList_unconfirmedColdSave_signsNothing() async {
        let probe = Probe()
        probe.confirm = .unconfirmed
        let repo = RecipeBookmarkRepository(env: probe.env)
        let kp = try! makeKeypair()
        let added = await repo.mutateList(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordA,
            desired: true,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle,
            keypair: kp
        )
        #expect(added == false)
        #expect(probe.signed.isEmpty)
        #expect(probe.published.isEmpty)
        #expect(repo.lastWriteError == RecipeBookmarkRepository.writeUnconfirmedMessage)
    }

    @Test func mutateList_confirmedAbsent_publishesFreshList() async {
        let probe = Probe()
        probe.confirm = .confirmedAbsent
        let repo = RecipeBookmarkRepository(env: probe.env)
        let kp = try! makeKeypair()
        let added = await repo.mutateList(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordA,
            desired: true,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle,
            keypair: kp
        )
        #expect(added == true)
        #expect(probe.signed.count == 1)
        #expect(probe.published.count == 1)
        #expect(probe.signed.first?.tags.contains(["a", coordA]) == true)
        #expect(probe.signed.first?.tags.contains(where: { $0.first == "t" }) == false)
        #expect(repo.lastWriteError == nil)
    }

    /// The 1.3.5 overwrite: a cold session whose first save ran before the
    /// remote list loaded published a one-item replaceable event and
    /// superseded the user's real collection. An empty-remote create passes
    /// without proving the fix — this case is the one that lost data.
    @Test func mutateList_coldSession_populatedRemote_firstSaveAppends() async {
        let remote = listEvent(
            tags: [
                ["d", RecipeBookmarkRepository.defaultListDTag],
                ["title", "Saved"],
                ["summary", "my keepers"],
                ["image", "https://example.com/cover.jpg"],
                ["client", "Zap Cooking Web"],
                ["a", coordA],
                ["a", coordB],
            ],
            content: "web content",
            createdAt: 1_700_000_000
        )
        let probe = Probe()
        probe.confirm = .found(remote)
        #expect(probe.cached.isEmpty, "cold session: on-device cache must be empty")
        let repo = RecipeBookmarkRepository(env: probe.env)
        #expect(repo.lists.isEmpty)
        #expect(repo.bookmarkedCoordinates.isEmpty)

        let kp = try! makeKeypair()
        let added = await repo.mutateList(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordC,
            desired: true,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle,
            keypair: kp
        )

        #expect(added == true)
        #expect(probe.signed.count == 1)
        #expect(probe.published.count == 1)
        let tags = probe.signed[0].tags
        let publishedCoords = tags.compactMap { $0.count >= 2 && $0[0] == "a" ? $0[1] : nil }
        #expect(publishedCoords == [coordA, coordB, coordC])
        #expect(publishedCoords != [coordC], "first save must not replace the remote collection")
        #expect(tags.contains(["d", RecipeBookmarkRepository.defaultListDTag]))
        #expect(tags.contains(["title", "Saved"]))
        #expect(tags.contains(["summary", "my keepers"]))
        #expect(tags.contains(["image", "https://example.com/cover.jpg"]))
        #expect(!tags.contains(where: { $0.first == "client" }))
        #expect(!tags.contains(where: { $0.first == "t" }))
        #expect(probe.signed[0].content == "web content")
        #expect(repo.bookmarkedCoordinates == Set([coordA, coordB, coordC]))
        #expect(repo.lastWriteError == nil)
    }

    @Test func defaultList_neverCarriesARecipeTTag() {
        let base = listEvent(
            tags: [
                ["d", RecipeBookmarkRepository.defaultListDTag],
                ["title", "Saved"],
                ["t", "zapcooking"],
                ["a", coordA],
            ]
        )
        let plan = RecipeBookmarkRepository.planMutation(
            base: base,
            absenceConfirmed: false,
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordB,
            desired: true,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle
        )
        guard case .publish(let tags, _, _) = plan else {
            Issue.record("expected publish")
            return
        }
        #expect(!tags.contains(where: { $0.first == "t" }))
    }

    // MARK: - HiddenRecipes inherited via RecipeRepository

    /// A coordinate on the hide list can still sit in the NIP-51 set (the
    /// user saved it, or another client did). Rendering goes through
    /// `RecipeRepository`, which already drops HiddenRecipes — verify that
    /// path rather than assume it.
    @Test func resolvedRecipes_dropsAHiddenSavedCoordinate() async throws {
        let hiddenCoord = try #require(HiddenRecipes.coordinates.first)
        let parsed = try #require(RecipeBookmarkRepository.parseCoordinate(hiddenCoord))
        #expect(HiddenRecipes.isHidden(coordinate: hiddenCoord))

        let hiddenEvent = NostrEvent(
            id: "aa",
            pubkey: parsed.pubkey,
            kind: parsed.kind,
            createdAt: 100,
            tags: [["d", parsed.dTag], ["t", "zapcooking"]],
            content: bookmarkTestRecipeBody,
            sig: String(repeating: "0", count: 128)
        )
        let visibleAuthor = String(repeating: "c", count: 64)
        let visible = NostrEvent(
            id: "bb",
            pubkey: visibleAuthor,
            kind: RecipeParser.recipeKind,
            createdAt: 100,
            tags: [["d", "weeknight-ragu"], ["t", "zapcooking"]],
            content: bookmarkTestRecipeBody,
            sig: String(repeating: "0", count: 128)
        )
        let visibleCoord = RecipeRepository.coordinate(visible)

        let recipes = RecipeRepository(relays: [])
        recipes.ingest([hiddenEvent, visible])
        #expect(recipes.cached(author: parsed.pubkey, dTag: parsed.dTag) == nil)
        #expect(recipes.cached(author: visibleAuthor, dTag: "weeknight-ragu")?.id == "bb")
        #expect(await recipes.requestRecipe(author: parsed.pubkey, dTag: parsed.dTag) == nil)

        let probe = Probe()
        let repo = RecipeBookmarkRepository(env: probe.env)
        let rendered = await repo.resolvedRecipes(
            coordinates: [hiddenCoord, visibleCoord],
            using: recipes
        )
        #expect(rendered.map(\.id) == ["bb"])
        #expect(!rendered.contains { RecipeRepository.coordinate($0) == hiddenCoord })
    }

    @Test func coordinateForEvent_usesTheRecipeDTag_notTheListHelper() {
        let event = NostrEvent(
            id: "aa",
            pubkey: author,
            kind: RecipeParser.recipeKind,
            createdAt: 1,
            tags: [["d", "tuscan-peposo"], ["t", "zapcooking"]],
            content: bookmarkTestRecipeBody,
            sig: String(repeating: "0", count: 128)
        )
        #expect(RecipeBookmarkRepository.coordinateForEvent(event) == coordA)
    }

    private func makeKeypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private final class Probe: @unchecked Sendable {
        var confirm: RecipeBookmarkRepository.RelayListCheck = .unconfirmed
        var cached: [NostrEvent] = []
        var signed: [NostrEvent] = []
        var published: [NostrEvent] = []
        var env: RecipeBookmarkRepository.Environment {
            RecipeBookmarkRepository.Environment(
                confirmList: { _, _ in self.confirm },
                cachedList: { _, _ in self.cached.first },
                cachedLists: { _ in self.cached },
                persist: { _ in },
                sign: { kind, tags, content in
                    let event = NostrEvent(
                        id: String(repeating: "11", count: 32),
                        pubkey: String(repeating: "bb", count: 32),
                        kind: kind,
                        createdAt: 1_700_000_001,
                        tags: tags,
                        content: content,
                        sig: String(repeating: "0", count: 128)
                    )
                    self.signed.append(event)
                    return event
                },
                publish: { event in self.published.append(event) },
                readRelays: { [] },
                nowMs: { 0 }
            )
        }
    }
}
