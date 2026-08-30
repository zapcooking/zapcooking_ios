import Foundation
import Testing
@testable import wisp

/// Gate for Concern 1.5 — the Recipes tab observer. Hermetic: every
/// repository is constructed with `relays: []`, so a cache miss cannot
/// open a socket.
@MainActor
struct RecipeFeedViewModelTests {

    private let recipeBody = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."

    private func recipe(
        id: String,
        author: String = String(repeating: "a", count: 64),
        dTag: String = "ragu",
        createdAt: Int
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: author,
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: [["d", dTag], ["t", "zapcooking"], ["title", "Ragu"]],
            content: recipeBody,
            sig: String(repeating: "0", count: 128)
        )
    }

    /// "Still fetching" and "no recipes yet" must not share a state.
    /// Before the first load completes, an empty list is the loading
    /// skeleton — not the empty copy. A slow union would otherwise
    /// flash "No recipes yet."
    @Test func emptyAndLoading_areDistinguishable() {
        let repo = RecipeRepository(relays: [])
        let vm = RecipeFeedViewModel(repository: repo)

        #expect(vm.isAwaitingFirstPaint)
        #expect(!vm.isEmpty)
        #expect(vm.events.isEmpty)
    }

    @Test func emptyState_onlyAfterCompletedLoadWithNothing() async {
        let repo = RecipeRepository(relays: [])
        let vm = RecipeFeedViewModel(repository: repo)

        vm.start()
        await repo.inFlight?.value

        #expect(!vm.isAwaitingFirstPaint)
        #expect(vm.isEmpty)
        #expect(vm.hasLoaded)
    }

    /// Cache-seeded first paint: recipes are on screen before the union
    /// answers, and a silent union does not replace them with the empty
    /// state. This is the airplane-mode / Guideline 4.2 property.
    @Test func start_paintsCacheAndDoesNotTreatEmptyUnionAsEmpty() async {
        let cached = recipe(id: "aa", createdAt: 100)
        let repo = RecipeRepository(relays: [], seedCache: { [cached] })
        let vm = RecipeFeedViewModel(repository: repo)

        vm.start()
        await repo.inFlight?.value

        #expect(vm.events.map(\.id) == ["aa"])
        #expect(!vm.isAwaitingFirstPaint)
        #expect(!vm.isEmpty)
        #expect(vm.hasLoaded)
    }

    /// `.task` re-runs on state changes. A second `start` must not
    /// re-issue the filter (§7.4).
    @Test func start_isOneShot() async {
        let repo = RecipeRepository(relays: [])
        let vm = RecipeFeedViewModel(repository: repo)

        vm.start()
        await repo.inFlight?.value
        #expect(repo.hasLoaded)

        vm.start()
        #expect(!repo.isLoading)
    }

    @Test func loadMoreIfNeeded_firesNearTheEnd() {
        let events = (0..<20).map { i in
            recipe(
                id: String(format: "%02x", i),
                dTag: "r\(i)",
                createdAt: 300 - i
            )
        }
        let repo = RecipeRepository(relays: [])
        repo.ingest(events)
        let vm = RecipeFeedViewModel(repository: repo)

        vm.loadMoreIfNeeded(currentIndex: 0, total: 20)
        #expect(!repo.isLoading)

        vm.loadMoreIfNeeded(currentIndex: 14, total: 20)
        #expect(repo.isLoading)
    }
}
