import Foundation
import Testing
@testable import wisp

/// Quiet pantry miss — existing detail tests must not open a socket.
struct StubNourish: NourishScoring, Sendable {
    var result: NourishFetchResult = .miss
    func fetchScore(author: String, dTag: String) async -> NourishFetchResult { result }
}

/// Gate for Concern 1.3 — detail consumes `RecipeRepository`, applies
/// `IngredientScaler` to ingredients + servings only, and survives the
/// live-data holes §7.7 paid for (missing `published_at`, missing servings,
/// parenthesized d-tag).
///
/// Hermetic: every repository is constructed with `relays: []`, so a cache
/// miss cannot open a socket. The Tuscan fixture is the real event.
@MainActor
struct RecipeDetailViewModelTests {

    private func tuscanEvent() -> NostrEvent {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            fatalError("fixture decode failed")
        }
        return event
    }

    private func repoHolding(_ events: [NostrEvent]) -> RecipeRepository {
        let repo = RecipeRepository(relays: [])
        repo.ingest(events, reset: true)
        return repo
    }

    private func makeVM(
        _ repo: RecipeRepository,
        nourish: (any NourishScoring)? = nil
    ) -> RecipeDetailViewModel {
        RecipeDetailViewModel(
            repository: repo,
            loadProfile: { _ in nil },
            nourish: nourish ?? StubNourish()
        )
    }

    private func recipeEvent(
        id: String = "aa",
        author: String = String(repeating: "a", count: 64),
        dTag: String = "ragu",
        createdAt: Int = 100,
        title: String = "Ragu",
        servingsLine: String? = nil,
        extraIngredients: [String] = []
    ) -> NostrEvent {
        var details = "- \u{23F2}\u{FE0F} Prep time: 10 min\n- \u{1F373} Cook time: 30 min"
        if let servingsLine {
            details += "\n- \u{1F37D}\u{FE0F} Servings: \(servingsLine)"
        }
        let extras = extraIngredients.map { "- \($0)" }.joined(separator: "\n")
        let body = """
        ## Chef's notes

        Note.

        ## Details

        \(details)

        ## Ingredients

        - 1 kg beef
        - Salt
        \(extras)

        ## Directions

        1. Mix.
        2. Cook.
        """
        return NostrEvent(
            id: id,
            pubkey: author,
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: [
                ["d", dTag],
                ["t", "zapcooking"],
                ["title", title],
            ],
            content: body,
            sig: String(repeating: "0", count: 128)
        )
    }

    // MARK: - Repository is the only source

    @Test func load_resolvesFromRepositoryCache_noRelayQuery() async {
        let event = tuscanEvent()
        let repo = repoHolding([event])
        let vm = makeVM(repo)

        await vm.load(author: event.pubkey, dTag: RecipeParser.dTag(event))

        #expect(vm.notFound == false)
        #expect(vm.isLoading == false)
        #expect(vm.event?.id == event.id)
        #expect(vm.recipe?.title == "Tuscan Peposo (Black Pepper Beef Stew)")
        #expect(vm.recipe?.dTag == "tuscan-peposo-(black-pepper-beef-stew)")
    }

    @Test func load_missOnEmptyRelays_isNotFound() async {
        let repo = RecipeRepository(relays: [])
        let vm = makeVM(repo)

        await vm.load(author: String(repeating: "a", count: 64), dTag: "missing")

        #expect(vm.notFound)
        #expect(vm.recipe == nil)
        #expect(vm.isLoading == false)
    }

    @Test func load_parenthesizedDTag_joinsRaw() async {
        let dTag = "tuscan-peposo-(black-pepper-beef-stew)/v2"
        let event = recipeEvent(dTag: dTag)
        let repo = repoHolding([event])
        let vm = makeVM(repo)

        await vm.load(author: event.pubkey, dTag: dTag)

        #expect(vm.recipe?.dTag == dTag)
        #expect(vm.recipe?.title == "Ragu")
    }

    // MARK: - §7.7 live-data holes on the real event

    @Test func tuscan_missingPublishedAt_fallsBackToCreatedAt() async {
        let event = tuscanEvent()
        let vm = makeVM(repoHolding([event]))
        await vm.load(author: event.pubkey, dTag: RecipeParser.dTag(event))

        #expect(vm.recipe?.publishedAt == 1_776_632_470)
        #expect(vm.prepTime == "10 min")
        #expect(vm.cookTime == "3 hours")
        #expect(vm.scaledServings == nil)
    }

    @Test func tuscan_ingredientsAndDirections_matchParser() async {
        let event = tuscanEvent()
        let vm = makeVM(repoHolding([event]))
        await vm.load(author: event.pubkey, dTag: RecipeParser.dTag(event))

        #expect(vm.scaledIngredients.count == 7)
        #expect(vm.scaledIngredients.first == "1 kg beef for stewing (chuck or similar)")
        #expect(vm.recipe?.content.directions.count == 6)
        #expect(vm.recipe?.content.directions.first == "Cut beef into large chunks.")
        #expect(vm.recipe?.categories == ["italian", "beef", "stew", "slowcooked"])
    }

    // MARK: - Scaling

    @Test func scale_ingredientsLeadingTokenOnly_servingsScales_prepCookDoNot() async {
        let event = recipeEvent(servingsLine: "4", extraIngredients: ["60 mL water ¼ cup"])
        let vm = makeVM(repoHolding([event]))
        await vm.load(author: event.pubkey, dTag: RecipeParser.dTag(event))

        #expect(vm.prepTime == "10 min")
        #expect(vm.cookTime == "30 min")
        #expect(vm.scaledServings == "4")

        vm.setScale(2.0)
        #expect(vm.scaledIngredients.contains("2 kg beef"))
        #expect(vm.scaledIngredients.contains("Salt"))
        #expect(vm.scaledIngredients.contains("120 mL water ¼ cup"))
        #expect(vm.scaledServings == "8")
        #expect(vm.prepTime == "10 min")
        #expect(vm.cookTime == "30 min")
    }

    @Test func scale_halfAndIdentity() async {
        let event = recipeEvent(servingsLine: "4")
        let vm = makeVM(repoHolding([event]))
        await vm.load(author: event.pubkey, dTag: RecipeParser.dTag(event))

        vm.setScale(0.5)
        #expect(vm.scaledIngredients.contains("½ kg beef"))
        #expect(vm.scaledServings == "2")

        vm.setScale(1.0)
        #expect(vm.scaledIngredients.contains("1 kg beef"))
        #expect(vm.scaledServings == "4")
    }

    @Test func scale_resetsWhenCoordinateChanges() async {
        let first = recipeEvent(dTag: "one")
        let second = recipeEvent(id: "bb", dTag: "two", title: "Other")
        let repo = repoHolding([first, second])
        let vm = makeVM(repo)

        await vm.load(author: first.pubkey, dTag: "one")
        vm.setScale(3.0)
        #expect(abs(vm.scale - 3.0) < 0.001)

        await vm.load(author: second.pubkey, dTag: "two")
        #expect(abs(vm.scale - 1.0) < 0.001)
        #expect(vm.recipe?.title == "Other")
    }

    @Test func scaleLabel_matchesChipCopy() {
        #expect(RecipeDetailView.scaleLabel(0.5) == "½×")
        #expect(RecipeDetailView.scaleLabel(1.0) == "1×")
        #expect(RecipeDetailView.scaleLabel(2.0) == "2×")
        #expect(RecipeDetailView.scaleLabel(3.0) == "3×")
    }
}
