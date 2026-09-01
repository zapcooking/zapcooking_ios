import Foundation
import Testing
@testable import wisp

@MainActor
struct NourishExploreTests {
    init() {
        NourishDiscovery.resetSessionCaches()
    }

    @Test func killSwitch_defaultOn_offHidesTabAndCard() {
        #expect(FeatureFlags.nourishEnabled)
        #expect(NourishGate.entryVisible())
        #expect(NourishGate.entryVisible(flagEnabled: true))
        #expect(!NourishGate.entryVisible(flagEnabled: false))
        #expect(MyKitchenSection.visibleCases(nourishEnabled: true).contains(.nourish))
        #expect(!MyKitchenSection.visibleCases(nourishEnabled: false).contains(.nourish))
        #expect(RecipeNourishUi.from(.scored(Self.score), enabled: false) == .hidden)
    }

    @Test func loadingThenEmpty() async {
        let vm = NourishExploreViewModel { _, _, _ in
            NourishDiscovery.DiscoveryResult(recipes: [], degraded: false, relaysResponded: 1)
        }
        vm.start()
        #expect(vm.ui.loading)
        await vm.flush()
        #expect(!vm.ui.loading)
        #expect(!vm.ui.error)
        #expect(vm.ui.recipes.isEmpty)
    }

    @Test func authChallenge_isError_notEmpty() async {
        let vm = NourishExploreViewModel { _, _, _ in
            NourishDiscovery.DiscoveryResult(
                recipes: [], degraded: false, authChallenged: true, relaysResponded: 0
            )
        }
        vm.start()
        await vm.flush()
        #expect(vm.ui.error)
        #expect(vm.ui.recipes.isEmpty)
        #expect(!vm.ui.loading)
    }

    @Test func noEose_isError() async {
        let vm = NourishExploreViewModel { _, _, _ in
            NourishDiscovery.DiscoveryResult(recipes: [], degraded: false, relaysResponded: 0)
        }
        vm.start()
        await vm.flush()
        #expect(vm.ui.error)
    }

    @Test func loadedRecipes_sortDoesNotRefetch() async {
        let box = FetchBox()
        let vm = NourishExploreViewModel { sortBy, _, _ in
            box.n += 1
            return Self.result(sortBy: sortBy)
        }
        vm.start()
        await vm.flush()
        #expect(box.n == 1)
        #expect(vm.ui.recipes.count == 2)
        vm.setSort(.protein)
        #expect(box.n == 1)
        #expect(vm.ui.sortBy == .protein)
        #expect(vm.ui.recipes.first?.recipeDTag == "high-protein")
    }

    @Test func toggleChip_refetches() async {
        let box = FetchBox()
        let vm = NourishExploreViewModel { _, _, filters in
            box.filters.append(filters)
            return NourishDiscovery.DiscoveryResult(recipes: [], degraded: false, relaysResponded: 1)
        }
        vm.start()
        await vm.flush()
        vm.toggleChip("high-protein")
        await vm.flush()
        #expect(box.filters.count == 2)
        #expect(box.filters.last == ["protein:30plus"])
    }

    @Test func degraded_flagIsPassedThrough() async {
        let vm = NourishExploreViewModel { _, _, _ in
            NourishDiscovery.DiscoveryResult(
                recipes: Self.result(sortBy: .overall).recipes,
                degraded: true,
                relaysResponded: 1
            )
        }
        vm.start()
        await vm.flush()
        #expect(vm.ui.degraded)
        #expect(!vm.ui.error)
        #expect(!vm.ui.recipes.isEmpty)
    }

    private static let score = NourishScore(
        overall: 7,
        overallLabel: "Strong",
        dimensions: [
            NourishDimension(name: "Real Food", score: 7),
            NourishDimension(name: "Gut", score: 6),
            NourishDimension(name: "Protein", score: 9),
            NourishDimension(name: "Anti-Inflammatory", score: 5),
            NourishDimension(name: "Blood Sugar", score: 4),
            NourishDimension(name: "Immune", score: 5),
            NourishDimension(name: "Brain", score: 5),
            NourishDimension(name: "Heart", score: 6),
        ],
        improvements: []
    )

    private static func result(
        sortBy: NourishDiscovery.SortDimension
    ) -> NourishDiscovery.DiscoveryResult {
        let high = ranked(dTag: "high-protein", protein: 9, createdAt: 1)
        let other = ranked(dTag: "other", protein: 4, createdAt: 2)
        return NourishDiscovery.DiscoveryResult(
            recipes: [high, other],
            degraded: false,
            relaysResponded: 1
        )
    }

    private static func ranked(dTag: String, protein: Int, createdAt: Int) -> NourishDiscovery.RankedRecipe {
        var score = score
        if let i = score.dimensions.firstIndex(where: { $0.name == "Protein" }) {
            score.dimensions[i].score = protein
        }
        let event = NostrEvent(
            id: dTag,
            pubkey: "aa",
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: [["d", dTag], ["t", "zapcooking"], ["title", dTag]],
            content: "## Ingredients\n- x\n## Directions\n1. y",
            sig: ""
        )
        return NourishDiscovery.RankedRecipe(
            event: event,
            score: score,
            createdAt: createdAt,
            authorPubkey: "aa",
            recipeDTag: dTag
        )
    }
}

private final class FetchBox: @unchecked Sendable {
    var n = 0
    var filters: [[String]] = []
}
