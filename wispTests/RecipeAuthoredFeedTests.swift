import Foundation
import Testing
@testable import wisp

/// Smallest body that passes `RecipeParser.validateMarkdownTemplate`.
/// File-scope, not a static: MainActor default isolation + default-argument
/// evaluation under Swift 6 (see `RecipeRepositoryTests`).
private let authoredTestRecipeBody = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."

/// Concern 3.2 contract 2: Published = the signed-in author's recipes
/// **through the repository** — `loadAuthoredFeed` is a repository query
/// (`authorFeedFilter`), never a view-side `.filter`, and inherits the same
/// dedup, NIP-01 tiebreaker, and HiddenRecipes reduction as the feed.
/// Every repository is constructed with `relays: []`, so a cache miss
/// cannot open a socket.
@MainActor
struct RecipeAuthoredFeedTests {

    private let author = String(repeating: "aa", count: 32)
    private let other = String(repeating: "cc", count: 32)

    private func recipe(
        id: String,
        author: String,
        dTag: String,
        createdAt: Int = 1_700_000_000
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: author,
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: [["d", dTag], ["t", "zapcooking"], ["title", dTag]],
            content: authoredTestRecipeBody,
            sig: String(repeating: "0", count: 128)
        )
    }

    // MARK: - Author scoping

    @Test func authoredFeed_isAnAuthorScopedRepositoryQuery() async {
        let mineA = recipe(id: "a1", author: author, dTag: "tuscan-peposo")
        let mineB = recipe(id: "a2", author: author, dTag: "shakshuka", createdAt: 1_700_000_010)
        let theirs = recipe(id: "b1", author: other, dTag: "meatloaf")

        let repo = RecipeRepository(relays: [], seedCache: { [mineA, mineB, theirs] })
        repo.loadAuthoredFeed(author: author)
        await repo.authoredInFlight?.value

        #expect(repo.authoredRecipes.map(\.id) == ["a2", "a1"], "newest first, author only")
        #expect(!repo.authoredRecipes.contains { $0.pubkey == other })
        #expect(repo.hasAuthoredLoaded)
        #expect(repo.activeAuthor == author)
        // The authored session must not touch the main feed or mark it loaded.
        #expect(repo.recipes.isEmpty)
        #expect(!repo.hasLoaded)
    }

    @Test func authorFeedFilter_comesFromTheFormatSeam() {
        let repo = RecipeRepository(relays: [])
        let filter = repo.authorFeedFilter(author: author, limit: 100)
        #expect(filter.kinds == [RecipeParser.recipeKind])
        #expect(filter.authors == [author])
        #expect(filter.tTags == RecipeParser.recipeHashtags)
        #expect(filter.limit == 100)
    }

    /// A relay answering an `authors` filter loosely must not leak someone
    /// else's recipe into Published — `ingestAuthored` re-filters by pubkey.
    @Test func ingestAuthored_dropsForeignPubkeys() async {
        let repo = RecipeRepository(relays: [], seedCache: { [] })
        repo.loadAuthoredFeed(author: author)
        await repo.authoredInFlight?.value

        repo.ingestAuthored([
            recipe(id: "a1", author: author, dTag: "tuscan-peposo"),
            recipe(id: "b1", author: other, dTag: "meatloaf"),
        ])
        #expect(repo.authoredRecipes.map(\.id) == ["a1"])
    }

    // MARK: - Duplicate-coordinate tiebreaker (NIP-01)

    @Test func authoredFeed_duplicateCoordinate_equalCreatedAt_lowerIdWins() async {
        let highId = recipe(
            id: "ff" + String(repeating: "0", count: 62),
            author: author,
            dTag: "tuscan-peposo",
            createdAt: 1_700_000_000
        )
        let lowId = recipe(
            id: "00" + String(repeating: "1", count: 62),
            author: author,
            dTag: "tuscan-peposo",
            createdAt: 1_700_000_000
        )

        let repo = RecipeRepository(relays: [], seedCache: { [highId, lowId] })
        repo.loadAuthoredFeed(author: author)
        await repo.authoredInFlight?.value

        #expect(repo.authoredRecipes.count == 1)
        #expect(repo.authoredRecipes.first?.id == lowId.id)
    }

    @Test func authoredFeed_duplicateCoordinate_newerCreatedAtWins() async {
        let older = recipe(id: "ff", author: author, dTag: "tuscan-peposo", createdAt: 1_700_000_000)
        let newer = recipe(id: "00", author: author, dTag: "tuscan-peposo", createdAt: 1_700_000_005)

        let repo = RecipeRepository(relays: [], seedCache: { [older, newer] })
        repo.loadAuthoredFeed(author: author)
        await repo.authoredInFlight?.value

        #expect(repo.authoredRecipes.count == 1)
        #expect(repo.authoredRecipes.first?.id == newer.id)
    }

    // MARK: - HiddenRecipes inherited

    /// A HiddenRecipes coordinate authored by the signed-in pubkey must not
    /// appear in Published — the hide is applied inside the repository's one
    /// reduction, not re-filtered in views.
    @Test func authoredFeed_hiddenCoordinate_ownAuthor_neverAppears() async {
        let hidden = recipe(id: "h1", author: author, dTag: "ios-2.3-live-publish-golden")
        #expect(HiddenRecipes.isHidden(hidden), "fixture must match the hide-list d-tag prefix")
        let visible = recipe(id: "v1", author: author, dTag: "shakshuka")

        let repo = RecipeRepository(relays: [], seedCache: { [hidden, visible] })
        repo.loadAuthoredFeed(author: author)
        await repo.authoredInFlight?.value

        #expect(repo.authoredRecipes.map(\.id) == ["v1"])
    }

    // MARK: - One-shot load / re-query paths

    @Test func loadAuthoredFeed_isOneShotPerAuthor() async {
        let repo = RecipeRepository(relays: [], seedCache: { [self.recipe(id: "a1", author: self.author, dTag: "tuscan-peposo")] })
        repo.loadAuthoredFeed(author: author)
        await repo.authoredInFlight?.value
        #expect(repo.hasAuthoredLoaded)

        // A `.task` re-run with the same author must not resubmit — a
        // resubmit would raise `isAuthoredLoading` synchronously (§7.4).
        repo.loadAuthoredFeed(author: author)
        #expect(!repo.isAuthoredLoading)
        #expect(repo.authoredRecipes.map(\.id) == ["a1"])
    }

    // MARK: - Delete propagation (contract 1)

    @Test func removeRecipe_evictsEverySession_andBlocksLaggardResurrection() async {
        let mine = recipe(id: "a1", author: author, dTag: "tuscan-peposo", createdAt: 1_700_000_000)
        let coordinate = RecipeRepository.coordinate(mine)

        let repo = RecipeRepository(relays: [], seedCache: { [mine] })
        repo.ingest([mine])
        repo.loadAuthoredFeed(author: author)
        await repo.authoredInFlight?.value
        #expect(repo.recipes.map(\.id) == ["a1"])
        #expect(repo.authoredRecipes.map(\.id) == ["a1"])
        #expect(repo.cached(author: author, dTag: "tuscan-peposo")?.id == "a1")

        repo.removeRecipe(coordinate: coordinate, asOf: mine.createdAt)

        #expect(repo.recipes.isEmpty)
        #expect(repo.authoredRecipes.isEmpty)
        #expect(repo.cached(author: author, dTag: "tuscan-peposo") == nil)
        #expect(await repo.requestRecipe(author: author, dTag: "tuscan-peposo") == nil)

        // A laggard relay still serving the deleted version must not
        // resurrect the card mid-session — in any session.
        repo.ingest([mine])
        repo.ingestAuthored([mine])
        #expect(repo.recipes.isEmpty)
        #expect(repo.authoredRecipes.isEmpty)

        // A strictly newer republish at the coordinate is a new recipe and
        // revives the address (Android's unmark path).
        let republished = recipe(id: "a9", author: author, dTag: "tuscan-peposo", createdAt: 1_700_000_001)
        repo.ingest([republished])
        #expect(repo.recipes.map(\.id) == ["a9"])
    }
}
