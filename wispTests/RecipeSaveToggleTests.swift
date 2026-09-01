import Foundation
import Testing
@testable import wisp

private let saveToggleRecipeBody = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."

/// Concern 3.1b — save toggle state is a repository read; writes go through
/// the 3.1 `toggle` / `mutateList` path (cold-session guard intact);
/// `ArticleActionBar` routes recipes to kind 30001 and articles to 30003.
@MainActor
struct RecipeSaveToggleTests {

    private let author = String(repeating: "bb", count: 32)
    private var coordA: String { "30023:\(author):tuscan-peposo" }

    // MARK: - ArticleActionBar routing (one test per branch)

    @Test func bookmarkActionTarget_recipe_isKind30001() {
        let event = recipe()
        #expect(RecipeParser.isRecipe(event))
        #expect(BookmarkActionTarget.of(event: event) == .recipeBookmark)
    }

    @Test func bookmarkActionTarget_plainArticle_isKind30003() {
        let event = article()
        #expect(!RecipeParser.isRecipe(event))
        #expect(BookmarkActionTarget.of(event: event) == .noteList)
    }

    // MARK: - Watch-only gate (needs-key, not a silent no-op)

    @Test func recipeSaveGate_watchOnly_isNeedsKey() {
        #expect(RecipeSaveGate.of(canSign: false) == .needsKey)
        #expect(RecipeSaveGate.of(canSign: true) == .canWrite)
        #expect(RecipeSaveActions.needsKeyMessage ==
            "Saving is signed with your key. Sign in with a key to save this.")
    }

    @Test func unconfirmedMessage_matchesAndroidToastCopy() {
        #expect(
            RecipeBookmarkRepository.writeUnconfirmedMessage
                == "Couldn't reach your relays to check your saved list — nothing was saved. Try again in a moment."
        )
    }

    // MARK: - Fill state from the repository

    @Test func fillState_present_readsTheDefaultList() {
        let probe = Probe()
        let repo = RecipeBookmarkRepository(env: probe.env)
        repo.applyEvent(listEvent(tags: [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", "Saved"],
            ["a", coordA],
        ]))
        #expect(repo.isRecipeBookmarked(recipe()))
        #expect(repo.bookmarkedCoordinates == [coordA])
        #expect(!repo.isWriting)
    }

    @Test func fillState_absent_isUnfilled() {
        let repo = RecipeBookmarkRepository(env: Probe().env)
        #expect(!repo.isRecipeBookmarked(recipe()))
        #expect(repo.bookmarkedCoordinates.isEmpty)
    }

    // MARK: - Save / unsave through the 3.1 path

    @Test func toggle_save_writesDefaultList30001Shape() async {
        let probe = Probe()
        probe.confirm = .confirmedAbsent
        let repo = RecipeBookmarkRepository(env: probe.env)
        let kp = try! makeKeypair()

        #expect(!repo.isRecipeBookmarked(recipe()), "pre-toggle fill is a repository read")
        let saved = await repo.toggle(event: recipe(), keypair: kp)
        #expect(saved == true)
        #expect(repo.isRecipeBookmarked(recipe()))
        #expect(probe.signed.count == 1)
        let tags = probe.signed[0].tags
        #expect(probe.signed[0].kind == RecipeBookmarkRepository.listKind)
        #expect(tags.contains(["d", RecipeBookmarkRepository.defaultListDTag]))
        #expect(tags.contains(["title", RecipeBookmarkRepository.defaultListTitle]))
        #expect(tags.contains(["a", coordA]))
        #expect(!tags.contains(where: { $0.first == "t" }), "default list never carries t")
        #expect(!repo.isWriting)
    }

    @Test func toggle_unsave_dropsTheCoordinate() async {
        let probe = Probe()
        probe.confirm = .found(listEvent(tags: [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", "Saved"],
            ["a", coordA],
            ["a", "30023:\(author):shakshuka"],
        ]))
        let repo = RecipeBookmarkRepository(env: probe.env)
        let kp = try! makeKeypair()
        let stillSaved = await repo.toggle(event: recipe(), keypair: kp)
        #expect(stillSaved == false)
        #expect(!repo.isRecipeBookmarked(recipe()))
        #expect(probe.signed[0].tags.contains(["a", "30023:\(author):shakshuka"]))
        #expect(!probe.signed[0].tags.contains(["a", coordA]))
    }

    @Test func toggle_unconfirmedCold_signsNothing_fillUnchanged() async {
        let probe = Probe()
        probe.confirm = .unconfirmed
        let repo = RecipeBookmarkRepository(env: probe.env)
        let kp = try! makeKeypair()
        #expect(!repo.isRecipeBookmarked(recipe()))
        let saved = await repo.toggle(event: recipe(), keypair: kp)
        #expect(saved == false)
        #expect(!repo.isRecipeBookmarked(recipe()), "unconfirmed must not flip filled")
        #expect(probe.signed.isEmpty)
        #expect(probe.published.isEmpty)
        #expect(repo.lastWriteError == RecipeBookmarkRepository.writeUnconfirmedMessage)
        #expect(!repo.isWriting)
    }

    // MARK: - HiddenRecipes refuse

    @Test func shouldRefuseHiddenAdd_addYes_unsaveNo() throws {
        let hidden = try #require(HiddenRecipes.coordinates.first)
        #expect(RecipeBookmarkRepository.shouldRefuseHiddenAdd(
            coordinate: hidden, currentlySaved: false, desired: true
        ))
        #expect(RecipeBookmarkRepository.shouldRefuseHiddenAdd(
            coordinate: hidden, currentlySaved: false, desired: nil
        ))
        #expect(!RecipeBookmarkRepository.shouldRefuseHiddenAdd(
            coordinate: hidden, currentlySaved: true, desired: false
        ))
        #expect(!RecipeBookmarkRepository.shouldRefuseHiddenAdd(
            coordinate: hidden, currentlySaved: true, desired: nil
        ))
        #expect(!RecipeBookmarkRepository.shouldRefuseHiddenAdd(
            coordinate: coordA, currentlySaved: false, desired: true
        ))
    }

    @Test func toggle_hiddenCoordinate_refused_signsNothing() async throws {
        let hiddenEvent = try hiddenRecipe()
        let coord = try #require(RecipeBookmarkRepository.coordinateForEvent(hiddenEvent))
        #expect(HiddenRecipes.isHidden(coordinate: coord))

        let probe = Probe()
        probe.confirm = .confirmedAbsent
        let repo = RecipeBookmarkRepository(env: probe.env)
        let kp = try! makeKeypair()
        let saved = await repo.toggle(event: hiddenEvent, keypair: kp)
        #expect(saved == false)
        #expect(probe.signed.isEmpty)
        #expect(probe.published.isEmpty)
        #expect(!repo.isRecipeBookmarked(hiddenEvent))
    }

    @Test func toggle_hiddenCoordinate_alreadySaved_unsaves() async throws {
        let hiddenEvent = try hiddenRecipe()
        let coord = try #require(RecipeBookmarkRepository.coordinateForEvent(hiddenEvent))
        let probe = Probe()
        probe.confirm = .found(listEvent(tags: [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", "Saved"],
            ["a", coord],
        ]))
        let repo = RecipeBookmarkRepository(env: probe.env)
        let kp = try! makeKeypair()
        let stillSaved = await repo.toggle(event: hiddenEvent, keypair: kp)
        #expect(stillSaved == false)
        #expect(probe.signed.count == 1)
        #expect(!probe.signed[0].tags.contains(["a", coord]))
    }

    @Test func createList_hiddenSeed_omittedFromCoords() async throws {
        let hiddenEvent = try hiddenRecipe()
        let coord = try #require(RecipeBookmarkRepository.coordinateForEvent(hiddenEvent))
        let probe = Probe()
        probe.confirm = .confirmedAbsent
        let repo = RecipeBookmarkRepository(env: probe.env)
        let dTag = await repo.createList(title: "Weeknight", seedEvent: hiddenEvent, keypair: try makeKeypair())
        #expect(dTag == "weeknight")
        #expect(probe.signed.count == 1)
        #expect(!probe.signed[0].tags.contains(["a", coord]))
        #expect(probe.signed[0].tags.contains(["t", RecipeBookmarkRepository.collectionTag]))
    }

    // MARK: - Helpers

    private func recipe() -> NostrEvent {
        NostrEvent(
            id: "aa",
            pubkey: author,
            kind: RecipeParser.recipeKind,
            createdAt: 1,
            tags: [["d", "tuscan-peposo"], ["t", "zapcooking"]],
            content: saveToggleRecipeBody,
            sig: String(repeating: "0", count: 128)
        )
    }

    private func article() -> NostrEvent {
        NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: String(repeating: "1", count: 64),
            kind: RecipeParser.recipeKind,
            createdAt: 1_700_000_000,
            tags: [["t", "zapcooking"], ["d", "my-thoughts"]],
            content: "# My Thoughts on Food\n\nA long essay. No ingredients, no directions.",
            sig: String(repeating: "2", count: 128)
        )
    }

    private func hiddenRecipe() throws -> NostrEvent {
        let hiddenCoord = try #require(HiddenRecipes.coordinates.first)
        let parsed = try #require(RecipeBookmarkRepository.parseCoordinate(hiddenCoord))
        return NostrEvent(
            id: "hh",
            pubkey: parsed.pubkey,
            kind: parsed.kind,
            createdAt: 100,
            tags: [["d", parsed.dTag], ["t", "zapcooking"]],
            content: saveToggleRecipeBody,
            sig: String(repeating: "0", count: 128)
        )
    }

    private func listEvent(tags: [[String]]) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "aa", count: 32),
            pubkey: author,
            kind: RecipeBookmarkRepository.listKind,
            createdAt: 1_700_000_000,
            tags: tags,
            content: "",
            sig: String(repeating: "0", count: 128)
        )
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
