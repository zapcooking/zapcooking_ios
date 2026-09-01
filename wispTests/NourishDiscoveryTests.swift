import Foundation
import Testing
@testable import wisp

struct NourishDiscoveryTests {
    init() {
        NourishDiscovery.resetSessionCaches()
    }

    @Test func filterChips_andLabelsFromChipIds() {
        #expect(NourishDiscovery.filterChips.count == 6)
        #expect(NourishDiscovery.labelsFromChipIds([] as [String]) == [])
        #expect(NourishDiscovery.labelsFromChipIds(["high-protein"]) == ["protein:30plus"])
        #expect(
            NourishDiscovery.labelsFromChipIds(["no-seed-oils", "high-protein"])
                == ["protein:30plus", "seedoil:free"]
        )
        #expect(NourishDiscovery.labelsFromChipIds(["not-a-chip", "high-protein"]) == ["protein:30plus"])
    }

    @Test func pickMostSelectiveLabel() {
        #expect(
            NourishDiscovery.pickMostSelectiveLabel(["seedoil:free", "protein:30plus"])
                == "protein:30plus"
        )
        #expect(
            NourishDiscovery.pickMostSelectiveLabel(["kcal:under600", "seedoil:free"])
                == "kcal:under600"
        )
        #expect(NourishDiscovery.pickMostSelectiveLabel(["redmeat:free"]) == "redmeat:free")
    }

    @Test func eventHasAllLabels_namespaceAndBare() {
        let tags = [
            ["l", "protein:30plus", NourishDiscovery.labelNamespace],
            ["l", "seedoil:free", NourishDiscovery.labelNamespace],
        ]
        #expect(NourishDiscovery.eventHasAllLabels(tags: tags, required: ["protein:30plus", "seedoil:free"]))
        #expect(!NourishDiscovery.eventHasAllLabels(tags: tags, required: ["protein:30plus", "addedsugar:free"]))
        #expect(NourishDiscovery.eventHasAllLabels(tags: tags, required: []))
        #expect(
            NourishDiscovery.eventHasAllLabels(
                tags: [["l", "protein:30plus"]],
                required: ["protein:30plus"]
            )
        )
        #expect(
            !NourishDiscovery.eventHasAllLabels(
                tags: [["l", "seedoil:free", "other.ns"]],
                required: ["seedoil:free"]
            )
        )
    }

    @Test func shouldDegradeAndPreservePrevious() {
        #expect(NourishDiscovery.shouldDegradeFilteredResults(0))
        #expect(!NourishDiscovery.shouldDegradeFilteredResults(1))
        #expect(NourishDiscovery.shouldPreservePreviousOnEmpty(previousCount: 12, freshCount: 0))
        #expect(!NourishDiscovery.shouldPreservePreviousOnEmpty(previousCount: 12, freshCount: 10))
        #expect(!NourishDiscovery.shouldPreservePreviousOnEmpty(previousCount: 0, freshCount: 0))
        #expect(
            !NourishDiscovery.shouldPreservePreviousOnEmpty(
                previousCount: 12, freshCount: 0, legitimateEmpty: true
            )
        )
    }

    @Test func parseAnalyses_dedupByCoordKeepsNewest() {
        let older = nourishEvent(id: "old", createdAt: 10, recipePk: "aa", recipeD: "pasta")
        let newer = nourishEvent(id: "new", createdAt: 20, recipePk: "aa", recipeD: "pasta")
        let other = nourishEvent(id: "b", createdAt: 15, recipePk: "bb", recipeD: "soup")
        let rows = NourishDiscovery.parseAnalyses([older, newer, other])
        #expect(rows.count == 2)
        let pasta = rows.first { $0.recipeDTag == "pasta" }
        #expect(pasta?.eventId == "new")
        #expect(pasta?.createdAt == 20)
    }

    @Test func filterCacheKey_orderIndependent() {
        #expect(
            NourishDiscovery.filterCacheKey(["seedoil:free", "protein:30plus"])
                == NourishDiscovery.filterCacheKey(["protein:30plus", "seedoil:free"])
        )
        #expect(NourishDiscovery.filterCacheKey([] as [String]) == "")
    }

    @Test func recipeEventCache_keepsNewer() {
        let older = recipeEvent(id: "evt1", createdAt: 1)
        let newer = recipeEvent(id: "evt2", createdAt: 2)
        NourishDiscovery.putCachedRecipeEvent(pubkey: "pk1", dTag: "pasta", event: older)
        #expect(NourishDiscovery.getCachedRecipeEvent(pubkey: "pk1", dTag: "pasta")?.id == "evt1")
        NourishDiscovery.putCachedRecipeEvent(pubkey: "pk1", dTag: "pasta", event: newer)
        #expect(NourishDiscovery.getCachedRecipeEvent(pubkey: "pk1", dTag: "pasta")?.id == "evt2")
        NourishDiscovery.putCachedRecipeEvent(pubkey: "pk1", dTag: "pasta", event: older)
        #expect(NourishDiscovery.getCachedRecipeEvent(pubkey: "pk1", dTag: "pasta")?.id == "evt2")
    }

    private func nourishEvent(
        id: String,
        createdAt: Int,
        recipePk: String,
        recipeD: String
    ) -> NostrEvent {
        let content = """
            {"realFood":{"score":8},"gut":{"score":7},"protein":{"score":6},
             "antiInflammatory":{"score":5},"bloodSugar":{"score":4},
             "immuneSupportive":{"score":7},"brainHealth":{"score":6},
             "heartHealth":{"score":9},"overall":{"score":7,"label":"Strong"}}
            """
        return NostrEvent(
            id: id,
            pubkey: NourishParser.servicePubkey,
            kind: NourishParser.kind,
            createdAt: createdAt,
            tags: [
                ["d", NourishParser.dTag(recipeAuthor: recipePk, recipeDTag: recipeD)],
                ["a", "30023:\(recipePk):\(recipeD)"],
            ],
            content: content,
            sig: ""
        )
    }

    private func recipeEvent(id: String, createdAt: Int) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: "pk1",
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: [["d", "pasta"], ["t", "zapcooking"], ["title", "Pasta"]],
            content: "## Ingredients\n- 1 egg\n## Directions\n1. Cook.",
            sig: ""
        )
    }
}
