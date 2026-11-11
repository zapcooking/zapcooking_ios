import Foundation

/// "From the recipe box": older recipes woven into Fresh as special cards,
/// ported from web `src/lib/freshFeed/recipeBox.ts` (ZapCooking e4a71d6b).
/// Picked at random from the recipes this account hasn't been shown yet.
///
/// Pool: kind 30023 tagged zapcooking / nostrcooking (and kind 35000, which
/// iOS doesn't request), first published (`published_at`, else
/// `created_at`) more than 14 days ago; one per coordinate, the newest
/// version.
///
/// The box cards and the finish-line recipe row never show the same recipe
/// (Seth, 2026-11-11): a box pick skips what the row has shown, and the row
/// skips what the box has taken. Web gets this by drawing its explore row
/// from the same taken set.
nonisolated enum FreshRecipeBox {
    /// `kind:pubkey:d`, the coordinate every version of a recipe shares.
    static func address(_ e: NostrEvent) -> String {
        RecipeRepository.coordinate(e)
    }

    /// An older recipe: first published before the free window.
    static func isCandidate(_ e: NostrEvent, now: Int) -> Bool {
        guard FreshPosts.isRecipe(kind: e.kind, tags: e.tags) else { return false }
        let first = FreshPosts.publishedAt(tags: e.tags) ?? e.createdAt
        return first < now - FreshPosts.freeWindowSeconds
    }

    /// Candidates only, newest version per coordinate, newest first.
    static func buildPool(_ events: [NostrEvent], now: Int) -> [NostrEvent] {
        var byAddress: [String: NostrEvent] = [:]
        for e in events where isCandidate(e, now: now) {
            let a = address(e)
            if let kept = byAddress[a], kept.createdAt >= e.createdAt { continue }
            byAddress[a] = e
        }
        return byAddress.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
    }

    /// A random recipe this account hasn't been shown (`seen`), not already
    /// taken this session, and not otherwise excluded (in the feed, or shown
    /// in the finish-line row); nil when the pool is used up.
    static func pickRandom(
        _ pool: [NostrEvent],
        seen: Set<String>,
        taken: Set<String>,
        excluding: Set<String> = [],
        random: FreshRandom = { Double.random(in: 0..<1) }
    ) -> NostrEvent? {
        let open = pool.filter {
            let a = address($0)
            return !seen.contains(a) && !taken.contains(a) && !excluding.contains(a) && !excluding.contains($0.id)
        }
        guard !open.isEmpty else { return nil }
        return open[min(open.count - 1, Int((random() * Double(open.count)).rounded(.down)))]
    }

    /// The finish-line row: the pool minus recipes already in the feed (by
    /// id, or by coordinate so another edit counts as shown) and minus the
    /// coordinates the box cards took, at most `limit`.
    static func rowPicks(pool: [NostrEvent], feed: [NostrEvent], boxTaken: Set<String>, limit: Int) -> [NostrEvent] {
        let shownIds = Set(feed.map(\.id))
        let shownCoordinates = Set(feed.filter { $0.kind == 30023 }.map(address))
        return Array(pool.lazy
            .filter {
                let a = address($0)
                return !shownIds.contains($0.id) && !shownCoordinates.contains(a) && !boxTaken.contains(a)
            }
            .prefix(limit))
    }
}
