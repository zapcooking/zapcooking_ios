import Foundation
import Testing
@testable import wisp

@MainActor
struct NourishCardTests {
    @Test func quietMiss_isHidden_notError() {
        #expect(RecipeNourishUi.from(.miss) == .hidden)
    }

    @Test func auth_isError_notMiss() {
        #expect(RecipeNourishUi.from(.authRequired) == .authError)
        #expect(RecipeNourishUi.from(.authRequired) != .hidden)
    }

    @Test func scored_renders() {
        let score = NourishScore(
            overall: 7,
            overallLabel: "Strong",
            dimensions: [NourishDimension(name: "Real Food", score: 8)],
            improvements: ["Add greens"]
        )
        #expect(RecipeNourishUi.from(.scored(score)) == .scored(score))
    }

    @Test func detailLoad_miss_staysHidden() async {
        let event = recipeEvent()
        let repo = RecipeRepository(relays: [])
        repo.ingest([event], reset: true)
        let vm = RecipeDetailViewModel(
            repository: repo,
            loadProfile: { _ in nil },
            nourish: StubNourish(result: .miss)
        )
        await vm.load(author: event.pubkey, dTag: RecipeParser.dTag(event))
        #expect(vm.nourishUi == .hidden)
        #expect(vm.recipe != nil)
    }

    @Test func detailLoad_auth_isExplicitError() async {
        let event = recipeEvent()
        let repo = RecipeRepository(relays: [])
        repo.ingest([event], reset: true)
        let vm = RecipeDetailViewModel(
            repository: repo,
            loadProfile: { _ in nil },
            nourish: StubNourish(result: .authRequired)
        )
        await vm.load(author: event.pubkey, dTag: RecipeParser.dTag(event))
        #expect(vm.nourishUi == .authError)
    }

    @Test func detailLoad_scored_showsCardState() async {
        let event = recipeEvent()
        let repo = RecipeRepository(relays: [])
        repo.ingest([event], reset: true)
        let score = NourishScore(
            overall: 8,
            overallLabel: "Strong",
            dimensions: [],
            improvements: []
        )
        let vm = RecipeDetailViewModel(
            repository: repo,
            loadProfile: { _ in nil },
            nourish: StubNourish(result: .scored(score))
        )
        await vm.load(author: event.pubkey, dTag: RecipeParser.dTag(event))
        #expect(vm.nourishUi == .scored(score))
    }

    @Test func repositoryFetchScore_authShortCircuits() async {
        let repo = NourishRepository(
            pantryQuery: { _ in
                RelayQueryOutcome(events: [], relaysResponded: 0, authChallenged: true)
            },
            articlesQuery: { _ in [] }
        )
        let result = await repo.fetchScore(author: "aa", dTag: "stew")
        #expect(result == .authRequired)
    }

    @Test func repositoryFetchScore_emptyEose_isMiss() async {
        let repo = NourishRepository(
            pantryQuery: { filter in
                #expect(filter.authors == [NourishParser.servicePubkey])
                #expect(filter.kinds == [30078])
                return RelayQueryOutcome(events: [], relaysResponded: 1, authChallenged: false)
            },
            articlesQuery: { _ in [] }
        )
        let result = await repo.fetchScore(author: "aa", dTag: "stew")
        #expect(result == .miss)
    }

    private func recipeEvent() -> NostrEvent {
        NostrEvent(
            id: "rid",
            pubkey: String(repeating: "a", count: 64),
            kind: RecipeParser.recipeKind,
            createdAt: 1,
            tags: [["d", "stew"], ["t", "zapcooking"], ["title", "Stew"]],
            content: """
            ## Details
            - ⏱️ Prep time: 10 min
            - 🍳 Cook time: 30 min
            ## Ingredients
            - 1 kg beef
            ## Directions
            1. Cook.
            """,
            sig: String(repeating: "0", count: 128)
        )
    }
}
