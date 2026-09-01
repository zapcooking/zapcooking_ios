import Foundation

/// Nourish Explore discovery helpers — port of Android `NourishDiscovery.kt`.
enum NourishDiscovery {
    static let labelNamespace = "cooking.zap.nourish"
    static let discoveryCacheTTL: TimeInterval = 5 * 60

    enum SortDimension: String, CaseIterable, Sendable {
        case overall
        case realFood
        case gut
        case protein
    }

    struct FilterChip: Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        var nourishLabel: String
    }

    static let filterChips: [FilterChip] = [
        FilterChip(id: "high-protein", label: "High protein (30g+)", nourishLabel: "protein:30plus"),
        FilterChip(id: "under-600", label: "Under 600 kcal", nourishLabel: "kcal:under600"),
        FilterChip(id: "low-carb", label: "Low carb (under 40g)", nourishLabel: "carbs:under40"),
        FilterChip(id: "no-seed-oils", label: "No seed oils", nourishLabel: "seedoil:free"),
        FilterChip(id: "no-added-sugar", label: "No added sugar", nourishLabel: "addedsugar:free"),
        FilterChip(id: "no-red-meat", label: "No red meat", nourishLabel: "redmeat:free"),
    ]

    static let labelSelectivityAsc: [String] = [
        "protein:40plus",
        "kcal:under400",
        "protein:30plus",
        "carbs:under20",
        "protein:20plus",
        "carbs:under40",
        "kcal:under600",
        "addedsugar:free",
        "kcal:under800",
        "redmeat:free",
        "seedoil:free",
    ]

    struct AnalysisRow: Equatable, Sendable {
        var score: NourishScore
        var createdAt: Int
        var recipePubkey: String
        var recipeDTag: String
        var eventId: String
    }

    struct RankedRecipe: Sendable, Identifiable {
        var event: NostrEvent
        var score: NourishScore
        var createdAt: Int
        var authorPubkey: String
        var recipeDTag: String

        var id: String { "\(authorPubkey):\(recipeDTag)" }
    }

    struct DiscoveryResult: Sendable {
        var recipes: [RankedRecipe]
        var degraded: Bool
        var fromCache: Bool = false
        var refreshMiss: Bool = false
        var authChallenged: Bool = false
        var relaysResponded: Int = 1
    }

    static func labelsFromChipIds(_ chipIds: some Collection<String>) -> [String] {
        let wanted = Set(chipIds)
        return filterChips.compactMap { wanted.contains($0.id) ? $0.nourishLabel : nil }
    }

    static func pickMostSelectiveLabel(_ labels: [String]) -> String {
        precondition(!labels.isEmpty, "pickMostSelectiveLabel requires at least one label")
        var best = labels[0]
        var bestRank = selectivityRank(best)
        for i in 1..<labels.count {
            let rank = selectivityRank(labels[i])
            if rank < bestRank {
                best = labels[i]
                bestRank = rank
            }
        }
        return best
    }

    private static func selectivityRank(_ label: String) -> Int {
        labelSelectivityAsc.firstIndex(of: label) ?? Int.max
    }

    static func eventHasAllLabels(tags: [[String]], required: [String]) -> Bool {
        if required.isEmpty { return true }
        var present = Set<String>()
        for t in tags {
            guard t.first == "l", t.count >= 2, !t[1].isEmpty else { continue }
            if t.count >= 3, !t[2].isEmpty, t[2] != labelNamespace { continue }
            present.insert(t[1])
        }
        return required.allSatisfy { present.contains($0) }
    }

    static func intersectEventsByLabels(
        _ events: [NostrEvent],
        remainingLabels: [String]
    ) -> [NostrEvent] {
        if remainingLabels.isEmpty { return events }
        return events.filter { eventHasAllLabels(tags: $0.tags, required: remainingLabels) }
    }

    static func shouldDegradeFilteredResults(_ filteredCount: Int) -> Bool {
        filteredCount == 0
    }

    static func shouldPreservePreviousOnEmpty(
        previousCount: Int,
        freshCount: Int,
        legitimateEmpty: Bool = false
    ) -> Bool {
        if legitimateEmpty { return false }
        return previousCount > 0 && freshCount == 0
    }

    static func filterCacheKey(_ filters: some Collection<String>) -> String {
        let set = Set(filters)
        if set.isEmpty { return "" }
        return set.sorted().joined(separator: ",")
    }

    static func buildNourishAnalysisFilter(label: String? = nil) -> NostrFilter {
        if let label { return NourishFilter.labeled(label) }
        return NourishFilter.publicCorpus
    }

    static func getDimensionScore(_ score: NourishScore, dim: SortDimension) -> Int {
        switch dim {
        case .overall: score.overall
        case .realFood: score.dimensions.first { $0.name == "Real Food" }?.score ?? 0
        case .gut: score.dimensions.first { $0.name == "Gut" }?.score ?? 0
        case .protein: score.dimensions.first { $0.name == "Protein" }?.score ?? 0
        }
    }

    static func parseAnalyses(_ nourishEvents: [NostrEvent]) -> [AnalysisRow] {
        var byCoord: [String: AnalysisRow] = [:]
        for event in nourishEvents {
            let dTag = event.tags.first { $0.count >= 2 && $0[0] == "d" }?[1] ?? ""
            guard dTag.hasPrefix("nourish:") else { continue }
            guard let parsed = NourishParser.parse(event.content) else { continue }
            let aTag = event.tags.first { $0.count >= 2 && $0[0] == "a" }?[1] ?? ""
            let parts = aTag.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 3, parts[0] == "30023" else { continue }
            let recipePubkey = parts[1]
            let recipeDTag = parts[2]
            guard !recipePubkey.isEmpty, !recipeDTag.isEmpty else { continue }
            let key = recipeCoordKey(recipePubkey, recipeDTag)
            let row = AnalysisRow(
                score: parsed,
                createdAt: event.createdAt,
                recipePubkey: recipePubkey,
                recipeDTag: recipeDTag,
                eventId: event.id
            )
            if let existing = byCoord[key] {
                if row.createdAt > existing.createdAt { byCoord[key] = row }
            } else {
                byCoord[key] = row
            }
        }
        return Array(byCoord.values)
    }

    static func sortAnalyses(
        _ analyses: [AnalysisRow],
        sortBy: SortDimension
    ) -> [AnalysisRow] {
        analyses.sorted {
            let a = getDimensionScore($0.score, dim: sortBy)
            let b = getDimensionScore($1.score, dim: sortBy)
            if a != b { return a > b }
            return $0.createdAt > $1.createdAt
        }
    }

    static func recipeCoordKey(_ pubkey: String, _ dTag: String) -> String {
        "\(pubkey):\(dTag)"
    }

    // MARK: - Session caches

    private static let cacheLock = NSLock()
    private static var discoveryCache: [String: CacheEntry] = [:]
    private static var recipeEventCache: [String: NostrEvent] = [:]

    private struct CacheEntry {
        var recipes: [RankedRecipe]
        var degraded: Bool
        var fetchedAt: Date
    }

    static func peekDiscoveryCache(_ filters: some Collection<String>) -> DiscoveryResult? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let key = filterCacheKey(filters)
        guard let entry = discoveryCache[key] else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) > discoveryCacheTTL {
            discoveryCache.removeValue(forKey: key)
            return nil
        }
        return DiscoveryResult(
            recipes: entry.recipes,
            degraded: entry.degraded,
            fromCache: true
        )
    }

    static func putDiscoveryCache(
        _ filters: some Collection<String>,
        recipes: [RankedRecipe],
        degraded: Bool = false,
        fetchedAt: Date = Date()
    ) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        discoveryCache[filterCacheKey(filters)] = CacheEntry(
            recipes: recipes, degraded: degraded, fetchedAt: fetchedAt
        )
    }

    static func getCachedDiscoveryEntry(
        _ filters: some Collection<String>
    ) -> (recipes: [RankedRecipe], degraded: Bool)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let entry = discoveryCache[filterCacheKey(filters)] else { return nil }
        return (entry.recipes, entry.degraded)
    }

    static func getCachedRecipeEvent(pubkey: String, dTag: String) -> NostrEvent? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return recipeEventCache[recipeCoordKey(pubkey, dTag)]
    }

    static func putCachedRecipeEvent(pubkey: String, dTag: String, event: NostrEvent) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let key = recipeCoordKey(pubkey, dTag)
        if let existing = recipeEventCache[key], event.createdAt < existing.createdAt {
            return
        }
        recipeEventCache[key] = event
    }

    static func resetSessionCaches() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        discoveryCache.removeAll()
        recipeEventCache.removeAll()
    }
}
