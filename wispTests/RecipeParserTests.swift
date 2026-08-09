import Foundation
import Testing
@testable import wisp

/// Golden conformance for `RecipeParser` against a **real** zap.cooking
/// recipe — the "Tuscan Peposo" event (kind 30023, `#t zapcooking`) fetched
/// live from `relay.primal.net` during Android Step-0 investigation and frozen
/// byte-for-byte. Ported from Android `RecipeParserTest` @ `4389530`.
///
/// This pins the two drift cases Step 0 surfaced (build doc §Phase 1 / §7.7):
///  - the event has **no `published_at` tag** → `Recipe.publishedAt` must fall
///    back to `created_at`;
///  - the `## Details` block has prep + cook but **no servings** → the servings
///    field must be nil, not an empty string or a crash.
///
/// **The fixture is an inline string literal, not a bundle resource.** Android
/// loads it off the test classpath; iOS has no equivalent that does not require
/// registering a resource in `project.pbxproj` (build doc §6: that file is a
/// trap, and a hand-merged conflict can silently drop a file from a build
/// phase). `NSpamTests` already documents that test-bundle resources here are
/// unreliable. The bytes are identical to
/// `app/src/test/resources/recipes/tuscan_peposo.json` @ `4389530`
/// (sha256 63c21e626f06216e2e52c1a370b6ce2e99586cee90109664c367127356a9f642),
/// and `realEmojiDetails_...` below fails loudly if the hard bytes are ever
/// lost in transcription.
///
/// Emoji in test inputs are written as `\u{...}` escapes, not pasted glyphs:
/// `⏲️` (U+23F2 U+FE0F) and `⏲` (U+23F2 alone) are indistinguishable by eye but
/// are the entire point of two of these tests. An editor pass that "normalizes"
/// the glyphs would weaken the golden with no visible diff.
struct RecipeParserTests {

    // MARK: - Fixture

    /// The real Tuscan Peposo event, verbatim as the relay sent it.
    private static let tuscanPeposoJSON = #"{"content": "\n## Chef's notes\n\nPeposo comes from Impruneta near Florence, traditionally cooked for hours over low heat. The secret is time, black pepper, and patience. A little tomato paste adds depth without changing its rustic identity.\n\n## Details\n\n- ⏲️ Prep time: 10 min\n- 🍳 Cook time: 3 hours\n\n## Ingredients\n\n- 1 kg beef for stewing (chuck or similar)\n- 750 ml red wine\n- 4 garlic cloves\n- 2 tbsp black pepper (coarsely ground)\n- 1 tbsp tomato paste\n- Salt\n- Extra virgin olive oil\n\n\n## Directions\n\n1. Cut beef into large chunks.\n2. Place in a pot with garlic, black pepper, tomato paste, and a drizzle of olive oil.\n3. Add red wine to almost cover the meat.\n4. Cook on very low heat for about 3 hours.\n5. Stir occasionally, add a little water if needed.\n6. Rest 10 minutes, adjust salt, serve hot.\n", "created_at": 1776632470, "id": "19fec9967054f84cedf6c74c095f544f9630464913c7c9543b2e1cc6640ff2bb", "kind": 30023, "pubkey": "1852d83e2b9d12fa561071bfe159ff5ae510af1fc9b51b85539cb6a81486f207", "sig": "40fbacfe1d01511f4194d3fc44174a7e93a82f27c8c1caed27b1a3d09340af75cd3e900ed179b7d51186ed83fe2692a6e6116303c5c856465ea6e9bc734a35a1", "tags": [["d", "tuscan-peposo-(black-pepper-beef-stew)"], ["title", "Tuscan Peposo (Black Pepper Beef Stew)"], ["t", "zapcooking"], ["t", "zapcooking-tuscan-peposo-(black-pepper-beef-stew)"], ["summary", "A bold Tuscan beef stew cooked with red wine, garlic, black pepper, and a touch of tomato. Simple ingredients, deep flavour."], ["image", "https://image.nostr.build/95df427de745f56529810d928a4b6dd059f972fd5aee86efc618cd92023486ad.jpg"], ["t", "zapcooking-italian"], ["t", "zapcooking-beef"], ["t", "zapcooking-stew"], ["t", "zapcooking-slowcooked"], ["client", "zap.cooking"]]}"#

