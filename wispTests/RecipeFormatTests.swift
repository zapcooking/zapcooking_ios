import Foundation
import Testing
@testable import wisp

/// Gate for the format-agnostic half of the recipe seam — `recipeKey` and
/// `dedupeAcrossFormats`, both free functions in `RecipeFormat.swift`.
///
/// Ported from Android `RecipeFormatTest` @ `68242f5`. That file's 12 cases are
/// split across three suites here by the entry point each one calls, not by
/// filename: the 5 below reach `RecipeFormat.swift`, 3 reach `RecipeFormats`
/// (`RecipeFormatsTests`), and 4 reach the adapter (`Nip23RecipeFormatTests`).
///
/// Proves `dedupeAcrossFormats` is a **true pass-through while one format is
/// active**, and that the cross-format canonical-pick order
/// `(rank desc, created_at desc, id asc)` is correct — simulated via the
/// `rankOf` closure, since no second format is registered.
struct RecipeFormatTests {

    // Minimal recipe-template body: kind + `#t zapcooking` alone no longer make
    // a recipe — the content must pass RecipeParser.validateMarkdownTemplate, so
    // the stub carries the smallest valid template (one ingredient + one step).
    private static let recipeBody = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."

    private func stub(
        id: String,
        createdAt: Int,
        author: String = String(repeating: "p", count: 64),
        d: String = "x"
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: author,
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: [["d", d], ["t", "zapcooking"]],
            content: Self.recipeBody,
            sig: String(repeating: "0", count: 128)
        )
    }

    /// Kotlin's `NostrEvent` is a data class, so its tests compare events with
    /// value equality. The Swift type is not `Equatable`, and adding that
    /// conformance would mean editing `NostrEvent.swift` — a file this concern
    /// does not own, and a conformance the app module may want to define itself.
    /// Compared field-by-field here instead, which is what data-class equality
    /// does anyway.
    private func same(_ a: NostrEvent, _ b: NostrEvent) -> Bool {
        a.id == b.id && a.pubkey == b.pubkey && a.kind == b.kind
            && a.createdAt == b.createdAt && a.tags == b.tags
            && a.content == b.content && a.sig == b.sig
    }

    private func same(_ a: [NostrEvent], _ b: [NostrEvent]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
    }

    // MARK: - RecipeKey

    @Test func recipeKey_isAuthorPlusDTag_kindIndependent() {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            return
        }
        #expect(
            recipeKey(event) == RecipeKey(
                author: "1852d83e2b9d12fa561071bfe159ff5ae510af1fc9b51b85539cb6a81486f207",
                slug: "tuscan-peposo-(black-pepper-beef-stew)"
            )
        )
    }

    // MARK: - dedupeAcrossFormats: single-format pass-through

    @Test func dedupe_singleFormat_isPassThrough() {
        // Distinct recipes (different d-tags) → all survive, none collapsed.
        let a = stub(id: "aa", createdAt: 100, d: "recipe-a")
        let b = stub(id: "bb", createdAt: 100, d: "recipe-b")
        let out = dedupeAcrossFormats([a, b]) { RecipeFormats.rankOf($0) }
        #expect(out.count == 2)
        #expect(out.contains { same($0, a) })
        #expect(out.contains { same($0, b) })
    }

    @Test func dedupe_dropsEventsWithNoActiveFormat() {
        let recipe = stub(id: "aa", createdAt: 100)
        // Kotlin uses `recipe.copy(id = "bb", kind = 1)`; NostrEvent's Swift
        // properties are `let`, so the copy is spelled out. rankOf → nil.
        let notARecipe = NostrEvent(
            id: "bb",
            pubkey: recipe.pubkey,
            kind: 1,
            createdAt: recipe.createdAt,
            tags: recipe.tags,
            content: recipe.content,
            sig: recipe.sig
        )
        let out = dedupeAcrossFormats([recipe, notARecipe]) { RecipeFormats.rankOf($0) }
        #expect(same(out, [recipe]))
    }

    // MARK: - dedupeAcrossFormats: cross-format canonical-pick
    // No second format is registered, so rank is simulated via the closure.

    @Test func dedupe_crossFormat_higherRankWins_evenIfOlder() {
        // Same RecipeKey (same author + d), different "formats".
        let lowRankNewer = stub(id: "aa", createdAt: 200)  // rank 0
        let highRankOlder = stub(id: "bb", createdAt: 100) // rank 1
        let out = dedupeAcrossFormats([lowRankNewer, highRankOlder]) { $0.id == "bb" ? 1 : 0 }
        // Rank beats recency: the higher-rank (migration-target) event wins.
        #expect(same(out, [highRankOlder]))
    }

    /// Multi-key output order: a key that is overwritten by a more canonical
    /// event keeps its **original** position.
    ///
    /// Not in the Android suite, and deliberately so rather than by oversight.
    /// Kotlin gets this free from `LinkedHashMap`, whose `values` are in
    /// first-insertion order with overwrite-in-place. Swift's `Dictionary` is
    /// unordered, so the port has to reproduce the ordering by hand — and
    /// invented behaviour needs its own golden. Nothing else here would catch
    /// it: `dedupe_singleFormat_isPassThrough` is the only other multi-element
    /// case and asserts count plus membership, not order, and the remaining
    /// three assert single-element results.
    ///
    /// An implementation that appended on overwrite instead would return
    /// `[b, aNewer]` and pass every other test in this file.
    @Test func dedupe_multiKey_overwriteKeepsFirstInsertionPosition() {
        let aOlder = stub(id: "aa", createdAt: 100, d: "recipe-a")
        let b = stub(id: "bb", createdAt: 100, d: "recipe-b")
        let aNewer = stub(id: "cc", createdAt: 200, d: "recipe-a")

        // `recipe-a` is seen first, then `recipe-b`, then a better `recipe-a`.
        let out = dedupeAcrossFormats([aOlder, b, aNewer]) { RecipeFormats.rankOf($0) }
        #expect(same(out, [aNewer, b]))
    }

    @Test func dedupe_sameRank_newerWins_thenLowerId() {
        let older = stub(id: "ff", createdAt: 100)
        let newer = stub(id: "aa", createdAt: 200)
        #expect(same(dedupeAcrossFormats([older, newer]) { _ in 0 }, [newer]))

        // created_at tie → lexicographically lower id wins.
        let lowId = stub(id: "00aa", createdAt: 100)
        let highId = stub(id: "ffbb", createdAt: 100)
        #expect(same(dedupeAcrossFormats([highId, lowId]) { _ in 0 }, [lowId]))
    }
}
