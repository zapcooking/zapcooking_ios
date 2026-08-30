import Foundation
import Testing
@testable import wisp

/// Gate for the NIP-23 adapter — the cases whose entry point is
/// `Nip23RecipeFormat`.
///
/// Ported from Android @ `68242f5`: 4 adapter/filter cases from
/// `RecipeFormatTest`, all 11 `edit_*` cases from `RecipeEditSerializerTest`
/// (which reach `serializeEdit`), and the create-path seam case
/// `create_serializeIsByteIdenticalToTheDefaultedToTags` — which asserts
/// `Nip23RecipeFormat.serialize` and `RecipeSerializer.toTags` agree. That seam
/// case lands here because 2.1 shipped first and it needs `serialize`.
///
/// Every edit case is a way an edit can quietly destroy part of the recipe it
/// was supposed to correct, so each asserts on **what survived**, not just on
/// what changed. The create-path round-trip gates live in
/// `RecipeSerializerTests` and are deliberately untouched: create's output must
/// not move.
struct Nip23RecipeFormatTests {

    private let format = Nip23RecipeFormat()

    // MARK: - Fixtures

    private func tuscanEvent() -> NostrEvent {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            fatalError("fixture decode failed")
        }
        return event
    }

    /// A published recipe event. `extraTags` are appended verbatim, which is how
    /// each test states the thing it expects to still be there afterwards.
    private func published(
        _ title: String,
        _ dTag: String,
        images: [String],
        categories: [String] = ["italian"],
        extraTags: [[String]] = [],
        createdAt: Int = 1_700_000_000,
        publishedAt: Int64? = nil,
        pubkey: String = String(repeating: "a", count: 64),
        id: String = String(repeating: "1", count: 64)
    ) -> NostrEvent {
        var tags: [[String]] = []
        tags.append(["d", dTag])
        tags.append(["title", title])
        tags.append(["t", "zapcooking"])
        tags.append(["t", "zapcooking-\(dTag)"])
        if let publishedAt { tags.append(["published_at", String(publishedAt)]) }
        for image in images { tags.append(["image", image]) }
        for category in categories { tags.append(["t", "zapcooking-\(category)"]) }
        tags.append(contentsOf: extraTags)
        return NostrEvent(
            id: id,
            pubkey: pubkey,
            kind: RecipeParser.recipeKind,
            createdAt: createdAt,
            tags: tags,
            content: "\n## Ingredients\n\n- 1 thing\n\n\n## Directions\n\n1. Do it.\n",
            sig: String(repeating: "0", count: 128)
        )
    }

    /// Serialize an edit of `original`, optionally under a `newTitle`.
    private func edit(
        _ original: NostrEvent,
        newTitle: String? = nil,
        images: [String]? = nil,
        categories: [String]? = nil
    ) -> UnsignedRecipeEvent {
        let recipe = RecipeParser.parse(original)
        return format.serializeEdit(
            recipe: recipe,
            title: newTitle ?? recipe.title!,
            imageUrls: images ?? recipe.images,
            categories: categories ?? recipe.categories,
            original: original
        )
    }

    /// Kotlin's `NostrEvent.copy(...)`; the Swift properties are `let`.
    private func copy(
        _ event: NostrEvent,
        id: String? = nil,
        createdAt: Int? = nil,
        tags: [[String]]? = nil,
        content: String? = nil
    ) -> NostrEvent {
        NostrEvent(
            id: id ?? event.id,
            pubkey: event.pubkey,
            kind: event.kind,
            createdAt: createdAt ?? event.createdAt,
            tags: tags ?? event.tags,
            content: content ?? event.content,
            sig: event.sig
        )
    }

    private func values(_ tags: [[String]], _ name: String) -> [String] {
        tags.filter { $0.count >= 2 && $0[0] == name }.map { $0[1] }
    }

    // MARK: - Adapter identity

    @Test func nip23Adapter_isIdentityWithRetainedObjects() {
        let e = tuscanEvent()
        // parse delegates verbatim → same structured recipe.
        #expect(format.parse(e) == RecipeParser.parse(e))
        // serialize delegates verbatim → byte-identical content + tags.
        let recipe = RecipeParser.parse(e)
        let unsigned = format.serialize(
            recipe: recipe,
            title: recipe.title!,
            imageUrls: [recipe.image!],
            categories: recipe.categories
        )
        #expect(unsigned.kind == RecipeParser.recipeKind)
        #expect(unsigned.content == RecipeSerializer.toContent(recipe))
        #expect(
            unsigned.tags == RecipeSerializer.toTags(
                title: recipe.title!,
                summary: recipe.summary,
                imageUrls: [recipe.image!],
                categories: recipe.categories
            )
        )
        #expect(format.slug(recipe.title!) == RecipeSerializer.slug(recipe.title!))
    }

    // MARK: - authorFeedFilter (My Recipes live author query)

    @Test func authorFeedFilter_isFeedFilterScopedToAuthor() {
        let author = String(repeating: "a", count: 64)
        let filter = format.authorFeedFilter(author: author, limit: 200, until: nil)
        #expect(filter.kinds == [RecipeParser.recipeKind])
        #expect(filter.tTags == RecipeParser.recipeHashtags)
        #expect(filter.authors == [author])
        #expect(filter.limit == 200)
        #expect(filter.until == nil)
    }

    @Test func authorFeedFilter_passesUntilForPaging() {
        let filter = format.authorFeedFilter(
            author: String(repeating: "b", count: 64), limit: 50, until: 1234
        )
        #expect(filter.until == 1234)
    }

    // MARK: - tagFeedFilter (Concern 1.7)

    @Test func tagFeedFilter_prefixesBothRecipeRoots() {
        let filter = format.tagFeedFilter(tag: "Italian", limit: 50, until: nil)
        #expect(filter.kinds == [RecipeParser.recipeKind])
        #expect(filter.tTags == ["zapcooking-italian", "nostrcooking-italian"])
        #expect(filter.limit == 50)
        #expect(filter.until == nil)
    }

    @Test func tagFeedFilter_passesUntilForPaging() {
        #expect(format.tagFeedFilter(tag: "beef", limit: 50, until: 1234).until == 1234)
    }

    // MARK: - authorFeedFilter for ANY author (other-user profile Recipes tab)

    @Test func authorFeedFilter_isPubkeyParameterized_notSelfScoped() {
        // The profile Recipes tab reuses this filter for a stranger's pubkey.
        // It must scope to whoever is passed and be otherwise identical to the
        // My Recipes query — same kinds, same recipe hashtags.
        let stranger = String(repeating: "c", count: 64)
        let mine = format.authorFeedFilter(
            author: String(repeating: "d", count: 64), limit: 200, until: nil
        )
        let theirs = format.authorFeedFilter(author: stranger, limit: 200, until: nil)

        #expect(theirs.authors == [stranger])
        #expect(theirs.kinds == mine.kinds)
        #expect(theirs.tTags == mine.tTags)
        #expect(theirs.limit == mine.limit)
    }

    // MARK: - D0: a re-serialize must not delete what the model is lossy about

    @Test func edit_keepsEveryImage_notJustTheCover() {
        let cover = "https://example.com/cover.jpg"
        let second = "https://example.com/second.jpg"
        let original = published("Ragu", "ragu", images: [cover, second])

        // The model's `image` is a single cover; `images` is the whole list.
        // Editing through the cover alone is exactly the deletion this guards.
        #expect(RecipeParser.parse(original).images == [cover, second])

        let tags = edit(original, newTitle: "Ragù").tags
        #expect(values(tags, "image") == [cover, second])
    }

    @Test func edit_keepsPlainHashtags_whileReplacingRecipeConventionOnes() {
        let original = published(
            "Ragu", "ragu", images: ["i"], categories: ["italian"],
            extraTags: [["t", "vegan"]]
        )
        // `hashtags` is every `t`; `categories` only the `zapcooking-` ones — so
        // a plain `t` is parsed and then not represented in the form.
        let parsed = RecipeParser.parse(original)
        #expect(parsed.hashtags.contains("vegan"))
        #expect(!parsed.categories.contains("vegan"))

        let tags = edit(original, categories: ["french"]).tags
        let ts = values(tags, "t")
        #expect(ts.contains("vegan"))
        #expect(ts.contains("zapcooking-french"))
        #expect(!ts.contains("zapcooking-italian"))
        #expect(ts.contains("zapcooking"))
        #expect(ts.filter { $0 == "zapcooking" }.count == 1)
    }

    @Test func edit_carriesOverTagsTheModelDoesNotKnow() {
        // Nothing here knows what these mean. That is the point: preserving by
        // default is what makes the model's blind spots non-destructive.
        let unmodelled: [[String]] = [
            ["gated", "gated_123", "100"],
            ["a", "30023:\(String(repeating: "b", count: 64)):other"],
            ["some-future-tag", "value"],
        ]
        let original = published("Ragu", "ragu", images: ["i"], extraTags: unmodelled)
        let tags = edit(original, newTitle: "Ragù").tags
        for tag in unmodelled { #expect(tags.contains(tag)) }
    }

    @Test func edit_doesNotDuplicateOwnedTags() {
        let original = published("Ragu", "ragu", images: ["i"])
        let tags = edit(original, newTitle: "Ragù", images: ["j"]).tags
        #expect(values(tags, "d").count == 1)
        #expect(values(tags, "title").count == 1)
        #expect(values(tags, "image") == ["j"])
        #expect(values(tags, "title") == ["Ragù"])
    }

    @Test func edit_dropsTheOriginalsClientTag() {
        // The publisher adds `client` per the member's current NIP-89 preference.
        // Carrying the original's forward would duplicate it and override a
        // preference the member has since turned off.
        let original = published(
            "Ragu", "ragu", images: ["i"],
            extraTags: [["client", "zap.cooking"]]
        )
        #expect(!edit(original).tags.contains { $0.first == "client" })
    }

    /// A legacy `#nostrcooking`-rooted recipe comes out of an edit rooted at
    /// `#zapcooking`, and its category tags are re-prefixed to match.
    ///
    /// Pinned rather than assumed: `isGeneratedHashtag` treats **both** roots as
    /// this serializer's own, so the legacy root is replaced rather than
    /// preserved — the same thing the create path does. The visible consequence
    /// is that editing a legacy recipe takes it out of `#nostrcooking` feeds, so
    /// this is a product call, not just a tag rule. Carried over from Android's
    /// note: if the legacy root should be preserved, this test is the line that
    /// changes.
    @Test func edit_reRootsALegacyNostrcookingRecipe() {
        let original = NostrEvent(
            id: String(repeating: "1", count: 64),
            pubkey: String(repeating: "a", count: 64),
            kind: RecipeParser.recipeKind,
            createdAt: 1_600_000_000,
            tags: [
                ["d", "ragu"],
                ["title", "Ragu"],
                ["t", "nostrcooking"],
                ["t", "nostrcooking-ragu"],
                ["t", "nostrcooking-italian"],
                ["image", "i"],
            ],
            content: "\n## Ingredients\n\n- 1 thing\n\n\n## Directions\n\n1. Do it.\n",
            sig: String(repeating: "0", count: 128)
        )
        #expect(RecipeParser.parse(original).categories == ["italian"])

        let edited = edit(original, newTitle: "Ragù")
        let ts = values(edited.tags, "t")
        #expect(ts.filter { $0 == "zapcooking" } == ["zapcooking"])
        #expect(ts.filter { $0.hasPrefix("nostrcooking") } == [])

        // The tag set stays internally coherent: the self-tag and the categories
        // share the new root, so no chip appears for the recipe itself.
        let reparsed = RecipeParser.parse(
            copy(original, id: String(repeating: "2", count: 64), tags: edited.tags, content: edited.content)
        )
        #expect(reparsed.categories == ["italian"])
        #expect(reparsed.dTag == "ragu")
    }

    // MARK: - D1: the address is preserved, and the self-tag follows it

    @Test func edit_preservesIdentifier_acrossARename() {
        let original = published("Chocalate Cake", "chocalate-cake", images: ["i"])
        let tags = edit(original, newTitle: "Chocolate Cake").tags
        #expect(values(tags, "d") == ["chocalate-cake"])
        #expect(values(tags, "title") == ["Chocolate Cake"])
    }

    @Test func edit_selfTagFollowsIdentifier_soNoCategoryChipAppears() {
        let original = published(
            "Chocalate Cake", "chocalate-cake", images: ["i"],
            categories: ["dessert"]
        )
        let edited = edit(original, newTitle: "Chocolate Cake")
        let ts = values(edited.tags, "t")
        #expect(ts.contains("zapcooking-chocalate-cake"))
        #expect(!ts.contains("zapcooking-chocolate-cake"))

        // The consequence, not just the tag: deriveCategories excludes exactly
        // "<root>-<dTag>", so a title-derived self-tag would survive that filter
        // and render as a category chip named after the recipe itself.
        let reparsed = RecipeParser.parse(
            copy(original, id: String(repeating: "2", count: 64), tags: edited.tags, content: edited.content)
        )
        #expect(reparsed.categories == ["dessert"])
    }

    // MARK: - D2: an edit must not re-date the recipe

    @Test func edit_pinsPublicationMoment_fromTheOriginalsCreatedAt() {
        // The original carries no published_at, so the parser falls back to its
        // created_at — and that fallback is what the edit has to write down
        // before republishing under a fresh created_at.
        let original = published("Ragu", "ragu", images: ["i"], createdAt: 1_600_000_000)
        let tags = edit(original, newTitle: "Ragù").tags
        #expect(values(tags, "published_at") == ["1600000000"])
    }

    @Test func edit_keepsAnExistingPublishedAt() {
        let original = published(
            "Ragu", "ragu", images: ["i"],
            createdAt: 1_700_000_000, publishedAt: 1_500_000_000
        )
        let tags = edit(original).tags
        #expect(values(tags, "published_at") == ["1500000000"])
        #expect(values(tags, "published_at").count == 1)
    }

    @Test func edit_survivesASecondEdit_withoutDrift() {
        // Edit twice off the previous result: the address, the publication
        // moment and an unmodelled tag must all be the same as after edit one.
        let original = published(
            "Ragu", "ragu", images: ["a.jpg", "b.jpg"],
            extraTags: [["gated", "gated_123", "100"]],
            createdAt: 1_600_000_000
        )
        let once = edit(original, newTitle: "Ragù")
        let onceEvent = copy(
            original,
            id: String(repeating: "2", count: 64),
            createdAt: 1_800_000_000,
            tags: once.tags,
            content: once.content
        )
        let twice = edit(onceEvent, newTitle: "Ragù alla Bolognese").tags

        #expect(values(twice, "d") == ["ragu"])
        #expect(values(twice, "published_at") == ["1600000000"])
        #expect(values(twice, "image") == ["a.jpg", "b.jpg"])
        #expect(twice.contains(["gated", "gated_123", "100"]))
        #expect(values(twice, "published_at").count == 1)
    }

    // MARK: - The create-path seam: serialize agrees with the defaulted toTags

    @Test func create_serializeIsByteIdenticalToTheDefaultedToTags() {
        let event = tuscanEvent()
        let recipe = RecipeParser.parse(event)
        let produced = format.serialize(
            recipe: recipe,
            title: recipe.title!,
            imageUrls: recipe.images,
            categories: recipe.categories
        )
        let expected = RecipeSerializer.toTags(
            title: recipe.title!,
            summary: recipe.summary,
            imageUrls: recipe.images,
            categories: recipe.categories
        )
        #expect(produced.tags == expected)
        #expect(produced.content == event.content)
    }
}
