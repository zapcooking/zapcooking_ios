import Foundation

/// Serializes a `RecipeParser.Recipe` into a kind-30023 recipe body + tags —
/// the inverse of `RecipeParser`, for publishing recipes. Mirrors the
/// zap.cooking web create flow byte-for-byte (`createMarkdown` +
/// `create/+page.svelte` tag-building) so app-authored recipes round-trip
/// against web-authored ones.
///
/// Port of Android `nostr/RecipeSerializer.kt` @ `68242f5`. Behaviour is
/// intended to be identical; only syntax is translated.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 2 / 2.1):
/// - `d = slug(title)` (spaces → `-` only; keep parens/slashes).
/// - Tags: `t:zapcooking` + `t:zapcooking-<slug>` + `t:zapcooking-<category>`,
///   image tags; **no `published_at`** on create.
/// - Round-trip tested (serialize → parse → equals) against the real Tuscan
///   Peposo event.
///
/// Pure (string ops only).
enum RecipeSerializer {

    /// New recipes always carry the current root tag (never legacy nostrcooking).
    private static let root = RecipeParser.recipeHashtags[0] // "zapcooking"

    /// The web's exact d-tag/slug: `title.toLowerCase().replaceAll(' ', '-')` —
    /// **spaces only**. Parens/slashes are deliberately kept (e.g.
    /// `tuscan-peposo-(black-pepper-beef-stew)`); the recipe route already
    /// URL-encodes them. Do not "clean up" further or recipes won't round-trip
    /// against web-authored ones. Same title → same d-tag (replaces) — web
    /// behavior; mirrored, not de-duplicated.
    ///
    /// Kotlin pins `Locale.ROOT` here because a Turkish-locale dotless-i would
    /// break web parity and the "same title → same d-tag" guarantee. Swift's
    /// `lowercased()` is the locale-independent Unicode mapping already — the
    /// locale-sensitive one is the explicit `lowercased(with:)`, which this must
    /// never use.
    static func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// Kotlin's `String.isNotBlank()`.
    private static func isNotBlank(_ s: String) -> Bool {
        !s.allSatisfy { $0.isWhitespace } && !s.isEmpty
    }

    /// Structured body → `##`-section markdown (mirrors web `createMarkdown`).
    ///
    /// The detail labels are written as scalar escapes, not pasted glyphs:
    /// `⏲️` is U+23F2 **plus U+FE0F**, `🍳` is U+1F373 with **no** variation
    /// selector, and `🍽️` is U+1F37D plus U+FE0F. That asymmetry is real and
    /// load-bearing — it is what the frozen web-authored event contains, and
    /// `serializedContent_isByteIdenticalToWebAuthoredEvent` fails if an editor
    /// pass ever "normalizes" it. Same convention as `RecipeParser`'s own
    /// section keys.
    static func toContent(_ recipe: RecipeParser.Recipe) -> String {
        let c = recipe.content
        var out = ""

        if let chefNotes = c.chefNotes, isNotBlank(chefNotes) {
            out += "\n## Chef's notes\n\n\(chefNotes)\n"
        }

        let d = c.details
        if d.prepTime != nil || d.cookTime != nil || d.servings != nil {
            out += "\n## Details\n\n"
            if let prep = d.prepTime { out += "- \u{23F2}\u{FE0F} Prep time: \(prep)\n" }
            if let cook = d.cookTime { out += "- \u{1F373} Cook time: \(cook)\n" }
            if let servings = d.servings { out += "- \u{1F37D}\u{FE0F} Servings: \(servings)\n" }
        }

        if !c.ingredients.isEmpty {
            out += "\n## Ingredients\n\n"
            for ingredient in c.ingredients { out += "- \(ingredient)\n" }
        }

        if !c.directions.isEmpty {
            out += "\n\n## Directions\n\n"
            for (i, step) in c.directions.enumerated() { out += "\(i + 1). \(step)\n" }
        }

        if let additional = c.additionalMarkdown, isNotBlank(additional) {
            out += "\n\n## Additional Resources\n\n\(additional)\n\n"
        }

        return out
    }

