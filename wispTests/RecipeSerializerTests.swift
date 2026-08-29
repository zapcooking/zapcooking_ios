import Foundation
import Testing
@testable import wisp

/// Round-trip gate for `RecipeSerializer` (Concern 2.1): take the REAL Tuscan
/// Peposo recipe, serialize it back to a kind-30023 body + tags, re-parse with
/// `RecipeParser`, and assert the structured recipe is unchanged. This is what
/// guarantees app-published recipes match web-authored ones.
///
/// Ported from Android `RecipeSerializerTest` @ `68242f5` (8 tests) plus the
/// one create-path guard from `RecipeEditSerializerTest` that calls
/// `RecipeSerializer.toTags` directly — 9 goldens. The other 12 cases in that
/// file reach `Nip23RecipeFormat`, not this type, and belong to Concern 2.2;
/// they are classified by the entry point each one calls, not by filename.
///
/// The fixture is `RecipeParserTests.tuscanPeposoJSON` — the same frozen bytes,
/// referenced rather than transcribed. Android reads it off the test classpath;
/// here it is already an inline literal in the test module, so a second copy
/// would be 5 KB of hand-frozen bytes that can drift with no visible diff.
struct RecipeSerializerTests {

    // MARK: - Fixture

    private func tuscanEvent() -> NostrEvent {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            fatalError("fixture decode failed")
        }
        return event
    }

    private func tuscan() -> RecipeParser.Recipe { RecipeParser.parse(tuscanEvent()) }

    /// Build a synthetic 30023 event from serialized content+tags, then parse it.
    private func roundTrip(_ recipe: RecipeParser.Recipe) -> RecipeParser.Recipe {
        let content = RecipeSerializer.toContent(recipe)
        let tags = RecipeSerializer.toTags(
            title: recipe.title!,
            summary: recipe.summary,
            imageUrls: recipe.image.map { [$0] } ?? [],
            categories: recipe.categories
        )
        let event = NostrEvent(
            id: String(repeating: "f", count: 64),
            pubkey: recipe.author,
            kind: RecipeParser.recipeKind,
            createdAt: 1_700_000_000,
            tags: tags,
            content: content,
            sig: String(repeating: "0", count: 128)
        )
        return RecipeParser.parse(event)
    }

    private func values(_ tags: [[String]], _ name: String) -> [String] {
        tags.filter { $0.count >= 2 && $0[0] == name }.map { $0[1] }
    }

    // MARK: - Round trip

    @Test func roundTrip_preservesMetadata() {
        let original = tuscan()
        let again = roundTrip(original)
        #expect(again.title == original.title)
        #expect(again.summary == original.summary)
        #expect(again.image == original.image)
        // d-tag = slug(title); for a web-authored recipe that equals the original.
        #expect(again.dTag == original.dTag)
        #expect(again.categories == original.categories)
    }

    @Test func roundTrip_preservesBody() {
        let original = tuscan()
        let again = roundTrip(original)
        #expect(again.content.chefNotes == original.content.chefNotes)
        #expect(again.content.details == original.content.details)
        #expect(again.content.ingredients == original.content.ingredients)
        #expect(again.content.directions == original.content.directions)
        #expect(again.content.additionalMarkdown == original.content.additionalMarkdown)
    }

    @Test func roundTrip_preservesHashtagSet() {
        let original = tuscan()
        let again = roundTrip(original)
        // Same set of #t tags (root + per-recipe slug + categories).
        #expect(Set(again.hashtags) == Set(original.hashtags))
    }

    // MARK: - Byte-for-byte web parity

    @Test func serializedContent_isByteIdenticalToWebAuthoredEvent() {
        // The frozen Tuscan event was authored by the web's createMarkdown.
        // Our serializer mirrors it, so re-serializing the parsed recipe must
        // reproduce the original content byte-for-byte (the real "byte-for-byte
        // web parity" gate, beyond the lenient semantic round-trip above).
        let event = tuscanEvent()
        #expect(RecipeSerializer.toContent(RecipeParser.parse(event)) == event.content)
    }

    @Test func serializedTags_matchWebAuthoredEvent_exceptClientTag() {
        let event = tuscanEvent()
        let recipe = RecipeParser.parse(event)
        let produced = Set(
            RecipeSerializer.toTags(
                title: recipe.title!,
                summary: recipe.summary,
                imageUrls: recipe.image.map { [$0] } ?? [],
                categories: recipe.categories
            )
        )
        // Web event carries a `client` tag the serializer omits (added at publish).
        let expected = Set(event.tags.filter { $0.first != "client" })
        #expect(produced == expected)
    }

    // MARK: - Slug and body shape

    @Test func slug_isSpacesOnly_keepsParens() {
        #expect(
            RecipeSerializer.slug("Tuscan Peposo (Black Pepper Beef Stew)")
                == "tuscan-peposo-(black-pepper-beef-stew)"
        )
    }

    @Test func toContent_usesEmojiDetailLabels_andBulletsAndNumbers() {
        let content = RecipeSerializer.toContent(tuscan())
        // U+23F2 U+FE0F — the variation selector is part of the frozen bytes.
        #expect(content.contains("- \u{23F2}\u{FE0F} Prep time: 10 min"))
        // U+1F373 — no variation selector on this one. The asymmetry is real.
        #expect(content.contains("- \u{1F373} Cook time: 3 hours"))
        #expect(content.contains("\n- 750 ml red wine\n"))
        #expect(content.contains("\n1. Cut beef into large chunks.\n"))
        // Tuscan has no servings → no servings line.
        #expect(!content.contains("Servings"))
    }

    @Test func toTags_omitsPublishedAt() {
        let tags = RecipeSerializer.toTags(
            title: "X Y", summary: "s", imageUrls: ["u"], categories: ["Italian"]
        )
        #expect(!tags.contains { $0.first == "published_at" })
        #expect(tags.contains(["d", "x-y"]))
        #expect(tags.contains(["t", "zapcooking"]))
        #expect(tags.contains(["t", "zapcooking-x-y"]))
        #expect(tags.contains(["t", "zapcooking-italian"]))
        #expect(tags.contains(["image", "u"]))
    }

    // MARK: - D2 regression guard: the create path does not move

    @Test func create_tagsAreUnchanged_noIdentifierNoPublishedAt() {
        let tags = RecipeSerializer.toTags(
            title: "X Y", summary: "s", imageUrls: ["u"], categories: ["Italian"]
        )
        #expect(!tags.contains { $0.first == "published_at" })
        #expect(values(tags, "d") == ["x-y"])
        #expect(tags.contains(["t", "zapcooking-x-y"]))
    }
}
