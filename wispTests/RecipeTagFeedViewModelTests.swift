import Foundation
import Testing
@testable import wisp

@MainActor
struct RecipeTagFeedViewModelTests {

    private let recipeBody = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."

    private func recipe(
        id: String,
        dTag: String = "ragu",
        createdAt: Int,
        categories: [String] = ["italian"]
    ) -> NostrEvent {
        var tags: [[String]] = [["d", dTag], ["t", "zapcooking"], ["t", "zapcooking-\(dTag)"]]
        for category in categories { tags.append(["t", "zapcooking-\(category)"]) }
        tags.append(["title", "Ragu"])
        return NostrEvent(
            id: id,
            pubkey: String(repeating: "a", count: 64),
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: tags,
            content: recipeBody,
            sig: String(repeating: "0", count: 128)
        )
    }

    @Test func emptyAndLoading_areDistinguishable() {
        let repo = RecipeRepository(relays: [])
        let vm = RecipeTagFeedViewModel(tag: "italian", repository: repo)

        #expect(vm.isAwaitingFirstPaint)
        #expect(!vm.isEmpty)
        #expect(vm.events.isEmpty)
        #expect(vm.tagInfo.label == "Italian")
    }

    @Test func start_paintsMatchingCacheAndDoesNotTreatEmptyUnionAsEmpty() async {
        let cached = recipe(id: "aa", createdAt: 100, categories: ["italian"])
        let repo = RecipeRepository(relays: [], seedCache: { [cached] })
        let vm = RecipeTagFeedViewModel(tag: "italian", repository: repo)

        vm.start()
        await repo.tagInFlight?.value

        #expect(vm.events.map(\.id) == ["aa"])
        #expect(!vm.isAwaitingFirstPaint)
        #expect(!vm.isEmpty)
        #expect(vm.hasLoaded)
    }

    @Test func start_isOneShotWhileTheSharedSessionIsThisTag() async {
        let repo = RecipeRepository(relays: [])
        let vm = RecipeTagFeedViewModel(tag: "italian", repository: repo)

        vm.start()
        await repo.tagInFlight?.value
        #expect(repo.hasTagLoaded)

        vm.start()
        #expect(!repo.isTagLoading)
    }

    /// Italian → recipe → beef chip → pop. `.task` re-runs `start()` on
    /// the Italian VM; a one-shot `startedTag` would leave beef recipes
    /// under the Italian header.
    @Test func start_reloadsWhenSharedSessionMovedToAnotherTag() async {
        let italian = recipe(id: "aa", dTag: "peposo", createdAt: 100, categories: ["italian"])
        let beef = recipe(id: "bb", dTag: "steak", createdAt: 100, categories: ["beef"])
        let repo = RecipeRepository(relays: [], seedCache: { [italian, beef] })

        let italianVM = RecipeTagFeedViewModel(tag: "italian", repository: repo)
        italianVM.start()
        await repo.tagInFlight?.value
        #expect(italianVM.events.map(\.id) == ["aa"])

        let beefVM = RecipeTagFeedViewModel(tag: "beef", repository: repo)
        beefVM.start()
        await repo.tagInFlight?.value
        #expect(repo.activeTag == "beef")
        #expect(repo.tagRecipes.map(\.id) == ["bb"])

        italianVM.start()
        await repo.tagInFlight?.value
        #expect(repo.activeTag == "italian")
        #expect(italianVM.events.map(\.id) == ["aa"])
    }

    @Test func start_doesNotQueryABlankTag() {
        let repo = RecipeRepository(relays: [])
        let vm = RecipeTagFeedViewModel(tag: "   ", repository: repo)
        vm.start()
        #expect(!repo.isTagLoading)
        #expect(repo.activeTag == nil)
    }

    @Test func loadMoreIfNeeded_firesNearTheEnd() async {
        let events = (0..<20).map { i in
            recipe(
                id: String(format: "%02x", i),
                dTag: "r\(i)",
                createdAt: 300 - i,
                categories: ["italian"]
            )
        }
        let repo = RecipeRepository(relays: [])
        repo.loadTagFeed(tag: "italian")
        await repo.tagInFlight?.value
        repo.ingestTag(events)
        let vm = RecipeTagFeedViewModel(tag: "italian", repository: repo)

        vm.loadMoreIfNeeded(currentIndex: 0, total: 20)
        #expect(!repo.isTagLoading)

        vm.loadMoreIfNeeded(currentIndex: 14, total: 20)
        #expect(repo.isTagLoading)
    }
}
