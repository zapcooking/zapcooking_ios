import Foundation
import Observation

/// Drives `RecipeDetailView`. Recipe bytes come only from `RecipeRepository`
/// — cache-first `requestRecipe`, one dedup. This type does not query relays
/// for recipes and does not reimplement coordinate reduction. Author-profile
/// hydration is a separate, best-effort `ProfileRepository` read and may
/// fan out on a cache miss; a miss is quiet absence, never a failed load.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.3 + §7.7):
/// - Hero / summary / prep / cook / servings / chef's notes / ingredients /
///   directions come from `RecipeParser.parse` of the repository event.
/// - `published_at` is optional (parser falls back to `created_at`).
/// - Prep / cook / servings are free-text and all optional.
/// - ½× / 1× / 2× / 3× scale the **leading numeric token** of each ingredient
///   and of the servings chip. Prep and cook are never scaled.
/// - An unparseable line comes back verbatim — `IngredientScaler` already
///   guarantees that; this type just applies it.
///
/// Parsing is `Task.detached` (§6): `RecipeParser` is `nonisolated` compute
/// and the project defaults to `MainActor`.
@Observable
@MainActor
final class RecipeDetailViewModel {

    /// ½× / 1× / 2× / 3× — the 1.4 chip set.
    static let scaleOptions: [Double] = [0.5, 1.0, 2.0, 3.0]

    private(set) var event: NostrEvent?
    private(set) var recipe: RecipeParser.Recipe?
    private(set) var isLoading = true
    private(set) var notFound = false
    private(set) var scale: Double = 1.0
    /// Author profile, hydrated best-effort. A miss is quiet absence.
    private(set) var authorProfile: ProfileData?
    /// Nourish section (Concern 3.5, read-only). Loading and a pantry miss
    /// are `.hidden` (nothing renders). AUTH on the pinned public REQ is
    /// `.authError`, never a quiet miss.
    private(set) var nourishUi: RecipeNourishUi = .hidden

    @ObservationIgnored private let repository: RecipeRepository
    @ObservationIgnored private let loadProfile: (String) async -> ProfileData?
    @ObservationIgnored private let nourish: any NourishScoring
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadedCoordinate: String?

    /// `repository` / `loadProfile` default in the body: default arguments
    /// naming isolated statics are evaluated in the caller's isolation.
    init(
        repository: RecipeRepository? = nil,
        loadProfile: ((String) async -> ProfileData?)? = nil,
        nourish: (any NourishScoring)? = nil
    ) {
        self.repository = repository ?? RecipeRepository.shared
        self.loadProfile = loadProfile ?? { pubkey in
            await ProfileRepository.shared.ensure([pubkey])[pubkey]
        }
        self.nourish = nourish ?? NourishRepository.shared
    }

    func setScale(_ value: Double) {
        scale = value
    }

    /// Ingredients with the current scale applied. Unparseable lines stay
    /// verbatim — that is `IngredientScaler`'s contract, not a second one.
    var scaledIngredients: [String] {
        guard let recipe else { return [] }
        return recipe.content.ingredients.map {
            IngredientScaler.scaleLine($0, multiplier: scale)
        }
    }

    /// Servings chip, scaled. Nil when the recipe has no servings — Tuscan
    /// Peposo is that case; the chip is omitted, not shown as empty.
    var scaledServings: String? {
        guard let raw = recipe?.content.details.servings else { return nil }
        return IngredientScaler.scaleLine(raw, multiplier: scale)
    }

    /// Prep / cook are free-text and never scaled.
    var prepTime: String? { recipe?.content.details.prepTime }
    var cookTime: String? { recipe?.content.details.cookTime }

    func load(author: String, dTag: String) async {
        let coordinate = RecipeRepository.coordinate(
            kind: RecipeParser.recipeKind, author: author, dTag: dTag
        )
        if loadedCoordinate != coordinate {
            loadedCoordinate = coordinate
            scale = 1.0
            event = nil
            recipe = nil
            authorProfile = nil
            notFound = false
            nourishUi = .hidden
        }

        loadGeneration += 1
        let generation = loadGeneration
        if event == nil { isLoading = true }

        let nourishTask = Task { () -> NourishFetchResult in
            guard NourishGate.entryVisible() else { return .miss }
            return await self.nourish.fetchScore(author: author, dTag: dTag)
        }

        // The repository is cache-first, then the articles union, then the
        // same `deduped` reduction. There is no other source.
        let found = await repository.requestRecipe(author: author, dTag: dTag)
        guard generation == loadGeneration else { return }

        if let found {
            await apply(found, generation: generation)
        } else {
            notFound = true
            isLoading = false
        }

        let nourishResult = await nourishTask.value
        guard generation == loadGeneration else { return }
        nourishUi = RecipeNourishUi.from(
            nourishResult,
            enabled: NourishGate.entryVisible()
        )
    }

    func cancel() {
        loadGeneration += 1
    }

    private func apply(_ event: NostrEvent, generation: Int) async {
        self.event = event
        let parsed = await Task.detached(priority: .utility) {
            RecipeParser.parse(event)
        }.value
        guard generation == loadGeneration else { return }
        recipe = parsed
        isLoading = false
        notFound = false
        // Best-effort, not on the load path — `ensure` fans out to relays
        // and a miss is quiet absence, never an error on the recipe.
        Task { await self.hydrateAuthor(event.pubkey, generation: generation) }
    }

    private func hydrateAuthor(_ pubkey: String, generation: Int) async {
        if authorProfile != nil { return }
        let got = await loadProfile(pubkey)
        guard generation == loadGeneration else { return }
        authorProfile = got
    }
}
