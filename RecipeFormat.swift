import Foundation

/// One on-wire recipe encoding. NIP-23 (`kind 30023`) is the only active
/// format today (`Nip23RecipeFormat`); a future recipe NIP plugs in as a
/// second `RecipeFormat` without rewriting screens, feeds, or the
/// `RecipeParser.Recipe` domain model.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 2 / 2.2):
/// - Registry seam: `RecipeFormat` protocol + `Nip23RecipeFormat` thin
///   adapter + `RecipeFormats` registry (+ future `Nip333RecipeFormat` stub).
/// - Repos/publisher go through the registry, not `RecipeParser` /
///   `RecipeSerializer` directly.
///
/// Dual-write caveat: rank-before-recency can mask a newer low-rank edit.
/// When dual-write is on, keep both events in lockstep or put a recency
/// check ahead of rank.
///
/// Stub — Concern 1.0 scaffolding. Implementation lands in Concern 2.2.
protocol RecipeFormat {
    var kind: Int { get }
    var formatRank: Int { get }

    func matches(_ event: NostrEvent) -> Bool
    func parse(_ event: NostrEvent) -> RecipeParser.Recipe

    func serialize(
        recipe: RecipeParser.Recipe,
        title: String,
        imageUrls: [String],
        categories: [String]
    ) -> UnsignedRecipeEvent

    func serializeEdit(
        recipe: RecipeParser.Recipe,
        title: String,
        imageUrls: [String],
        categories: [String],
        original: NostrEvent
    ) -> UnsignedRecipeEvent

    func slug(_ title: String) -> String

    func feedFilter(limit: Int, until: Int?) -> NostrFilter
    func authorFeedFilter(author: String, limit: Int, until: Int?) -> NostrFilter
    func coordinateFilter(author: String, dTag: String) -> NostrFilter
    func searchFilter(query: String, limit: Int) -> NostrFilter
    func tagFeedFilter(tag: String, limit: Int, until: Int?) -> NostrFilter
}

/// A recipe event before signing — the publisher signs this verbatim.
struct UnsignedRecipeEvent {
    var kind: Int
    var content: String
    var tags: [[String]]
}

/// Format-agnostic identity of a logical recipe: author + slug (`d` tag),
/// deliberately without the kind — the join key across formats.
struct RecipeKey: Hashable {
    var author: String
    var slug: String
}

func recipeKey(_ event: NostrEvent) -> RecipeKey {
    fatalError("unimplemented")
}

/// Collapse same-logical-recipe events across formats by
/// `(formatRank desc, created_at desc, id asc)`.
///
/// Dual-write caveat: rank-before-recency can mask a newer low-rank edit.
func dedupeAcrossFormats(
    _ events: [NostrEvent],
    rankOf: (NostrEvent) -> Int?
) -> [NostrEvent] {
    fatalError("unimplemented")
}