    private func loadEvent() -> NostrEvent {
        guard let event = NostrEvent.fromJSON(Self.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            fatalError("fixture decode failed")
        }
        return event
    }

    private var recipe: RecipeParser.Recipe { RecipeParser.parse(loadEvent()) }

    // MARK: - Golden: the real event

    @Test func isRecipe_recognizesRealEvent() {
        #expect(RecipeParser.isRecipe(loadEvent()))
    }

    @Test func parsesAddressableCoordinatesAndTopTags() {
        let recipe = recipe
        #expect(recipe.id == "19fec9967054f84cedf6c74c095f544f9630464913c7c9543b2e1cc6640ff2bb")
        #expect(recipe.author == "1852d83e2b9d12fa561071bfe159ff5ae510af1fc9b51b85539cb6a81486f207")
        #expect(recipe.dTag == "tuscan-peposo-(black-pepper-beef-stew)")
        #expect(recipe.title == "Tuscan Peposo (Black Pepper Beef Stew)")
        #expect(
            recipe.image
                == "https://image.nostr.build/95df427de745f56529810d928a4b6dd059f972fd5aee86efc618cd92023486ad.jpg"
        )
        #expect(
            recipe.summary
                == "A bold Tuscan beef stew cooked with red wine, garlic, black pepper, "
                + "and a touch of tomato. Simple ingredients, deep flavour."
        )
    }

    @Test func missingPublishedAt_fallsBackToCreatedAt() {
        // The live event carries no `published_at` tag; created_at is 1776632470.
        #expect(recipe.publishedAt == 1_776_632_470)
    }

    @Test func derivesCategories_excludingRootAndSlugTags() {
        let recipe = recipe
        // t-tags: zapcooking, zapcooking-<slug>, zapcooking-italian/-beef/-stew/-slowcooked
        #expect(recipe.categories == ["italian", "beef", "stew", "slowcooked"])
        // Raw hashtags are preserved verbatim.
        #expect(recipe.hashtags.contains("zapcooking"))
        #expect(recipe.hashtags.contains("zapcooking-tuscan-peposo-(black-pepper-beef-stew)"))
    }

    @Test func parsesChefNotes() {
        #expect(
            recipe.content.chefNotes
                == "Peposo comes from Impruneta near Florence, traditionally cooked for hours "
                + "over low heat. The secret is time, black pepper, and patience. A little "
                + "tomato paste adds depth without changing its rustic identity."
        )
    }

    @Test func parsesDetails_prepAndCookPresent_servingsAbsent() {
        let details = recipe.content.details
        #expect(details.prepTime == "10 min")
        #expect(details.cookTime == "3 hours")
        #expect(details.servings == nil)
    }

    /// The one spot where a clean regex passes synthetic input but misses real
    /// events: the `## Details` emoji labels carry U+FE0F variation selectors in
    /// the live bytes. This proves the REAL event's prep AND cook extract to
    /// non-nil actual values — i.e. the emoji handling works on production
    /// bytes, not just on hand-typed glyphs.
    @Test func realEmojiDetails_extractNonNull_despiteVariationSelector() {
        // Guard: the fixture must actually contain the hard case (⏲️ = U+23F2
        // U+FE0F). If someone "cleans" the fixture and drops the selector, this
        // fails loudly rather than silently weakening the golden.
        //
        // Asserted at the unicode-scalar level, not with `String.contains`:
        // Swift string comparison applies canonical equivalence, so a
        // grapheme-level check is the wrong instrument for "are these exact
        // scalars present".
        let scalars = Array(loadEvent().content.unicodeScalars)
        let hardCase: [Unicode.Scalar] = ["\u{23F2}", "\u{FE0F}"]
        let hasSelector = scalars.indices.dropLast().contains { i in
            scalars[i] == hardCase[0] && scalars[i + 1] == hardCase[1]
        }
        #expect(
            hasSelector,
            "fixture lost its U+FE0F variation selector — golden no longer exercises the hard path"
        )

        let details = recipe.content.details
        #expect(details.prepTime != nil, "real ⏲️ Prep time (U+23F2 U+FE0F) must extract")
        #expect(details.cookTime != nil, "real 🍳 Cook time (U+1F373) must extract")
        #expect(details.prepTime == "10 min")
        #expect(details.cookTime == "3 hours")
    }

    @Test func details_tolerateMissingVariationSelectorAndMultiSpace() {
        // Base emoji without U+FE0F + irregular spacing — a stricter regex
        // would miss these; the hardened one must not.
        // ⏲ = U+23F2 (no selector), 🍽 = U+1F37D (no selector).
        let md = "## Details\n\n- \u{23F2}  Prep time:  12 min\n- \u{1F37D}   Servings:   4\n"
        let d = RecipeParser.parseContent(md).details
        #expect(d.prepTime == "12 min")  // ⏲ with NO selector, double space
        #expect(d.servings == "4")       // 🍽 with NO selector, triple space
    }

    @Test func parsesIngredients_asBulletList() {
        #expect(
            recipe.content.ingredients == [
                "1 kg beef for stewing (chuck or similar)",
                "750 ml red wine",
                "4 garlic cloves",
                "2 tbsp black pepper (coarsely ground)",
                "1 tbsp tomato paste",
                "Salt",
                "Extra virgin olive oil",
            ]
        )
    }

    @Test func parsesDirections_strippingStepNumbers() {
        let directions = recipe.content.directions
        #expect(directions.count == 6)
        #expect(directions.first == "Cut beef into large chunks.")
        #expect(directions.last == "Rest 10 minutes, adjust salt, serve hot.")
    }

    @Test func noAdditionalResourcesSection_yieldsNull() {
        #expect(recipe.content.additionalMarkdown == nil)
    }

    // MARK: - Synthetic edge cases for drift the single fixture can't cover

    @Test func details_servingsAndEmoji_parseLikeTheFrontend() {
        // Mirrors live "Spicy Hot Chocolate": prep with no unit, servings present.
        // ⏲️ = U+23F2 U+FE0F · 🍳 = U+1F373 (bare) · 🍽️ = U+1F37D U+FE0F.
        let md = """
            ## Details

            - \u{23F2}\u{FE0F} Prep time: 10
            - \u{1F373} Cook time: 5 min
            - \u{1F37D}\u{FE0F} Servings: 2
            """
        let d = RecipeParser.parseContent(md).details
        #expect(d.prepTime == "10")  // free-text, no unit, never assumed numeric
        #expect(d.cookTime == "5 min")
        #expect(d.servings == "2")
    }

    @Test func directions_keepSectionHeaderPseudoSteps_flat() {
        // Mirrors live "Japanese Milk Bread" where "1. Tangzhong:" is itself a step.
        let md = """
            ## Directions

            1. Tangzhong:
            2. Place the water in a small saucepan.
            """
        let steps = RecipeParser.parseContent(md).directions
        #expect(steps == ["Tangzhong:", "Place the water in a small saucepan."])
    }

    @Test func emptyBody_yieldsEmptyContent_noCrash() {
        let c = RecipeParser.parseContent("")
        #expect(c.chefNotes == nil)
        #expect(c.details.isEmpty)
        #expect(c.ingredients.isEmpty)
        #expect(c.directions.isEmpty)
        #expect(c.additionalMarkdown == nil)
    }

    // MARK: - Strict content-shape gate (port of validateMarkdownTemplate)
    //
    // recipes and articles share kind 30023 + can both carry `#t zapcooking`,
    // so the recipe feed additionally requires the content to be recipe-shaped.
    // Ground truth cross-checked against the web validator (`src/lib/parser.ts`).

    private func event(kind: Int, content: String, tTags: [String]) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: String(repeating: "1", count: 64),
            kind: kind,
            createdAt: 1_700_000_000,
            tags: tTags.map { ["t", $0] },
            content: content,
            sig: String(repeating: "2", count: 128)
        )
    }

    @Test func validate_acceptsRealRecipe() {
        let result = RecipeParser.validateMarkdownTemplate(loadEvent().content)
        #expect(result.isValid)
        guard let template = result.template else {
            Issue.record("expected a valid template")
            return
        }
        #expect(template.ingredients.count == 7)
        #expect(template.directions.count == 6)
        // Lock in that the LAST real line of each section survives.
        // `components(separatedBy:)` KEEPS trailing empty strings — unlike
        // Swift's `split(separator:)`, which omits them by default — so the
        // `slice(1, -1)` middle-slice drops only the trailing blank line the
        // section regex captures, never the last ingredient/step. If the split
        // dropped trailing empties this would under-count (6 ingredients) and
        // fail.
        #expect(template.ingredients.first == "1 kg beef for stewing (chuck or similar)")
        #expect(template.ingredients.last == "Extra virgin olive oil")
        #expect(template.directions.last == "Rest 10 minutes, adjust salt, serve hot.")
    }

    @Test func validate_singleIngredientRecipe_accepted() {
        // Web parity (cross-checked): a one-ingredient recipe is ACCEPTed and the
        // sole ingredient is retained — proves the middle-slice doesn't eat the
        // only real line when trailing empties are kept.
        let md = "## Ingredients\n\n- flour\n\n## Directions\n\n1. Bake."
        let r = RecipeParser.validateMarkdownTemplate(md)
        #expect(r.isValid)
        #expect(r.template?.ingredients == ["flour"])
    }

    @Test func isRecipe_rejectsArticleCarryingRecipeTag() {
        // A plain long-form ARTICLE that happens to carry `#t zapcooking` but has
        // no recipe-template body MUST NOT be treated as a recipe.
        let article = event(
            kind: RecipeParser.recipeKind,
            content: "# My Thoughts on Food\n\nA long essay about the #zapcooking community. "
                + "No ingredients, no directions — just prose.",
            tTags: ["zapcooking"]
        )
        #expect(!RecipeParser.isRecipe(article))
    }

    @Test func isRecipe_stillAcceptsRealRecipeEvent() {
        // The tightened gate must not regress real recipes.
        #expect(RecipeParser.isRecipe(loadEvent()))
    }

    @Test func validate_rejectsWhenNoSections() {
        let r = RecipeParser.validateMarkdownTemplate("Just a paragraph with no headings at all.")
        #expect(!r.isValid)
    }

    @Test func validate_rejectsHeadingsThatArentRecipeSections() {
        // Has `## ` sections, but no Ingredients/Directions → too short.
        let md = "## Introduction\nHello world here.\n\n## Conclusion\nGoodbye world here."
        #expect(!RecipeParser.isRecipeContent(md))
    }

    @Test func validate_rejectsProseDirections() {
        // Ingredients present, but Directions is prose, not a numbered list.
        let md = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n"
            + "First you mix things then bake. This is prose not a numbered list."
        #expect(!RecipeParser.isRecipeContent(md))
    }

    @Test func validate_rejectsNonSequentialDirections() {
        let md = "## Ingredients\n\n- flour\n\n## Directions\n\n1. Mix.\n3. Bake."
        #expect(!RecipeParser.isRecipeContent(md))
    }

    @Test func validate_acceptsMinimalRecipe() {
        // The web's minimum: at least one ingredient and one ordered direction.
        // Directions is the trailing section so slice(1) keeps every step; the
        // Ingredients section is followed by Directions, so its last line is the
        // blank line slice(1, -1) drops — both ingredients survive.
        let md = "## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."
        #expect(RecipeParser.isRecipeContent(md))
    }

    // MARK: - iOS-only: regex-dialect guard (no Android counterpart)

    /// **Not a port — this test exists only on iOS**, because the bug it guards
    /// exists only on iOS.
    ///
    /// Java's and JavaScript's `\d` are ASCII `[0-9]`. ICU's — which is what
    /// `NSRegularExpression` uses — is `\p{Nd}`, matching Arabic-Indic,
    /// Devanagari, fullwidth and ~600 other decimal digits. Transcribing the
    /// Kotlin's `\d` literally would make this parser strip a "step number" the
    /// web that published the recipe never treated as one.
    ///
    /// Every other test in this file passes under either dialect, so without
    /// this one the correction in `RecipeParser` is a comment with nothing
    /// holding it in place: a future simplification back to `\d` would ship
    /// green.
    ///
    /// Web/Kotlin behaviour, which this asserts: `١` (U+0661 ARABIC-INDIC
    /// DIGIT ONE) is not a step marker, so the line falls through to the lenient
    /// >10-character fallback and is kept **whole**, prefix included.
    @Test func directions_unicodeDigitsAreNotStepNumbers_icuRegexDialectGuard() {
        let md = "## Directions\n\n\u{0661}. Mix the flour and water thoroughly."
        let steps = RecipeParser.parseContent(md).directions
        #expect(steps == ["\u{0661}. Mix the flour and water thoroughly."])
    }
}
