import Foundation
import Testing
@testable import wisp

/// Concern 1.6 — the shared tap gate. A recipe event opens the recipe route;
/// a plain kind-30023 article opens the article route; a missing event
/// (cache miss) falls back to the article route and never claims to be a recipe.
struct ArticleTapRoutingTests {

    @Test func opensAsRecipe_realRecipe() {
        let event = Self.peposo()
        #expect(ArticleTapRouting.opensAsRecipe(event))
    }

    @Test func opensAsRecipe_plainArticle_isFalse() {
        let article = Self.articleCarryingRecipeTag()
        #expect(!ArticleTapRouting.opensAsRecipe(article))
    }

    @Test func opensAsRecipe_nilEvent_isFalse_cacheMissGuard() {
        #expect(!ArticleTapRouting.opensAsRecipe(nil))
    }

    @Test func recipeRoute_usesRawDTag() {
        let event = Self.peposo()
        let route = RecipeRoute(author: event.pubkey, dTag: RecipeParser.dTag(event))
        #expect(route.author == event.pubkey)
        #expect(route.dTag == "tuscan-peposo-(black-pepper-beef-stew)")
        #expect(ArticleTapRouting.opensAsRecipe(event))
    }

    @Test func articleFallback_whenEventMissing() {
        // The card still has author + dTag from the naddr; without the
        // event we must not invent a recipe screen.
        #expect(!ArticleTapRouting.opensAsRecipe(nil))
        let fallback = ArticleRoute(
            author: String(repeating: "a", count: 64),
            dTag: "some-slug"
        )
        #expect(fallback.kind == 30023)
        #expect(fallback.dTag == "some-slug")
    }

    @Test func kind1Note_isNotARecipe() {
        let note = NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: String(repeating: "1", count: 64),
            kind: 1,
            createdAt: 1_700_000_000,
            tags: [],
            content: "hello",
            sig: String(repeating: "2", count: 128)
        )
        #expect(!ArticleTapRouting.opensAsRecipe(note))
        #expect(note.kind != RecipeParser.recipeKind)
    }

    private static func peposo() -> NostrEvent {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            fatalError("fixture decode failed")
        }
        return event
    }

    private static func articleCarryingRecipeTag() -> NostrEvent {
        NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: String(repeating: "1", count: 64),
            kind: RecipeParser.recipeKind,
            createdAt: 1_700_000_000,
            tags: [["t", "zapcooking"], ["d", "my-thoughts"]],
            content: "# My Thoughts on Food\n\nA long essay about the #zapcooking community. "
                + "No ingredients, no directions — just prose.",
            sig: String(repeating: "2", count: 128)
        )
    }
}
