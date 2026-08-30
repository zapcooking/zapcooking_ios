import Foundation
import Testing
@testable import wisp

/// Gate for Concern 1.2 — the recipe read path's shared reduction, its query,
/// and cache-first single-recipe resolution.
///
/// Every case here is hermetic: no relay is contacted. The reduction is a
/// static function over events, and the cache-first path returns before any
/// query is issued — which is exactly the property being asserted.
///
/// The dedup itself is `dedupeAcrossFormats` (Concern 2.2) and has its own
/// goldens. What is tested here is that the **repository applies it** — the
/// thing that can regress when a caller is tempted to write a second dedup, and
/// the reason this concern was assigned SOLO.

/// Smallest body that passes `RecipeParser.validateMarkdownTemplate`, which
/// `isRecipe` requires in addition to kind and `#t`.
///
/// A file-scope constant, not a static on the suite: this module defaults to
/// `MainActor` isolation, and a default argument referencing an isolated static
/// is evaluated in the caller's context — an error under Swift 6.
private let recipeBody = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."

@MainActor
struct RecipeRepositoryTests {

    private func recipe(
        id: String,
        author: String = String(repeating: "a", count: 64),
        dTag: String = "ragu",
        createdAt: Int,
        hashtag: String = "zapcooking",
        body: String = recipeBody
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: author,
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: [["d", dTag], ["t", hashtag]],
            content: body,
            sig: String(repeating: "0", count: 128)
        )
    }

    // MARK: - Dedup by addressable coordinate

    @Test func dedupe_newestCreatedAtWins() {
        let older = recipe(id: "aa", createdAt: 100)
        let newer = recipe(id: "bb", createdAt: 200)
        let out = RecipeRepository.deduped([older, newer])
        #expect(out.count == 1)
        #expect(out.first?.id == "bb")
    }

    /// The NIP-01 tiebreaker. Without it two relays can disagree about which
    /// version of a recipe is current and the app shows different content on
    /// different launches — so this asserts both input orders resolve the same
    /// way, which is the property that actually matters.
    @Test func dedupe_equalCreatedAt_lowerIdWins() {
        let lowId = recipe(id: "00aa", createdAt: 100)
        let highId = recipe(id: "ffbb", createdAt: 100)

        #expect(RecipeRepository.deduped([highId, lowId]).first?.id == "00aa")
        #expect(RecipeRepository.deduped([lowId, highId]).first?.id == "00aa")
    }

    @Test func dedupe_distinctCoordinatesAllSurvive() {
        let a = recipe(id: "aa", dTag: "ragu", createdAt: 100)
        let b = recipe(id: "bb", dTag: "peposo", createdAt: 100)
        let c = recipe(id: "cc", author: String(repeating: "b", count: 64), dTag: "ragu", createdAt: 100)
        #expect(RecipeRepository.deduped([a, b, c]).count == 3)
    }

    @Test func dedupe_ordersNewestFirst_deterministicallyOnTies() {
        let newest = recipe(id: "zz", dTag: "one", createdAt: 300)
        let tieLow = recipe(id: "00", dTag: "two", createdAt: 200)
        let tieHigh = recipe(id: "ff", dTag: "three", createdAt: 200)
        let out = RecipeRepository.deduped([tieHigh, newest, tieLow])
        #expect(out.map(\.id) == ["zz", "00", "ff"])
    }

    // MARK: - Both recipe hashtags

    @Test func dedupe_acceptsBothCurrentAndLegacyHashtags() {
        let current = recipe(id: "aa", dTag: "ragu", createdAt: 100, hashtag: "zapcooking")
        let legacy = recipe(id: "bb", dTag: "peposo", createdAt: 100, hashtag: "nostrcooking")
        let out = RecipeRepository.deduped([current, legacy])
        #expect(Set(out.map(\.id)) == ["aa", "bb"])
    }

    @Test func feedFilter_queriesBothHashtagsOnKind30023() {
        let filter = RecipeRepository().feedFilter(limit: 50)
        #expect(filter.kinds == [RecipeParser.recipeKind])
        #expect(filter.tTags == ["zapcooking", "nostrcooking"])
        #expect(filter.limit == 50)
        #expect(filter.until == nil)
    }

    @Test func feedFilter_passesUntilForPaging() {
        #expect(RecipeRepository().feedFilter(limit: 50, until: 1234).until == 1234)
    }

    // MARK: - The content gate

    @Test func dedupe_dropsArticlesCarryingTheRecipeTag() {
        // A plain long-form article that merely carries `#t zapcooking`.
        let article = recipe(
            id: "aa", dTag: "announcing-branta", createdAt: 100,
            body: "# Announcing Branta\n\nProse only. No ingredients, no directions."
        )
        #expect(RecipeRepository.deduped([article]).isEmpty)
    }

    // MARK: - Raw d-tags

    /// Real d-tags carry `(`, `)` and `/`. The repository stores them raw and
    /// callers URL-encode at route boundaries; sanitizing here would break the
    /// join with what relays actually return.
    @Test func coordinate_preservesUrlHostileDTagCharacters() {
        let dTag = "tuscan-peposo-(black-pepper-beef-stew)/v2"
        let event = recipe(id: "aa", dTag: dTag, createdAt: 100)
        #expect(
            RecipeRepository.coordinate(event)
                == "30023:\(String(repeating: "a", count: 64)):\(dTag)"
        )
    }

    // MARK: - Cache-first resolution

    @Test func requestRecipe_resolvesFromCacheWithoutQuerying() async {
        let repo = RecipeRepository(relays: [])  // any query would return nothing
        let author = String(repeating: "a", count: 64)
        let dTag = "tuscan-peposo-(black-pepper-beef-stew)"
        let event = recipe(id: "aa", dTag: dTag, createdAt: 100)

        repo.ingest([event])
        #expect(repo.cached(author: author, dTag: dTag)?.id == "aa")

        let resolved = await repo.requestRecipe(author: author, dTag: dTag)
        #expect(resolved?.id == "aa")
    }

    /// Ingesting a newer edit of a recipe already held resolves through the same
    /// comparator instead of appending a duplicate — the property that makes
    /// paging and refresh safe.
    @Test func ingest_mergesWithHeldEventsRatherThanAppending() {
        let repo = RecipeRepository(relays: [])
        repo.ingest([recipe(id: "aa", createdAt: 100)])
        repo.ingest([recipe(id: "bb", createdAt: 200)])

        #expect(repo.recipes.count == 1)
        #expect(repo.recipes.first?.id == "bb")
    }

    /// The regression the uneven union actually produces. A page fetched with
    /// `until` can carry an **older** version of a coordinate already on
    /// screen, because the relay answering this page never received the edit
    /// that a different relay served on the previous page. Folding by arrival
    /// order would replace the current recipe with a stale one — wrong content,
    /// not a crash, which is the kind that ships.
    @Test func ingest_olderVersionDoesNotClobberNewerHeld() {
        let repo = RecipeRepository(relays: [])
        repo.ingest([recipe(id: "bb", createdAt: 200)])
        repo.ingest([recipe(id: "aa", createdAt: 100)])

        #expect(repo.recipes.count == 1)
        #expect(repo.recipes.first?.id == "bb")
        #expect(repo.cached(author: String(repeating: "a", count: 64), dTag: "ragu")?.id == "bb")
    }

    /// `reset` must genuinely discard, not merge — otherwise a refresh
    /// accumulates events no relay still serves. Asserted with an incoming
    /// event that is **older** than the held one, so a merge would keep the
    /// held one and the assertion catches it.
    @Test func ingest_resetDropsPreviouslyHeldEvents() {
        let repo = RecipeRepository(relays: [])
        repo.ingest([recipe(id: "aa", createdAt: 200)])
        repo.ingest([recipe(id: "bb", createdAt: 100)], reset: true)

        #expect(repo.recipes.map(\.id) == ["bb"])
    }

    @Test func ingest_resetAcrossDistinctCoordinates() {
        let repo = RecipeRepository(relays: [])
        repo.ingest([recipe(id: "aa", dTag: "ragu", createdAt: 100)])
        repo.ingest([recipe(id: "bb", dTag: "peposo", createdAt: 100)], reset: true)

        #expect(repo.recipes.map(\.id) == ["bb"])
    }

    // MARK: - The single submit path (§7.4)

    /// `isLoading` must be true the instant ``RecipeRepository/load(limit:)``
    /// returns, not once the job body starts. SwiftUI re-runs `.task` within
    /// the same runloop turn; a flag raised inside the task would still read
    /// false there, and every re-run would cancel and re-issue an identical
    /// filter on the same connection — the 99-then-0 rate-limit sequence.
    @Test func load_marksLoadingSynchronouslyAndSuppressesReentrantLoads() async {
        let repo = RecipeRepository(relays: [])  // no URLs: the query returns at once
        repo.load()
        #expect(repo.isLoading)

        repo.load()  // the re-entrant call SwiftUI would make
        repo.loadMore()
        #expect(repo.isLoading)

        await repo.inFlight?.value
        #expect(!repo.isLoading)
        #expect(repo.hasLoaded)
    }

    // MARK: - The paging cursor vs. the mute filter

    /// The cursor is a fact about what we fetched; visibility is a fact about
    /// what we display. Blocking the author of the oldest held recipe must not
    /// move the cursor forward, or every later page re-fetches ground already
    /// covered — and it gets worse as the muted fraction rises.
    @Test func pagingCursor_isOldestHeld_notOldestVisible() {
        let blocked = String(repeating: "b", count: 64)
        let repo = RecipeRepository(relays: [], isMuted: { $0 == blocked })

        repo.ingest([
            recipe(id: "aa", dTag: "newer", createdAt: 300),
            recipe(id: "bb", author: blocked, dTag: "oldest", createdAt: 100),
        ])

        #expect(repo.recipes.map(\.id) == ["aa"])        // the block is applied
        #expect(repo.recipes.last?.createdAt == 300)      // oldest VISIBLE
        #expect(repo.oldestHeldCreatedAt == 100)          // oldest HELD
    }

    /// The failure that ends the feed rather than narrowing it. When page one
    /// filters to nothing, a cursor taken from `recipes.last` is nil, so
    /// `loadMore` returns at its guard — and `load` no-ops on `hasLoaded` while
    /// `refresh` re-fetches page one and filters it away again. Empty forever,
    /// with no control that advances it, reading as "there are no recipes."
    @Test func loadMore_stillPagesWhenEveryHeldRecipeIsMuted() {
        let repo = RecipeRepository(relays: [], isMuted: { _ in true })
        repo.ingest([
            recipe(id: "aa", dTag: "one", createdAt: 300),
            recipe(id: "bb", dTag: "two", createdAt: 100),
        ])

        #expect(repo.recipes.isEmpty)
        #expect(repo.oldestHeldCreatedAt == 100)

        repo.loadMore()
        #expect(repo.isLoading)  // a job was submitted; the feed is not stranded
    }

    /// The guard still holds when there is genuinely nothing to page from, so
    /// the fix does not turn an empty union into an endless re-query.
    @Test func loadMore_isANoOpWhenNothingIsHeld() {
        let repo = RecipeRepository(relays: [])
        #expect(repo.oldestHeldCreatedAt == nil)
        repo.loadMore()
        #expect(!repo.isLoading)
    }

    /// A completed load is not re-queried. `hasLoaded` is set regardless of
    /// event count, so a legitimately empty union does not look like "never
    /// loaded" and get re-throttled (§7.4).
    @Test func load_isANoOpOnceLoadedEvenWithNoEvents() async {
        let repo = RecipeRepository(relays: [])
        repo.load()
        await repo.inFlight?.value
        #expect(repo.hasLoaded)
        #expect(repo.recipes.isEmpty)

        repo.load()
        #expect(!repo.isLoading)
    }

    // MARK: - Cache-seeded first paint (Concern 1.5 / §4.1)

    /// ObjectBox paint is a local ingest. It must not mark the feed loaded —
    /// otherwise `load` would no-op and the union would never run — and it
    /// must not open a socket.
    @Test func paintFromCache_surfacesRecipesWithoutMarkingLoaded() async {
        let cached = recipe(id: "aa", createdAt: 100)
        let repo = RecipeRepository(relays: [], seedCache: { [cached] })

        await repo.paintFromCache()

        #expect(repo.recipes.map(\.id) == ["aa"])
        #expect(!repo.hasLoaded)
        #expect(!repo.isLoading)
    }

    /// The airplane-mode gate. Seed first, then a silent union (no relays).
    /// The painted cache must still be on screen; an empty answer is not
    /// "the world is empty."
    @Test func load_keepsCacheWhenUnionReturnsNothing() async {
        let cached = recipe(id: "aa", createdAt: 100)
        let repo = RecipeRepository(relays: [], seedCache: { [cached] })

        repo.load()
        await repo.inFlight?.value

        #expect(repo.recipes.map(\.id) == ["aa"])
        #expect(repo.hasLoaded)
        #expect(!repo.isLoading)
    }

    /// Pull-to-refresh is a merge, not a replace. Airplane-mode refresh
    /// must not blank a painted grid.
    @Test func refresh_doesNotWipeHeldRecipesWhenUnionIsEmpty() async {
        let repo = RecipeRepository(relays: [])
        repo.ingest([recipe(id: "aa", createdAt: 100)])

        repo.refresh()
        await repo.inFlight?.value

        #expect(repo.recipes.map(\.id) == ["aa"])
        #expect(repo.hasLoaded)
    }

    /// `fetchPage` always persists the union result (including empty) so
    /// the hook is on the only path that talks to relays. The painted
    /// cache is not written back — persist sees the query, not the seed.
    @Test func load_persistsTheUnionResultNotTheSeed() async {
        let cached = recipe(id: "aa", createdAt: 100)
        var persisted: [[NostrEvent]] = []
        let repo = RecipeRepository(
            relays: [],
            seedCache: { [cached] },
            persist: { persisted.append($0) }
        )
        repo.load()
        await repo.inFlight?.value
        #expect(persisted.count == 1)
        #expect(persisted.first?.isEmpty == true)
        #expect(repo.recipes.map(\.id) == ["aa"])
    }
}
