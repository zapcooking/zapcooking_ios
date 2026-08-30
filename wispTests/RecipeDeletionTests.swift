import Foundation
import Testing
@testable import wisp

/// Gate for recipe deletion (`RecipeDeletion`) — the tag shape of the two events
/// the web publishes to delete a recipe, plus the two properties that decide
/// whether a delete actually lands:
///
///  - the tombstone addresses **the event being deleted** (its kind, its `d`),
///    never a re-derived or hardcoded one;
///  - the blanked replacement is **not a recipe** to any reader here, so a
///    deleted recipe leaves no "[Deleted]" ghost in the feeds.
///
/// Port of Android `RecipeDeletionTest`.
struct RecipeDeletionTests {

    private let author = String(repeating: "ab", count: 32)

    /// Smallest valid recipe template — needed so the "the original IS a
    /// recipe" half of the ghost test isn't vacuous.
    private let recipeBody = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."

    private func recipe(
        kind: Int = RecipeParser.recipeKind,
        d: String? = "tuscan-peposo",
        createdAt: Int = 1_700_000_000,
        pubkey: String? = nil
    ) -> NostrEvent {
        var tags: [[String]] = []
        if let d { tags.append(["d", d]) }
        tags.append(["t", "zapcooking"])
        tags.append(["title", "Tuscan Peposo"])
        return NostrEvent(
            id: String(repeating: "ee", count: 32),
            pubkey: pubkey ?? author,
            kind: kind,
            createdAt: createdAt,
            tags: tags,
            content: recipeBody,
            sig: String(repeating: "0", count: 128)
        )
    }

    // MARK: - blanked replacement

