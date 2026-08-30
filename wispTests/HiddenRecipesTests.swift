import Foundation
import Testing
@testable import wisp

/// The hide list is the one object feed / tag / detail / search inherit.
/// These cases lock the two matchers: exact coordinate (web/Android parity)
/// and d-tag prefix (the 2.3 live-publish leftovers — eight pubkeys, one
/// prefix). A pubkey denylist would need a new entry per live-gate run.
struct HiddenRecipesTests {

    @Test func exactCoordinate_matchesKnownE2eRecipe() {
        #expect(
            HiddenRecipes.isHidden(
                kind: 30023,
                pubkey: "772e4f7ffd63a09748eb231e40e4dbd772fe997b8748c194f6204cfd8e4c933f",
                dTag: "e2e-salad"
            )
        )
    }

    @Test func exactCoordinate_differentPubkeySameDTag_isNotHidden() {
        #expect(
            !HiddenRecipes.isHidden(
                kind: 30023,
                pubkey: String(repeating: "a", count: 64),
                dTag: "e2e-salad"
            )
        )
    }

    @Test func prefix_hidesAnyPubkeySharingTheLivePublishDTag() {
        let dTag = "ios-2.3-live-publish-1770000000"
        let one = String(repeating: "1", count: 64)
        let two = String(repeating: "2", count: 64)
        #expect(HiddenRecipes.isHidden(kind: 30023, pubkey: one, dTag: dTag))
        #expect(HiddenRecipes.isHidden(kind: 30023, pubkey: two, dTag: dTag))
        #expect(HiddenRecipes.isHidden(coordinate: "30023:\(one):\(dTag)"))
    }

    @Test func prefix_doesNotHideANeighboringSlug() {
        #expect(
            !HiddenRecipes.isHidden(
                kind: 30023,
                pubkey: String(repeating: "a", count: 64),
                dTag: "ios-2.3-live-publish"
            )
        )
        #expect(
            !HiddenRecipes.isHidden(
                kind: 30023,
                pubkey: String(repeating: "a", count: 64),
                dTag: "ios-live-gate-recipe"
            )
        )
    }

    @Test func eventOverload_readsDTagOffTheEvent() {
        let event = NostrEvent(
            id: "aa",
            pubkey: String(repeating: "b", count: 64),
            kind: RecipeParser.recipeKind,
            createdAt: 1,
            tags: [["d", "ios-2.3-live-publish-1"], ["t", "zapcooking"]],
            content: "",
            sig: String(repeating: "0", count: 128)
        )
        #expect(HiddenRecipes.isHidden(event))
    }
}