    /// kind-30023 tags for a recipe (mirrors the web create flow):
    /// `d`=identifier, `title`, `t:zapcooking`, `t:zapcooking-<identifier>`,
    /// `summary` (if set), one `image` per URL, and
    /// `t:zapcooking-<category-slug>` per category. The `client` tag is added at
    /// publish, not here.
    ///
    /// `identifier` and `publishedAt` are both **nil on create** — the emitted
    /// tags are then byte-identical to the web's, `published_at` is omitted
    /// exactly as the web omits it, and `d` is `slug(title)`. Both are set on
    /// **edit**: `d` must keep the original event's identifier (a re-derived one
    /// would publish a second recipe instead of replacing the first), and
    /// `published_at` must be written back from the original or the parser's
    /// `created_at` fallback re-dates the recipe to the edit time. The asymmetry
    /// is the design, not a compromise — create's output does not change.
    ///
    /// The per-recipe self-tag is derived from the **identifier**, never from
    /// `title`, and that is load-bearing: `RecipeParser.deriveCategories`
    /// excludes exactly `"<root>-<dTag>"`. Derive it from a retitled recipe's new
    /// title and the two stop matching, so the self-tag survives that filter and
    /// renders as a category chip named after the recipe itself, on the recipe
    /// screen and in every category feed.
    static func toTags(
        title: String,
        summary: String?,
        imageUrls: [String],
        categories: [String],
        identifier: String? = nil,
        publishedAt: Int64? = nil
    ) -> [[String]] {
        var tags: [[String]] = []
        // One source of truth for the address: `d` and the self-tag below both
        // read this, so they cannot drift apart at a call site.
        //
        // Note what the blank branch means: a BLANK `identifier` is create
        // semantics, silently. So `RecipeFormat.serializeEdit`'s "the address is
        // preserved, never re-derived from title" is a guarantee about its
        // CALLERS, not something enforced here. It holds today because the only
        // edit path resolves the original by a non-blank `d`
        // (`RecipeParser.dTag`), which is why there is no guard on a state that
        // cannot currently occur. It stops holding the day a format whose
        // identifier is not slugged from the title reaches `serializeEdit` —
        // that format must pass its own identifier, not rely on this fallback.
        let id = identifier.flatMap { isNotBlank($0) ? $0 : nil } ?? slug(title)
        tags.append(["d", id])
        tags.append(["title", title])
        tags.append(["t", root])
        tags.append(["t", "\(root)-\(id)"])
        if let publishedAt { tags.append(["published_at", String(publishedAt)]) }
        if let summary, isNotBlank(summary) { tags.append(["summary", summary]) }
        for url in imageUrls { tags.append(["image", url]) }
        // Categories are raw display names → `zapcooking-<slug>`, same slug fn.
        for category in categories where isNotBlank(category) {
            tags.append(["t", "\(root)-\(slug(category))"])
        }
        return tags
    }

    /// Tag names `toTags` writes and therefore owns outright on an edit. `client`
    /// is here but is **not** written by `toTags`: the publisher adds it per the
    /// member's NIP-89 preference, so carrying the original's forward would both
    /// duplicate it and override a preference since turned off.
    private static let ownedTagNames: Set<String> = ["d", "title", "summary", "image", "published_at", "client"]

    /// True when a `#t` value is one `toTags` generates — the root itself or any
    /// `<root>-…` value (the per-recipe self-tag and the category tags).
    ///
    /// Scoped deliberately: `hashtags` on the model is *every* `t` value, but
    /// `RecipeParser.deriveCategories` only reads the `<root>-` prefixed ones, so
    /// a plain `t: vegan` is parsed and then not represented in `categories`.
    /// Treating all of `t` as owned would delete that tag on the first edit —
    /// the same lossy-model deletion one tag over.
    private static func isGeneratedHashtag(_ value: String) -> Bool {
        RecipeParser.recipeHashtags.contains(value)
            || RecipeParser.recipeHashtags.contains { value.hasPrefix("\($0)-") }
    }

    /// Edit tag set: `newTags` (from `toTags`) plus every tag on the original
    /// event that this serializer does not own.
    ///
    /// The rule this encodes: **a re-serialize from a model deletes everything
    /// the model does not know.** The compose form models title, summary, cover
    /// photos, categories and the identifier; a real recipe event can carry
    /// anything else — a `gated` marker, an `a`/`e` reference, a plain
    /// non-category `#t`, a tag from a client that does not exist yet. Rebuilding
    /// tags from scratch on an edit drops all of it silently, and "silently" is
    /// the part that makes it a defect rather than a limitation.
    ///
    /// Preserved tags keep their original relative order and precede the
    /// regenerated ones. Order is not semantic in NIP-01, and no reader here
    /// depends on it (`firstTagValue` only ever sees one of each owned name).
    ///
    /// Its goldens are the 11 `edit_*` cases in Android's
    /// `RecipeEditSerializerTest`, which reach it through
    /// `Nip23RecipeFormat.serializeEdit` — Concern 2.2. Implemented here because
    /// this is the file that declares it and 2.2 cannot be written against a
    /// `fatalError`.
    static func mergeForEdit(
        originalTags: [[String]],
        newTags: [[String]]
    ) -> [[String]] {
        let preserved = originalTags.filter { tag in
            guard let name = tag.first else { return false }
            if ownedTagNames.contains(name) { return false }
            if name == "t" { return !isGeneratedHashtag(tag.count >= 2 ? tag[1] : "") }
            return true
        }
        return preserved + newTags
    }
}
