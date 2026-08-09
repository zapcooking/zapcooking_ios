import Foundation

/// Parses a zap.cooking recipe — a NIP-23 long-form event (`kind 30023`)
/// tagged `#t zapcooking` (or legacy `nostrcooking`) — into the structured
/// fields the recipe UI needs.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.1):
/// - Byte-faithful port of the Kotlin / web `parseMarkdownForEditing`.
/// - **No UI.** Golden-tested against the real *Tuscan Peposo* event,
///   including missing `published_at`, missing `servings`, and live U+FE0F
///   emoji bytes.
/// - `published_at` is optional (absent on new `zapcooking`, present on
///   legacy `nostrcooking`) → fall back to `created_at`.
/// - `RecipeParser.isRecipe` is the gate used by article-tap rewiring (1.6):
///   kind-30023 opens the recipe route only when this returns true.
///
/// Stub — Concern 1.0 scaffolding. Implementation lands in Concern 1.1.
enum RecipeParser {
    static let recipeKind = 30023
    static let recipeHashtags = ["zapcooking", "nostrcooking"]

    struct RecipeDetails {
        var prepTime: String?
        var cookTime: String?
        var servings: String?
    }

    struct RecipeContent {
        var chefNotes: String?
        var details: RecipeDetails
        var ingredients: [String]
        var directions: [String]
        var additionalMarkdown: String?
    }

    struct Recipe {
        var id: String
        var author: String
        var dTag: String
        var title: String?
        var images: [String]
        var summary: String?
        var publishedAt: Int64
        var hashtags: [String]
        var categories: [String]
        var content: RecipeContent
    }

    static func isRecipe(_ event: NostrEvent) -> Bool {
        fatalError("unimplemented")
    }

    static func isRecipeContent(_ markdown: String) -> Bool {
        fatalError("unimplemented")
    }

    static func publishedAt(_ event: NostrEvent) -> Int64 {
        fatalError("unimplemented")
    }

    static func dTag(_ event: NostrEvent) -> String {
        fatalError("unimplemented")
    }

    static func parse(_ event: NostrEvent) -> Recipe {
        fatalError("unimplemented")
    }

    static func parseContent(_ markdown: String) -> RecipeContent {
        fatalError("unimplemented")
    }
}
