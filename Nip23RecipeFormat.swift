import Foundation

/// The NIP-23 (`kind 30023`) recipe format — the only active format today.
///
/// A **thin adapter** that delegates to the existing `RecipeParser` (read) and
/// `RecipeSerializer` (write) types verbatim — it carries no parsing or
/// serialization logic of its own. Keeping those as the implementation is what
/// guarantees byte-identical output and unchanged parity tests: the adapter only
/// re-shapes their surface behind `RecipeFormat`.
///
/// Port of Android `nostr/Nip23RecipeFormat.kt` @ `68242f5`.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 2 / 2.2):
/// - `formatRank` baseline is 0; a superseding format ranks above this.
/// - Dual-write caveat (registry-level): rank-before-recency can mask a
///   newer low-rank edit.
struct Nip23RecipeFormat: RecipeFormat {

    let kind: Int = RecipeParser.recipeKind

    /// Baseline rank — a superseding format ranks above this.
    let formatRank: Int = 0

    func matches(_ event: NostrEvent) -> Bool { RecipeParser.isRecipe(event) }

    func parse(_ event: NostrEvent) -> RecipeParser.Recipe { RecipeParser.parse(event) }

    func serialize(
        recipe: RecipeParser.Recipe,
        title: String,
        imageUrls: [String],
        categories: [String]
    ) -> UnsignedRecipeEvent {
        UnsignedRecipeEvent(
            kind: RecipeParser.recipeKind,
            content: RecipeSerializer.toContent(recipe),
            tags: RecipeSerializer.toTags(
                title: title,
                summary: recipe.summary,
                imageUrls: imageUrls,
                categories: categories
            )
        )
    }

    /// The `d` comes off `original` rather than `recipe`, because `recipe` may be
    /// a re-parse and the event in hand is the thing being replaced.
    /// `published_at` comes off `original` too — `RecipeParser.publishedAt`
    /// resolves it to the original `created_at` when the tag is absent, which is
    /// the value that stays true after the edit republishes with a fresh
    /// `created_at`.
    func serializeEdit(
        recipe: RecipeParser.Recipe,
        title: String,
        imageUrls: [String],
        categories: [String],
        original: NostrEvent
    ) -> UnsignedRecipeEvent {
        UnsignedRecipeEvent(
            kind: RecipeParser.recipeKind,
            content: RecipeSerializer.toContent(recipe),
            tags: RecipeSerializer.mergeForEdit(
                originalTags: original.tags,
                newTags: RecipeSerializer.toTags(
                    title: title,
                    summary: recipe.summary,
                    imageUrls: imageUrls,
                    categories: categories,
                    identifier: RecipeParser.dTag(original),
                    publishedAt: RecipeParser.publishedAt(original)
                )
            )
        )
    }

    func slug(_ title: String) -> String { RecipeSerializer.slug(title) }

    func feedFilter(limit: Int, until: Int?) -> NostrFilter {
        NostrFilter(
            kinds: [RecipeParser.recipeKind],
            tTags: RecipeParser.recipeHashtags,
            limit: limit,
            until: until
        )
    }

    func authorFeedFilter(author: String, limit: Int, until: Int?) -> NostrFilter {
        NostrFilter(
            kinds: [RecipeParser.recipeKind],
            authors: [author],
            tTags: RecipeParser.recipeHashtags,
            limit: limit,
            until: until
        )
    }

    func coordinateFilter(author: String, dTag: String) -> NostrFilter {
        NostrFilter(
            kinds: [RecipeParser.recipeKind],
            authors: [author],
            dTags: [dTag],
            limit: 1
        )
    }

    func searchFilter(query: String, limit: Int) -> NostrFilter {
        NostrFilter(
            kinds: [RecipeParser.recipeKind],
            tTags: RecipeParser.recipeHashtags,
            limit: limit,
            search: query
        )
    }

    func tagFeedFilter(tag: String, limit: Int, until: Int?) -> NostrFilter {
        let slug = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixedTags = RecipeParser.recipeHashtags.map { "\($0)-\(slug)" }
        return NostrFilter(
            kinds: [RecipeParser.recipeKind],
            tTags: prefixedTags,
            limit: limit,
            until: until
        )
    }
}
