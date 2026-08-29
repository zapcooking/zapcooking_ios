import Foundation
import Testing
@testable import wisp

/// Gate for the format registry — the three cases in Android
/// `RecipeFormatTest` @ `68242f5` whose entry point is `RecipeFormats`.
///
/// Proves the registry resolves real recipes to `Nip23RecipeFormat`, that the
/// strict recipe gate holds against announcement articles that merely carry the
/// recipe hashtag, and that the `Nip333RecipeFormat` stub is never in the
/// runtime registry — so its unimplemented bodies can't fire.
struct RecipeFormatsTests {

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

    // MARK: - Registry

    @Test func registry_resolvesRealRecipeToNip23() {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            return
        }
        // Kotlin asserts reference identity against an `object` singleton. The
        // Swift conformer is a struct, so identity is a type check — the same
        // assertion about which format was resolved.
        #expect(RecipeFormats.forEvent(event) is Nip23RecipeFormat)
        #expect(RecipeFormats.rankOf(event) == 0)
    }

    // MARK: - The strict gate holds on a profile of pure articles

    @Test func forEvent_rejectsAnnouncementArticlesCarryingRecipeTag() {
        // Branta-announcement precedent: an author whose kind-30023 output is
        // announcements/essays that carry `#t zapcooking` has ZERO recipes. The
        // registry predicate is the one the profile query's collector gates on,
        // so nothing reaches the Recipes grid.
        let announcement = NostrEvent(
            id: String(repeating: "e", count: 64),
            pubkey: String(repeating: "f", count: 64),
            kind: RecipeParser.recipeKind,
            createdAt: 1_700_000_000,
            tags: [["d", "announcing-branta"], ["t", "zapcooking"]],
            content: "# Announcing Branta\n\nWe are pleased to share a partnership. "
                + "No ingredients, no directions — prose only.",
            sig: String(repeating: "0", count: 128)
        )
        #expect(RecipeFormats.forEvent(announcement) == nil)
        #expect(!RecipeParser.isRecipe(announcement))

        // ...while a real recipe from the same author still resolves, so the
        // gate is content-shape, not author-wide.
        let realOne = stub(
            id: String(repeating: "1", count: 64),
            createdAt: 1,
            author: String(repeating: "f", count: 64)
        )
        #expect(RecipeFormats.forEvent(realOne) != nil)
    }

    // MARK: - Stub guard

    @Test func nip333Stub_isNotRegistered() {
        // The stub must never be iterated at runtime — its unimplemented bodies
        // can't fire. Kotlin uses `===` against a singleton; the Swift conformer
        // is a struct, so the guard is a type check.
        #expect(!RecipeFormats.active.contains { $0 is Nip333RecipeFormat })
        #expect(!(RecipeFormats.primary is Nip333RecipeFormat))
    }
}