    @Test func blankedReplacement_carriesTheSameDTagAndTheWebsMarkers() {
        let tags = RecipeDeletion.blankedReplacementTags(recipe())
        #expect(tags == [
            ["d", "tuscan-peposo"],
            ["deleted", "true"],
            ["title", "[Deleted]"],
        ])
    }

    @Test func blankedReplacement_omitsDTagWhenTheRecipeHasNone() {
        #expect(
            RecipeDeletion.blankedReplacementTags(recipe(d: nil))
                == [["deleted", "true"], ["title", "[Deleted]"]]
        )
        // A blank `d` is the same case — there is nothing to address with.
        #expect(
            RecipeDeletion.blankedReplacementTags(recipe(d: "   "))
                == [["deleted", "true"], ["title", "[Deleted]"]]
        )
    }

    /// The load-bearing property: a blanked replacement is not a recipe, so it
    /// resolves to no format and never renders. Without this, deleting would
    /// leave a "[Deleted]" card in every recipe feed.
    @Test func blankedReplacement_isNotARecipe() {
        let original = recipe()
        #expect(RecipeParser.isRecipe(original), "fixture must be a recipe or the assertion below is vacuous")

        let blanked = NostrEvent(
            id: original.id,
            pubkey: original.pubkey,
            kind: original.kind,
            createdAt: RecipeDeletion.deletionTimestamp(original, now: 1_800_000_000),
            tags: RecipeDeletion.blankedReplacementTags(original),
            content: RecipeDeletion.tombstoneContent,
            sig: original.sig
        )
        #expect(!RecipeParser.isRecipe(blanked))
        #expect(RecipeFormats.forEvent(blanked) == nil)
    }

    /// The article surfaces route on `kind == 30023` alone, so the blanked
    /// replacement has to be recognisable *as a tombstone*.
    @Test func blankedReplacement_isRecognisableAsATombstone() {
        let original = recipe()
        #expect(!RecipeDeletion.isBlankedReplacement(original), "a live recipe must not look like a tombstone")

        let blanked = NostrEvent(
            id: original.id,
            pubkey: original.pubkey,
            kind: original.kind,
            createdAt: original.createdAt,
            tags: RecipeDeletion.blankedReplacementTags(original),
            content: RecipeDeletion.tombstoneContent,
            sig: original.sig
        )
        #expect(RecipeDeletion.isBlankedReplacement(blanked))

        let noD = NostrEvent(
            id: original.id,
            pubkey: original.pubkey,
            kind: original.kind,
            createdAt: original.createdAt,
            tags: RecipeDeletion.blankedReplacementTags(recipe(d: nil)),
            content: original.content,
            sig: original.sig
        )
        #expect(RecipeDeletion.isBlankedReplacement(noD))
    }

    /// And it is not a recipe for **two independent** reasons, so the property
    /// survives a change to either half.
    @Test func blankedReplacement_failsBothHalvesOfTheRecipeGate() {
        let original = recipe()

        let noT = NostrEvent(
            id: original.id,
            pubkey: original.pubkey,
            kind: original.kind,
            createdAt: original.createdAt,
            tags: RecipeDeletion.blankedReplacementTags(original),
            content: original.content,
            sig: original.sig
        )
        #expect(!RecipeParser.isRecipe(noT))

        var tags = RecipeDeletion.blankedReplacementTags(original)
        tags.append(["t", "zapcooking"])
        let blankContent = NostrEvent(
            id: original.id,
            pubkey: original.pubkey,
            kind: original.kind,
            createdAt: original.createdAt,
            tags: tags,
            content: RecipeDeletion.tombstoneContent,
            sig: original.sig
        )
        #expect(!RecipeParser.isRecipe(blankContent))
    }

    // MARK: - kind-5 deletion request

    @Test func deletionRequest_addressesTheCoordinateTheKindAndTheEventId() {
        let event = recipe()
        #expect(RecipeDeletion.deletionRequestTags(event) == [
            ["a", "30023:\(author):tuscan-peposo"],
            ["k", "30023"],
            ["e", event.id],
        ])
    }

    /// Kind comes off the event. A hardcoded 30023 is the web defect that
    /// points a premium recipe's tombstone at the author's public recipe of the
    /// same name — this repo has one recipe kind today, so the test is the guard.
    @Test func deletionRequest_usesTheEventsOwnKindNotTheDefault() {
        let tags = RecipeDeletion.deletionRequestTags(recipe(kind: 35000))
        #expect(tags[0] == ["a", "35000:\(author):tuscan-peposo"])
        #expect(tags[1] == ["k", "35000"])
    }

    @Test func deletionRequest_dropsTheCoordinateButKeepsTheIdWhenThereIsNoDTag() {
        let event = recipe(d: nil)
        #expect(RecipeDeletion.deletionRequestTags(event) == [
            ["k", "30023"],
            ["e", event.id],
        ])
    }

    // MARK: - timestamp

    @Test func deletionTimestamp_isNowWhenTheClockIsAheadOfTheRecipe() {
        let now = 1_800_000_000
        #expect(RecipeDeletion.deletionTimestamp(recipe(createdAt: 1_700_000_000), now: now) == now)
    }

    /// NIP-09 voids only `created_at <= deletion`, and a replacement must be
    /// newer to supersede — so a device clock at or behind the recipe's stamp
    /// must still produce a strictly newer tombstone, not a no-op.
    @Test func deletionTimestamp_stepsPastARecipeDatedAtOrAfterNow() {
        let stamp = 1_900_000_000
        #expect(RecipeDeletion.deletionTimestamp(recipe(createdAt: stamp), now: stamp) == stamp + 1)
        #expect(RecipeDeletion.deletionTimestamp(recipe(createdAt: stamp), now: stamp - 500) == stamp + 1)
    }

    // MARK: - future-date ceiling

    @Test func isDeletableNow_refusesARecipeDatedPastTheFutureCeiling() {
        let now = 1_800_000_000
        let grace = RecipeDeletion.futureDateGraceSeconds

        // The exact boundary: created_at + 1 == now + grace still lands.
        #expect(RecipeDeletion.isDeletableNow(recipe(createdAt: now + grace - 1), now: now))
        // One second further and the tombstone is itself dropped as future-dated.
        #expect(!RecipeDeletion.isDeletableNow(recipe(createdAt: now + grace), now: now))
        #expect(!RecipeDeletion.isDeletableNow(recipe(createdAt: now + 86_400), now: now))
    }

    @Test func isDeletableNow_allowsAnOrdinaryRecipe() {
        let now = 1_800_000_000
        #expect(RecipeDeletion.isDeletableNow(recipe(createdAt: 1_700_000_000), now: now))
        #expect(RecipeDeletion.isDeletableNow(recipe(createdAt: now), now: now))
    }

    // MARK: - d-tag extraction

    @Test func dTagOf_readsTheFirstDTagAndTreatsBlankAsAbsent() {
        #expect(RecipeDeletion.dTagOf(recipe()) == "tuscan-peposo")
        #expect(RecipeDeletion.dTagOf(recipe(d: nil)) == nil)
        #expect(RecipeDeletion.dTagOf(recipe(d: "")) == nil)
    }
}
