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

/// Extract the ``RecipeKey`` from an event (author + its `d` tag value).
func recipeKey(_ event: NostrEvent) -> RecipeKey {
    let d = event.tags.first { $0.count >= 2 && $0[0] == "d" }?[1] ?? ""
    return RecipeKey(author: event.pubkey, slug: d)
}

/// Collapse events that are the **same logical recipe across formats**, keyed by
/// ``RecipeKey`` (author + slug, kind-independent). The winner per key is chosen
/// by `(formatRank desc, created_at desc, id asc)` — the migration-target format
/// wins when a recipe exists in both, else newest-wins, with the lower id as a
/// deterministic final tiebreak.
///
/// `rankOf` resolves an event's format rank (`RecipeFormats.rankOf`); events
/// whose format isn't active resolve to nil and are dropped.
///
/// **Pass-through while one format is active:** every key maps to a single
/// format, so each survives unchanged and the feed is byte-for-byte what it is
/// today. The cross-format pick only ever fires once a second format registers.
///
/// Dual-write caveat: rank-before-recency means a stale higher-rank event could
/// mask a newer edit of the lower-rank one. When dual-write is turned on, either
/// keep both events in lockstep or put a recency check ahead of rank.
func dedupeAcrossFormats(
    _ events: [NostrEvent],
    rankOf: (NostrEvent) -> Int?
) -> [NostrEvent] {
    // Kotlin uses a `LinkedHashMap`, which keeps a key's ORIGINAL insertion
    // position when its value is overwritten. Swift's `Dictionary` is unordered,
    // so the key order is tracked alongside it — otherwise the output order of
    // the feed would depend on hashing.
    var order: [RecipeKey] = []
    var byKey: [RecipeKey: NostrEvent] = [:]
    for event in events {
        guard let rank = rankOf(event) else { continue }
        let key = recipeKey(event)
        guard let current = byKey[key] else {
            order.append(key)
            byKey[key] = event
            continue
        }
        if isMoreCanonical(event, rank, current, rankOf(current) ?? Int.min) {
            byKey[key] = event
        }
    }
    return order.compactMap { byKey[$0] }
}

/// The `(rank desc, created_at desc, id asc)` canonical-pick comparison.
private func isMoreCanonical(_ a: NostrEvent, _ aRank: Int, _ b: NostrEvent, _ bRank: Int) -> Bool {
    if aRank != bRank { return aRank > bRank }
    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
    return a.id < b.id
}
