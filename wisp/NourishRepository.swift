import Foundation

/// Outcome of a single-recipe pantry read.
nonisolated enum NourishFetchResult: Equatable, Sendable {
    case scored(NourishScore)
    /// EOSE (or timeout with a response) and no usable event — quiet miss.
    case miss
    /// Relay sent AUTH / CLOSED auth-required on a filter that should be public.
    case authRequired
}

protocol NourishScoring: Sendable {
    func fetchScore(author: String, dTag: String) async -> NourishFetchResult
}

/// Reads Nourish 30078s from pantry via `RelayPool.queryReportingAuth`.
/// Port of Android `NourishRepository.kt` (read path only — no compute).
@MainActor
final class NourishRepository: NourishScoring {
    static let shared = NourishRepository()

    typealias PantryQuery = (NostrFilter) async -> RelayQueryOutcome
    typealias ArticlesQuery = (NostrFilter) async -> [NostrEvent]

    private let pantryQuery: PantryQuery
    private let articlesQuery: ArticlesQuery
    private let lock = NSLock()
    private var scoreCache: [String: NourishScore] = [:]

    init(
        pantryQuery: PantryQuery? = nil,
        articlesQuery: ArticlesQuery? = nil
    ) {
        self.pantryQuery = pantryQuery ?? { filter in
            await RelayPool.queryReportingAuth(
                relays: RelayDefaults.members,
                filter: filter,
                timeout: 10,
                waitForAllRelays: true
            )
        }
        self.articlesQuery = articlesQuery ?? { filter in
            await RelayPool.query(
                relays: RelayDefaults.articles,
                filter: filter,
                timeout: 8,
                waitForAllRelays: true
            )
        }
    }

    func fetchScore(author: String, dTag: String) async -> NourishFetchResult {
        if author.isEmpty || dTag.isEmpty { return .miss }
        let key = "\(author):\(dTag)"
        if let cached = cachedScore(for: key) { return .scored(cached) }

        let outcome = await pantryQuery(NourishFilter.recipeScore(author: author, dTag: dTag))
        if outcome.authChallenged { return .authRequired }
        guard let event = outcome.events.first(where: { $0.kind == NourishParser.kind }),
              let parsed = NourishParser.parse(event.content)
        else { return .miss }
        storeScore(parsed, for: key)
        return .scored(parsed)
    }

    private func cachedScore(for key: String) -> NourishScore? {
        lock.lock(); defer { lock.unlock() }
        return scoreCache[key]
    }

    private func storeScore(_ score: NourishScore, for key: String) {
        lock.lock(); defer { lock.unlock() }
        scoreCache[key] = score
    }

    func fetchRankedRecipes(
        sortBy: NourishDiscovery.SortDimension = .overall,
        limit: Int = 40,
        filters: [String] = []
    ) async -> NourishDiscovery.DiscoveryResult {
        let uniqueFilters = Array(Set(filters))
        let previous = NourishDiscovery.getCachedDiscoveryEntry(uniqueFilters)
        let fresh = await fetchFreshRanked(sortBy: sortBy, limit: limit, uniqueFilters: uniqueFilters)

        if fresh.authChallenged {
            return NourishDiscovery.DiscoveryResult(
                recipes: [],
                degraded: false,
                authChallenged: true,
                relaysResponded: fresh.relaysResponded
            )
        }

        if NourishDiscovery.shouldPreservePreviousOnEmpty(
            previousCount: previous?.recipes.count ?? 0,
            freshCount: fresh.recipes.count
        ), let previous {
            return NourishDiscovery.DiscoveryResult(
                recipes: previous.recipes,
                degraded: previous.degraded,
                refreshMiss: true,
                relaysResponded: fresh.relaysResponded
            )
        }

        if fresh.legitimateEmpty && fresh.recipes.isEmpty {
            if let unfiltered = NourishDiscovery.getCachedDiscoveryEntry([]),
               !unfiltered.recipes.isEmpty {
                NourishDiscovery.putDiscoveryCache(
                    uniqueFilters, recipes: unfiltered.recipes, degraded: true
                )
                return NourishDiscovery.DiscoveryResult(
                    recipes: unfiltered.recipes,
                    degraded: true,
                    refreshMiss: true,
                    relaysResponded: fresh.relaysResponded
                )
            }
        }

        if !fresh.recipes.isEmpty || previous == nil {
            NourishDiscovery.putDiscoveryCache(
                uniqueFilters, recipes: fresh.recipes, degraded: fresh.degraded
            )
        }

        return NourishDiscovery.DiscoveryResult(
            recipes: fresh.recipes,
            degraded: fresh.degraded,
            relaysResponded: fresh.relaysResponded
        )
    }

    private struct FreshRanked {
        var recipes: [NourishDiscovery.RankedRecipe]
        var degraded: Bool
        var legitimateEmpty: Bool
        var authChallenged: Bool
        var relaysResponded: Int
    }

