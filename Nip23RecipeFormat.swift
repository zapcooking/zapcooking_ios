import Foundation

/// The NIP-23 (`kind 30023`) recipe format — the only active format today.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 2 / 2.2):
/// - Thin adapter over `RecipeParser` (read) and `RecipeSerializer` (write);
///   carries no parsing/serialization logic of its own.
/// - `formatRank` baseline is 0; a superseding format ranks above this.
/// - Dual-write caveat (registry-level): rank-before-recency can mask a
///   newer low-rank edit.
///
/// Stub — Concern 1.0 scaffolding. Implementation lands in Concern 2.2.
struct Nip23RecipeFormat: RecipeFormat {
    var kind: Int {
        fatalError("unimplemented")
    }

    var formatRank: Int {
        fatalError("unimplemented")
    }

    func matches(_ event: NostrEvent) -> Bool {
        fatalError("unimplemented")
    }

    func parse(_ event: NostrEvent) -> RecipeParser.Recipe {
        fatalError("unimplemented")
    }

    func serialize(
        recipe: RecipeParser.Recipe,
        title: String,
        imageUrls: [String],
        categories: [String]
    ) -> UnsignedRecipeEvent {
        fatalError("unimplemented")
    }

    func serializeEdit(
        recipe: RecipeParser.Recipe,
        title: String,
        imageUrls: [String],
        categories: [String],
        original: NostrEvent
    ) -> UnsignedRecipeEvent {
        fatalError("unimplemented")
    }

    func slug(_ title: String) -> String {
        fatalError("unimplemented")
    }

    func feedFilter(limit: Int, until: Int?) -> NostrFilter {
        fatalError("unimplemented")
    }

    func authorFeedFilter(author: String, limit: Int, until: Int?) -> NostrFilter {
        fatalError("unimplemented")
    }

    func coordinateFilter(author: String, dTag: String) -> NostrFilter {
        fatalError("unimplemented")
    }

    func searchFilter(query: String, limit: Int) -> NostrFilter {
        fatalError("unimplemented")
    }

    func tagFeedFilter(tag: String, limit: Int, until: Int?) -> NostrFilter {
        fatalError("unimplemented")
    }
}
