import Foundation
import Testing
@testable import wisp

/// Gate for Concern 1.7 — the curated browse list. Not derived from events;
/// per-recipe slug tags must not appear in it.
struct RecipeTagCatalogTests {

    @Test func catalog_matchesAndroidTagOrderAndSlugs() {
        #expect(RecipeTagCatalog.recipeTags.map(\.tag) == [
            "breakfast", "lunch", "dinner", "snack", "dessert",
            "baking", "bread", "soup", "salad", "pasta", "pizza",
            "grill", "bbq", "vegan", "vegetarian",
            "chicken", "beef", "seafood", "rice", "noodles",
            "curry", "tacos", "sandwich", "mealprep", "onepot",
            "cocktail", "coffee", "italian", "mexican", "indian",
        ])
    }

    @Test func catalog_doesNotContainPerRecipeSlugTags() {
        let slug = "tuscan-peposo-(black-pepper-beef-stew)"
        #expect(RecipeTagCatalog.byTag(slug) == nil)
        #expect(!RecipeTagCatalog.recipeTags.contains { $0.tag == slug })
        #expect(!RecipeTagCatalog.recipeTags.contains { $0.tag.hasPrefix("zapcooking-") })
        #expect(!RecipeTagCatalog.recipeTags.contains { $0.tag == "zapcooking" })
        #expect(!RecipeTagCatalog.recipeTags.contains { $0.tag == "nostrcooking" })
    }

    @Test func popular_isASubsetOfTheCatalog_inAndroidOrder() {
        #expect(RecipeTagCatalog.popularRecipeTags.map(\.tag) == [
            "breakfast", "dinner", "dessert", "chicken",
            "vegan", "pasta", "soup", "cocktail",
        ])
        let catalog = Set(RecipeTagCatalog.recipeTags.map(\.tag))
        for tag in RecipeTagCatalog.popularRecipeTags {
            #expect(catalog.contains(tag.tag))
        }
    }

    @Test func byTag_isCaseInsensitiveAndTrimmed() {
        #expect(RecipeTagCatalog.byTag(" Italian ")?.label == "Italian")
        #expect(RecipeTagCatalog.byTag("ITALIAN")?.emoji == "🇮🇹")
        #expect(RecipeTagCatalog.byTag("") == nil)
        #expect(RecipeTagCatalog.byTag("   ") == nil)
    }

    @Test func display_fallsBackForUnknownSlugs() {
        let stew = RecipeTagCatalog.display(for: "stew")
        #expect(stew.tag == "stew")
        #expect(stew.label == "Stew")
        #expect(stew.emoji == "🏷️")
        #expect(RecipeTagCatalog.display(for: "italian").label == "Italian")
    }

    @Test func search_matchesTagOrLabel_emptyNeedleIsEmpty() {
        #expect(RecipeTagCatalog.search("").isEmpty)
        #expect(RecipeTagCatalog.search("   ").isEmpty)
        #expect(RecipeTagCatalog.search("ital").map(\.tag) == ["italian"])
        #expect(RecipeTagCatalog.search("BBQ").map(\.tag) == ["bbq"])
        #expect(RecipeTagCatalog.search("cock").map(\.tag) == ["cocktail"])
        #expect(RecipeTagCatalog.search("no-such-category").isEmpty)
    }

    @Test func normalize_lowercasesAndTrims() {
        #expect(RecipeTagCatalog.normalize(" Italian ") == "italian")
        #expect(RecipeTagCatalog.normalize("") == "")
    }
}