    private func fetchFreshRanked(
        sortBy: NourishDiscovery.SortDimension,
        limit: Int,
        uniqueFilters: [String]
    ) async -> FreshRanked {
        if uniqueFilters.isEmpty {
            let (events, auth, responded) = await fetchNourishEvents(label: nil)
            if auth {
                return FreshRanked(
                    recipes: [], degraded: false, legitimateEmpty: false,
                    authChallenged: true, relaysResponded: responded
                )
            }
            let analyses = NourishDiscovery.parseAnalyses(events)
            let recipes = await resolveRecipesFromAnalyses(analyses, sortBy: sortBy, limit: limit)
            return FreshRanked(
                recipes: recipes, degraded: false, legitimateEmpty: false,
                authChallenged: false, relaysResponded: responded
            )
        }

        let primary = NourishDiscovery.pickMostSelectiveLabel(uniqueFilters)
        let remaining = uniqueFilters.filter { $0 != primary }
        let (nourishEvents, auth, responded) = await fetchNourishEvents(label: primary)
        if auth {
            return FreshRanked(
                recipes: [], degraded: false, legitimateEmpty: false,
                authChallenged: true, relaysResponded: responded
            )
        }
        if nourishEvents.isEmpty {
            return await degradeToUnfiltered(sortBy: sortBy, limit: limit, responded: responded)
        }

        let filteredList = remaining.isEmpty
            ? nourishEvents
            : NourishDiscovery.intersectEventsByLabels(nourishEvents, remainingLabels: remaining)
        let analyses = NourishDiscovery.parseAnalyses(filteredList)
        if NourishDiscovery.shouldDegradeFilteredResults(analyses.count) {
            return await degradeToUnfiltered(sortBy: sortBy, limit: limit, responded: responded)
        }
        let recipes = await resolveRecipesFromAnalyses(analyses, sortBy: sortBy, limit: limit)
        if recipes.isEmpty {
            return await degradeToUnfiltered(sortBy: sortBy, limit: limit, responded: responded)
        }
        return FreshRanked(
            recipes: recipes, degraded: false, legitimateEmpty: false,
            authChallenged: false, relaysResponded: responded
        )
    }

    private func degradeToUnfiltered(
        sortBy: NourishDiscovery.SortDimension,
        limit: Int,
        responded: Int
    ) async -> FreshRanked {
        let (allEvents, auth, unfilteredResponded) = await fetchNourishEvents(label: nil)
        if auth {
            return FreshRanked(
                recipes: [], degraded: false, legitimateEmpty: false,
                authChallenged: true, relaysResponded: unfilteredResponded
            )
        }
        let allAnalyses = NourishDiscovery.parseAnalyses(allEvents)
        let recipes = await resolveRecipesFromAnalyses(allAnalyses, sortBy: sortBy, limit: limit)
        return FreshRanked(
            recipes: recipes, degraded: true, legitimateEmpty: true,
            authChallenged: false, relaysResponded: max(responded, unfilteredResponded)
        )
    }

    private func fetchNourishEvents(
        label: String?
    ) async -> (events: [NostrEvent], auth: Bool, responded: Int) {
        let filter = NourishDiscovery.buildNourishAnalysisFilter(label: label)
        let outcome = await pantryQuery(filter)
        let events = outcome.events.filter { $0.kind == NourishParser.kind }
        return (events, outcome.authChallenged, outcome.relaysResponded)
    }

    private func resolveRecipesFromAnalyses(
        _ analyses: [NourishDiscovery.AnalysisRow],
        sortBy: NourishDiscovery.SortDimension,
        limit: Int
    ) async -> [NourishDiscovery.RankedRecipe] {
        if analyses.isEmpty { return [] }
        let sorted = Array(NourishDiscovery.sortAnalyses(analyses, sortBy: sortBy).prefix(limit))
        let missing = sorted.filter {
            NourishDiscovery.getCachedRecipeEvent(pubkey: $0.recipePubkey, dTag: $0.recipeDTag) == nil
        }
        if !missing.isEmpty {
            await fetchAndCacheRecipes(missing)
        }
        var results: [NourishDiscovery.RankedRecipe] = []
        for analysis in sorted {
            guard let event = NourishDiscovery.getCachedRecipeEvent(
                pubkey: analysis.recipePubkey, dTag: analysis.recipeDTag
            ), RecipeParser.isRecipe(event) else { continue }
            results.append(
                NourishDiscovery.RankedRecipe(
                    event: event,
                    score: analysis.score,
                    createdAt: analysis.createdAt,
                    authorPubkey: analysis.recipePubkey,
                    recipeDTag: analysis.recipeDTag
                )
            )
        }
        return results
    }

    private func fetchAndCacheRecipes(_ rows: [NourishDiscovery.AnalysisRow]) async {
        if rows.isEmpty { return }
        let authors = Array(Set(rows.map(\.recipePubkey)))
        let dTags = Array(Set(rows.map(\.recipeDTag)))
        let filter = NostrFilter(
            kinds: [RecipeParser.recipeKind],
            authors: authors,
            dTags: dTags,
            limit: min(200, max(50, authors.count * 2))
        )
        let events = await articlesQuery(filter)
        for event in events {
            guard event.kind == RecipeParser.recipeKind else { continue }
            let d = event.tags.first { $0.count >= 2 && $0[0] == "d" }?[1] ?? ""
            if d.isEmpty { continue }
            NourishDiscovery.putCachedRecipeEvent(pubkey: event.pubkey, dTag: d, event: event)
        }
    }

    func clear() {
        lock.lock()
        scoreCache.removeAll()
        lock.unlock()
        NourishDiscovery.resetSessionCaches()
    }
}
