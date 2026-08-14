import Foundation

/// Parses a zap.cooking recipe — a NIP-23 long-form event (`kind 30023`)
/// tagged `#t zapcooking` (or legacy `nostrcooking`) — into the structured
/// fields the recipe UI needs.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.1):
/// - Byte-faithful port of the Kotlin / web `parseMarkdownForEditing`.
/// - **No UI.** Golden-tested against the real *Tuscan Peposo* event,
///   including missing `published_at`, missing `servings`, and live U+FE0F
///   emoji bytes.
/// - `published_at` is optional (absent on new `zapcooking`, present on
///   legacy `nostrcooking`) → fall back to `created_at`.
/// - `RecipeParser.isRecipe` is the gate used by article-tap rewiring (1.6):
///   kind-30023 opens the recipe route only when this returns true.
///
/// Ported from Android `nostr/RecipeParser.kt` @ `4389530`, which is itself a
/// port of the web `src/lib/parser.ts`. Two regex-dialect corrections were
/// required and are load-bearing — ICU (NSRegularExpression) is not Java:
///
/// - **`\d` is NOT ASCII in ICU.** Java's and JavaScript's `\d` are `[0-9]`;
///   ICU's is `\p{Nd}`, which matches Arabic-Indic, Devanagari, fullwidth and
///   ~600 other decimal digits. A `١. Mix.` step would be accepted here and
///   rejected by the web that published it. Every digit class below is written
///   `[0-9]` explicitly for that reason — never `\d`.
/// - **`\s` is Unicode-wide in ICU**, ASCII-only in Java. Here that is a *fix*,
///   not a drift: JavaScript's `\s` is also Unicode-wide, so ICU matches the
///   web (the actual publisher) more closely than the Kotlin does. Left as
///   `\s`. It affects only heading/gap tolerance, never the recipe-vs-article
///   decision.
///
/// `nonisolated` per §6: the project defaults to
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so pure compute silently pins
/// to main. This is regex + string work only and must not.
nonisolated enum RecipeParser {
    /// NIP-23 long-form kind used for recipes.
    static let recipeKind = 30023

    /// Root `#t` tags that mark a long-form event as a recipe.
    /// `zapcooking` is current; `nostrcooking` is the legacy tag — support
    /// both (build doc §2).
    static let recipeHashtags = ["zapcooking", "nostrcooking"]

    /// Free-text recipe timings — each optional, never assumed numeric.
    nonisolated struct RecipeDetails: Equatable {
        var prepTime: String?
        var cookTime: String?
        var servings: String?

        init(prepTime: String? = nil, cookTime: String? = nil, servings: String? = nil) {
            self.prepTime = prepTime
            self.cookTime = cookTime
            self.servings = servings
        }

        var isEmpty: Bool { prepTime == nil && cookTime == nil && servings == nil }
    }

    /// The structured Markdown body, mirroring the frontend `MarkdownTemplate`.
    nonisolated struct RecipeContent: Equatable {
        var chefNotes: String?
        var details: RecipeDetails
        var ingredients: [String]
        var directions: [String]
        var additionalMarkdown: String?

        init(
            chefNotes: String? = nil,
            details: RecipeDetails = RecipeDetails(),
            ingredients: [String] = [],
            directions: [String] = [],
            additionalMarkdown: String? = nil
        ) {
            self.chefNotes = chefNotes
            self.details = details
            self.ingredients = ingredients
            self.directions = directions
            self.additionalMarkdown = additionalMarkdown
        }
    }

    /// A fully-resolved recipe: addressable coordinates, tags, parsed body.
    nonisolated struct Recipe: Equatable {
        var id: String
        /// Author pubkey (hex) — the `author` half of the `naddr` coordinate.
        var author: String
        /// Addressable `d` identifier — the `dTag` half of the coordinate.
        var dTag: String
        var title: String?
        /// Every `image` tag value, in event order — the web writes one `image`
        /// tag per photo with no limit, so a recipe routinely carries several
        /// and the first is the cover.
        ///
        /// This is a **list, not a single cover**, because the edit path
        /// re-serializes a recipe from this model: a `String?` cover would make
        /// "fix a typo" publish one `image` tag and silently delete every other
        /// photo. A model that is lossy about a tag is a deletion of that tag
        /// the moment anything writes the model back out.
        var images: [String]
        var summary: String?
        /// `published_at` if present, else the event `created_at` (epoch seconds).
        var publishedAt: Int64
        /// Every `#t` value on the event, verbatim.
        var hashtags: [String]
        /// Display categories derived from the `<root>-<category>` tag
        /// convention (e.g. `zapcooking-italian` → `italian`), excluding the
        /// root tag itself and the per-recipe `<root>-<dTag>` slug tag.
        var categories: [String]
        var content: RecipeContent

        /// Cover photo — the first `image` tag, or nil when the recipe has none.
        var image: String? { images.first }
    }

    /// Result of ``validateMarkdownTemplate(_:)``: the parsed template when the
    /// markdown has the recipe-template shape, or a human-readable reason when
    /// it does not. Mirrors the web's `MarkdownTemplate | string` return and
    /// the Kotlin `sealed interface TemplateValidation`; a Swift enum with
    /// associated values is the direct equivalent — there is no sealed-interface
    /// shape to reproduce.
    nonisolated enum TemplateValidation: Equatable {
        case valid(RecipeContent)
        case invalid(String)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }

        /// The parsed template, or nil when invalid.
        var template: RecipeContent? {
            if case .valid(let template) = self { return template }
            return nil
        }
    }

    /// True when `event` is a long-form recipe. A NIP-23 `kind 30023` is a
    /// recipe ONLY IF it carries a recipe root `#t` tag AND its content has the
    /// recipe-template shape (``isRecipeContent(_:)``).
    ///
    /// The tag alone is NOT sufficient: recipes and plain long-form articles
    /// share `kind 30023`, and an article that merely carries `#t zapcooking`
    /// would otherwise leak into the recipe feed. The web drops these by running
    /// the editor's save-time guard `validateMarkdownTemplate` on every event;
    /// mirroring that content gate here is what keeps articles out.
    static func isRecipe(_ event: NostrEvent) -> Bool {
        event.kind == recipeKind
            && tagValues(event, "t").contains { recipeHashtags.contains($0) }
            && isRecipeContent(event.content)
    }

    /// True when `markdown` has the recipe-template structure — i.e.
    /// ``validateMarkdownTemplate(_:)`` accepts it. This is the content-shape
    /// half of ``isRecipe(_:)`` and the single shared gate every recipe-feed
    /// path funnels through (via `RecipeFormats.forEvent` →
    /// `Nip23RecipeFormat.matches`).
    static func isRecipeContent(_ markdown: String) -> Bool {
        validateMarkdownTemplate(markdown).isValid
    }

    /// The original publication moment: `published_at` when the event carries
    /// it, else the event's own `created_at`.
    ///
    /// Public because the **edit** path needs it off the original event to write
    /// it back (an edit republishes with a fresh `created_at`, so without this
    /// the fallback below would silently re-date the recipe to the edit time).
    static func publishedAt(_ event: NostrEvent) -> Int64 {
        if let raw = firstTagValue(event, "published_at"), let parsed = Int64(raw) {
            return parsed
        }
        return Int64(event.createdAt)
    }

    /// The addressable `d` identifier, empty when absent (NIP-01 treats a
    /// missing `d` as `""`). Public for the same reason as ``publishedAt(_:)``:
    /// the edit path reads it off the original event, not off a re-parsed model.
    static func dTag(_ event: NostrEvent) -> String {
        firstTagValue(event, "d") ?? ""
    }

    /// Resolve a recipe event into ``Recipe``. Does not validate it is a recipe.
    static func parse(_ event: NostrEvent) -> Recipe {
        let hashtags = tagValues(event, "t")
        let d = dTag(event)

        return Recipe(
            id: event.id,
            author: event.pubkey,
            dTag: d,
            title: firstTagValue(event, "title"),
            images: tagValues(event, "image"),
            summary: firstTagValue(event, "summary"),
            publishedAt: publishedAt(event),
            hashtags: hashtags,
            categories: deriveCategories(hashtags, dTag: d),
            content: parseContent(event.content)
        )
    }

    // ---- Markdown body parsing (port of parseMarkdownForEditing) ----------

    private static let chefNotesSection = section("Chef's notes")
    private static let detailsSection = section("Details")
    private static let ingredientsSection = section("Ingredients")
    private static let directionsSection = section("Directions")
    private static let additionalSection = section("Additional Resources")

    // Emoji-prefixed Details fields. The live bytes are irregular: ⏲️ Prep is
    // U+23F2 + U+FE0F and 🍽️ Servings is U+1F37D + U+FE0F (variation selector
    // present), but 🍳 Cook is bare U+1F373 (no selector). Each pattern is the
    // base emoji followed by an OPTIONAL trailing U+FE0F and `\s*` for the gap,
    // so this is a strict SUPERSET of the frontend's single authored-glyph +
    // single-space regex: it matches everything the editor emits, and also
    // survives a client that strips the selector or pads the space.
    //
    // Scalars are written as `\u{...}` escapes rather than pasted glyphs on
    // purpose: `⏲️?` and `⏲?` are indistinguishable by eye but mean different
    // things (optional-selector vs optional-clock), and a well-meaning editor
    // pass that "normalizes" the emoji would silently break the live path with
    // no visible diff.
    private static let prepTimeField = try! NSRegularExpression(
        pattern: "\u{23F2}\u{FE0F}?\\s*Prep time[:\\s]+([^\\n]+)",
        options: [.caseInsensitive]
    )
    private static let cookTimeField = try! NSRegularExpression(
        pattern: "\u{1F373}\u{FE0F}?\\s*Cook time[:\\s]+([^\\n]+)",
        options: [.caseInsensitive]
    )
    private static let servingsField = try! NSRegularExpression(
        pattern: "\u{1F37D}\u{FE0F}?\\s*Servings[:\\s]+([^\\n]+)",
        options: [.caseInsensitive]
    )

    /// `[0-9]`, not `\d` — see the type doc. ICU's `\d` is Unicode-wide.
    private static let numberedStep = try! NSRegularExpression(
        pattern: "^([0-9]+)\\.\\s*(.+)$"
    )

    static func parseContent(_ markdown: String) -> RecipeContent {
        RecipeContent(
            chefNotes: trimmedNonEmpty(firstCapture(chefNotesSection, in: markdown)),
            details: parseDetails(firstCapture(detailsSection, in: markdown)),
            ingredients: parseIngredients(firstCapture(ingredientsSection, in: markdown)),
            directions: parseDirections(firstCapture(directionsSection, in: markdown)),
            additionalMarkdown: trimmedNonEmpty(firstCapture(additionalSection, in: markdown))
        )
    }

    private static func parseDetails(_ body: String?) -> RecipeDetails {
        guard let body else { return RecipeDetails() }
        return RecipeDetails(
            prepTime: trimmedNonEmpty(firstCapture(prepTimeField, in: body)),
            cookTime: trimmedNonEmpty(firstCapture(cookTimeField, in: body)),
            servings: trimmedNonEmpty(firstCapture(servingsField, in: body))
        )
    }

    private static func parseIngredients(_ body: String?) -> [String] {
        guard let body else { return [] }
        var out: [String] = []
        for line in body.components(separatedBy: "\n") {
            let t = trimmed(line)
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                out.append(trimmed(String(t.dropFirst(2))))
            } else if !t.isEmpty && !t.hasPrefix("#") {
                // Lenient: keep any non-empty, non-heading line (the frontend
                // pushes the whole trimmed line here, unstripped).
                out.append(t)
            }
        }
        return out
    }

    private static func parseDirections(_ body: String?) -> [String] {
        guard let body else { return [] }
        var out: [String] = []
        for line in body.components(separatedBy: "\n") {
            let t = trimmed(line)
            if let step = firstCapture(numberedStep, in: t, group: 2) {
                out.append(trimmed(step))
            } else if t.hasPrefix("- ") {
                out.append(trimmed(String(t.dropFirst(2))))
            } else if !t.isEmpty && !t.hasPrefix("#") && t.utf16.count > 10 {
                // Lenient fallback for substantial unmarked lines.
                //
                // `utf16.count`, not `count`, for the same reason as the limits in
                // ``validateMarkdownTemplate(_:)`` — web `parser.ts:214` and Kotlin
                // `RecipeParser.kt:227` both compare `String.length`, which is UTF-16
                // units. The direction inverts here, which is what hid it: in the
                // validator `count` would let a *longer* string through, so it reads
                // as the lax choice; here `count` *drops* short lines the web keeps.
                // "Enjoy! 🎉🎊🥳" is 10 graphemes and 13 UTF-16 units.
                out.append(t)
            }
        }
        return out
    }

    // ---- Tag helpers ------------------------------------------------------

    /// `<root>-<category>` tags minus the root and the per-recipe
    /// `<root>-<dTag>` slug, with the root prefix stripped for display.
    private static func deriveCategories(_ hashtags: [String], dTag: String) -> [String] {
        guard let root = hashtags.first(where: { recipeHashtags.contains($0) }) else { return [] }
        let slugTag = "\(root)-\(dTag)"
        let prefix = "\(root)-"
        return hashtags
            .filter { $0 != root && $0 != slugTag && $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private static func firstTagValue(_ event: NostrEvent, _ name: String) -> String? {
        event.tags.first { $0.count >= 2 && $0[0] == name }?[1]
    }

    private static func tagValues(_ event: NostrEvent, _ name: String) -> [String] {
        event.tags.filter { $0.count >= 2 && $0[0] == name }.map { $0[1] }
    }

    /// Section extractor matching the frontend regex
    /// `/## <name>\s*\n([\s\S]*?)(?=\n## |$)/i` — captures everything from a
    /// heading up to the next `## ` heading or end of input.
    private static func section(_ name: String) -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return try! NSRegularExpression(
            pattern: "## \(escaped)\\s*\\n([\\s\\S]*?)(?=\\n## |$)",
            options: [.caseInsensitive]
        )
    }

    // ---- Strict recipe-template validation (port of validateMarkdownTemplate) ----

    /// Section splitter for the STRICT validator: `## <letters/space/apostrophe>`,
    /// a newline, then one-or-more non-`#` characters, scanned globally. This is
    /// the web's `/## [A-Za-z\s']+\n[^#]+/g` verbatim — and is **case-sensitive**
    /// (no `i` flag, unlike the lenient ``section(_:)`` reader).
    private static let templateSection = try! NSRegularExpression(
        pattern: "## [A-Za-z\\s']+\\n[^#]+"
    )
    /// `[0-9]`, not `\d` — see the type doc.
    ///
    /// Measured caveat, so nobody "proves" this is dead and drops it: swapping
    /// both of these to `\d` changes **no output**, and no test can be written
    /// that it would fail. `Int64(_: String)` is ASCII-only, so a Unicode-digit
    /// step yields `nil` → `Int64.max` → the order check rejects — the same
    /// `.invalid`, with the same message, that `[0-9]` reaches by not matching
    /// at all. The two spellings agree here **only because the regex and the
    /// integer parser happen to share an alphabet.** Make the parse
    /// Unicode-aware and `\d` starts accepting `١. Mix.` as step 1 while the web
    /// that published it does not. This is the guard that keeps that change
    /// safe, not a guard that is doing work today.
    ///
    /// `parseContent`'s ``numberedStep`` is the opposite case — there the
    /// dialect **is** observable, and
    /// `directions_unicodeDigitsAreNotStepNumbers_icuRegexDialectGuard` fails if
    /// it is relaxed.
    private static let leadingStepNumber = try! NSRegularExpression(pattern: "^[0-9]+\\.")
    private static let leadingDigits = try! NSRegularExpression(pattern: "^[0-9]+")

    // Exact Details field labels the web compares with `===`. The live bytes are
    // irregular: ⏲️ Prep carries U+FE0F and 🍽️ Servings carries U+FE0F, but
    // 🍳 Cook is the bare glyph (no selector). Matched verbatim — these gate only
    // the optional Details block, not the recipe/article decision.
    private static let prepKey = "- \u{23F2}\u{FE0F} Prep time"
    private static let cookKey = "- \u{1F373} Cook time"
    private static let servingsKey = "- \u{1F37D}\u{FE0F} Servings"

    /// Strict recipe-template validator — a byte-faithful port of the web
    /// editor's save-time guard `validateMarkdownTemplate` (`src/lib/parser.ts`).
    /// The web runs this BEFORE publishing, so every real zap.cooking recipe
    /// already satisfies it; porting it (rather than inventing a stricter rule)
    /// is what keeps iOS from over-rejecting genuine recipes — if the web
    /// shipped it, this accepts it.
    ///
    /// Acceptance rule, identical to the web:
    ///  - the body must contain at least one `## ` section;
    ///  - any `## Directions` must be a 1-based, strictly +1 incrementing
    ///    ordered list (a prose "Directions" section is rejected);
    ///  - after parsing there must be **at least one ingredient AND at least
    ///    one direction**.
    ///
    /// Unlike the lenient ``parseContent(_:)``, ingredient/direction lines are
    /// matched against the **raw** (un-trimmed) line exactly as the web does,
    /// and the `slice(1, -1)` / `slice(1)` line trimming is reproduced
    /// precisely. Length limits count **UTF-16 units**, because both the web's
    /// `String.length` and Kotlin's `String.length` do — Swift's `count` is
    /// grapheme clusters and would let a longer string through.
    static func validateMarkdownTemplate(_ markdown: String) -> TemplateValidation {
        var chefNotes: String?
        var prepTime = ""
        var cookTime = ""
        var servings = ""
        var ingredients: [String] = []
        var directions: [String] = []
        var additionalMarkdown: String?

        let sections = allMatches(templateSection, in: markdown)
        if sections.isEmpty { return .invalid("Sections are missing.") }

        for section in sections {
            if section.hasPrefix("## Chef's notes") {
                let notes = trimmed(String(section.dropFirst("## Chef's notes".count)))
                if notes.utf16.count > 99999 {
                    return .invalid("Chef's notes exceed character limit.")
                }
                chefNotes = notes
            } else if section.hasPrefix("## Details") {
                // JS: section.split('\n').slice(1, -1) — drop header + last line.
                for line in section.components(separatedBy: "\n").sliceMiddle() {
                    // JS destructures `const [key, value] = line.split(': ')` —
                    // value is the SECOND segment (nil when no ": " present).
                    let parts = line.components(separatedBy: ": ")
                    guard parts.count >= 2 else { continue }
                    let key = parts[0]
                    let value = parts[1]
                    switch key {
                    case prepKey:
                        if value.utf16.count > 999 { return .invalid("Prep time exceeds character limit.") }
                        prepTime = value
                    case cookKey:
                        if value.utf16.count > 999 { return .invalid("Cook time exceeds character limit.") }
                        cookTime = value
                    case servingsKey:
                        if value.utf16.count > 999 { return .invalid("Servings exceed character limit.") }
                        servings = value
                    default:
                        break
                    }
                }
            } else if section.hasPrefix("## Ingredients") {
                // JS: section.split('\n').slice(1, -1). Raw line, not trimmed.
                for line in section.components(separatedBy: "\n").sliceMiddle() where line.hasPrefix("- ") {
                    let ingredient = trimmed(String(line.dropFirst(2)))
                    if ingredient.utf16.count > 9999 {
                        return .invalid("An ingredient exceeds the character limit.")
                    }
                    ingredients.append(ingredient)
                }
            } else if section.hasPrefix("## Directions") {
                // JS: section.split('\n').slice(1) — drop only the header line.
                var prevStepNumber: Int64 = 0
                for line in section.components(separatedBy: "\n").dropFirst() {
                    guard let stepRange = firstMatchRange(leadingStepNumber, in: line) else {
                        if !trimmed(line).isEmpty {
                            return .invalid("Directions are not in the correct ordered list format.")
                        }
                        continue
                    }
                    // parseInt of the leading digits; overflow can't equal
                    // prev+1, so it falls through to the order-error like JS.
                    // `prevStepNumber` only ever advances by +1 from 0, so the
                    // `+ 1` below cannot overflow.
                    let digits = firstCapture(leadingDigits, in: line, group: 0) ?? ""
                    let stepNumber = Int64(digits) ?? Int64.max
                    if stepNumber != prevStepNumber + 1 {
                        return .invalid("Directions are not in the correct ordered list format.")
                    }
                    let stepDescription = trimmed(String(line[stepRange.upperBound...]))
                    if stepDescription.utf16.count > 9999 {
                        return .invalid("A step in the directions exceeds the character limit.")
                    }
                    directions.append(stepDescription)
                    prevStepNumber = stepNumber
                }
            } else if section.hasPrefix("## Additional Resources") {
                additionalMarkdown = trimmed(String(section.dropFirst("## Additional Resources".count)))
            }
        }

        if directions.isEmpty || ingredients.isEmpty {
            return .invalid("Directions and/or ingredients list too short.")
        }

        return .valid(
            RecipeContent(
                chefNotes: nonEmpty(chefNotes),
                details: RecipeDetails(
                    prepTime: nonEmpty(prepTime),
                    cookTime: nonEmpty(cookTime),
                    servings: nonEmpty(servings)
                ),
                ingredients: ingredients,
                directions: directions,
                additionalMarkdown: nonEmpty(additionalMarkdown)
            )
        )
    }

    // ---- Small shared helpers --------------------------------------------

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        return nonEmpty(trimmed(s))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// First match's capture `group` as a `String`, or nil when the pattern
    /// does not match / the group did not participate.
    private static func firstCapture(
        _ regex: NSRegularExpression,
        in s: String,
        group: Int = 1
    ) -> String? {
        let ns = s as NSString
        guard let match = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let range = match.range(at: group)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    private static func firstMatchRange(
        _ regex: NSRegularExpression,
        in s: String
    ) -> Range<String.Index>? {
        let ns = s as NSString
        guard let match = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Range(match.range, in: s)
    }

    private static func allMatches(_ regex: NSRegularExpression, in s: String) -> [String] {
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}

private extension Array where Element == String {
    /// JS `Array.prototype.slice(1, -1)`: drop the first and last elements.
    func sliceMiddle() -> ArraySlice<String> {
        count <= 2 ? [] : self[1..<(count - 1)]
    }
}
