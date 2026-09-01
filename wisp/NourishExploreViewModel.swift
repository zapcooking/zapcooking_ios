import Foundation
import Observation

/// Nourish Explore — ranked/filtered pantry analyses.
/// Port of Android `NourishExploreViewModel.kt`.
@Observable
@MainActor
final class NourishExploreViewModel {
    struct UiState {
        var recipes: [NourishDiscovery.RankedRecipe] = []
        var sortBy: NourishDiscovery.SortDimension = .overall
        var activeChipIds: Set<String> = []
        var loading: Bool = false
        var refreshing: Bool = false
        var error: Bool = false
        var degraded: Bool = false
        var shownCacheKey: String = ""
    }

    private(set) var ui = UiState()

    typealias Fetcher = (
        _ sortBy: NourishDiscovery.SortDimension,
        _ limit: Int,
        _ filters: [String]
    ) async -> NourishDiscovery.DiscoveryResult

    private let fetchRanked: Fetcher
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var started = false

    init(fetchRanked: Fetcher? = nil) {
        self.fetchRanked = fetchRanked ?? { sortBy, limit, filters in
            await NourishRepository.shared.fetchRankedRecipes(
                sortBy: sortBy, limit: limit, filters: filters
            )
        }
    }

    func start() {
        guard !started else { return }
        started = true
        loadRecipes(chipIds: ui.activeChipIds)
    }

    func setSort(_ dim: NourishDiscovery.SortDimension) {
        if ui.sortBy == dim { return }
        ui.sortBy = dim
        ui.recipes = sortRecipes(ui.recipes, sortBy: dim)
    }

    func toggleChip(_ chipId: String) {
        if ui.activeChipIds.contains(chipId) {
            ui.activeChipIds.remove(chipId)
        } else {
            ui.activeChipIds.insert(chipId)
        }
        loadRecipes(chipIds: ui.activeChipIds)
    }

    func retry() {
        loadRecipes(chipIds: ui.activeChipIds)
    }

    func loadRecipes(chipIds: Set<String>) {
        loadGeneration += 1
        let gen = loadGeneration
        loadTask?.cancel()

        let labels = NourishDiscovery.labelsFromChipIds(chipIds)
        let cacheKey = NourishDiscovery.filterCacheKey(labels)

        if let cached = NourishDiscovery.peekDiscoveryCache(labels), !cached.recipes.isEmpty {
            ui.recipes = sortRecipes(cached.recipes, sortBy: ui.sortBy)
            ui.degraded = cached.degraded
            ui.shownCacheKey = cacheKey
            ui.loading = false
            ui.refreshing = true
            ui.error = false
        } else {
            let clearPrior = ui.shownCacheKey != cacheKey
            if clearPrior {
                ui.recipes = []
                ui.degraded = false
            }
            ui.shownCacheKey = cacheKey
            ui.loading = clearPrior || ui.recipes.isEmpty
            ui.refreshing = !clearPrior && !ui.recipes.isEmpty
            ui.error = false
        }

        let sortBy = ui.sortBy
        loadTask = Task { [fetchRanked] in
            let result = await fetchRanked(sortBy, 40, labels)
            guard !Task.isCancelled, gen == self.loadGeneration else { return }
            let stillActive = NourishDiscovery.filterCacheKey(labels)
                == NourishDiscovery.filterCacheKey(
                    NourishDiscovery.labelsFromChipIds(self.ui.activeChipIds)
                )
            guard stillActive else { return }

            if result.authChallenged {
                self.ui.loading = false
                self.ui.refreshing = false
                self.ui.error = true
                return
            }
            if result.relaysResponded == 0 && result.recipes.isEmpty {
                self.ui.loading = false
                self.ui.refreshing = false
                self.ui.error = self.ui.recipes.isEmpty
                return
            }

            self.ui.recipes = self.sortRecipes(result.recipes, sortBy: self.ui.sortBy)
            self.ui.degraded = result.degraded
            self.ui.shownCacheKey = cacheKey
            self.ui.loading = false
            self.ui.refreshing = false
            self.ui.error = false
        }
    }

    /// Test seam — wait for the in-flight load.
    func flush() async {
        await loadTask?.value
    }

    private func sortRecipes(
        _ recipes: [NourishDiscovery.RankedRecipe],
        sortBy: NourishDiscovery.SortDimension
    ) -> [NourishDiscovery.RankedRecipe] {
        recipes.sorted {
            let a = NourishDiscovery.getDimensionScore($0.score, dim: sortBy)
            let b = NourishDiscovery.getDimensionScore($1.score, dim: sortBy)
            if a != b { return a > b }
            return $0.createdAt > $1.createdAt
        }
    }
}
