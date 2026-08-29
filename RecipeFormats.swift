import Foundation

/// Registry of the recipe formats the app understands. **The single extension
/// point**: adding a second format is a one-line edit to ``active`` (plus a new
/// `RecipeFormat` implementation) — no changes to the screens, feeds, compose
/// form, or domain model.
///
/// Today only `Nip23RecipeFormat` is registered, so every read/write resolves to
/// NIP-23 and behavior is identical to before the seam existed.
///
/// The future second format is ``Nip333RecipeFormat`` below — compile-checked
/// against `RecipeFormat` but deliberately **not** in ``active`` and never
/// iterated at runtime, so its unimplemented bodies can't fire. When it's ready:
/// implement it and add it here with a higher `formatRank`.
///
/// Port of Android `nostr/RecipeFormats.kt` @ `68242f5`.
enum RecipeFormats {

    /// Formats consulted on read, in priority order. Iterated at runtime.
    static let active: [any RecipeFormat] = [Nip23RecipeFormat()]

    /// The format used to author new recipes.
    static let primary: any RecipeFormat = Nip23RecipeFormat()

    /// The first active format that recognizes `event`, or nil if none does.
    static func forEvent(_ event: NostrEvent) -> (any RecipeFormat)? {
        active.first { $0.matches(event) }
    }

    /// `event`'s active-format rank (for `dedupeAcrossFormats`), or nil if no
    /// format owns it.
    static func rankOf(_ event: NostrEvent) -> Int? {
        forEvent(event)?.formatRank
    }
}

/// **STUB — not implemented, not registered.** A placeholder for a future
/// dedicated recipe NIP (e.g. a `kind 333xx`), kept as real code so the
/// `RecipeFormat` contract stays honest: if the protocol changes, this type
/// breaks the build and must be updated in lockstep — a doc comment would
/// silently rot instead.
///
/// **Guard:** this type is referenced **only as a type**. It is NOT in
/// ``RecipeFormats/active``, NOT ``RecipeFormats/primary``, and must never be
/// added to any runtime list or test that iterates formats — so none of the
/// unimplemented bodies below can ever execute. Activating it is a future
/// concern: implement these members, give it a `formatRank` above
/// `Nip23RecipeFormat` (0), and register it in ``RecipeFormats/active``. See the
/// dual-write edit-sync caveat in `RecipeFormat` before turning it on.
///
/// **Co-located with the registry rather than in its own file, deliberately.**
/// Swift has no one-type-per-file rule, and the six recipe implementation files
/// are hand-registered at the repo root — a seventh would mean editing
/// `project.pbxproj`, which parallel concern work must not touch. Keeping it
/// here also puts the guard beside `active`, so anyone editing the registry sees
/// what must not go into it. Moving it to its own file when the NIP is adopted
/// is a deliberate project-file commit at the moment you would want one.
struct Nip333RecipeFormat: RecipeFormat {

    var kind: Int {
        fatalError("Assign the dedicated recipe kind when this NIP is adopted.")
    }

    var formatRank: Int {
        fatalError("Rank above Nip23RecipeFormat (0) so it wins the cross-format pick.")
    }

    func matches(_ event: NostrEvent) -> Bool {
        fatalError("Recognize this format's events (kind + any tag qualifier).")
    }

    func parse(_ event: NostrEvent) -> RecipeParser.Recipe {
        fatalError("Decode this format into the shared RecipeParser.Recipe model.")
    }

    func serialize(
        recipe: RecipeParser.Recipe,
        title: String,
        imageUrls: [String],
        categories: [String]
    ) -> UnsignedRecipeEvent {
        fatalError("Encode RecipeParser.Recipe into this format's unsigned event.")
    }

    func serializeEdit(
        recipe: RecipeParser.Recipe,
        title: String,
        imageUrls: [String],
        categories: [String],
        original: NostrEvent
    ) -> UnsignedRecipeEvent {
        fatalError(
            "Encode an edit: preserve original's identifier and publication moment, "
                + "and carry over every tag this format does not generate."
        )
    }

    func slug(_ title: String) -> String {
        fatalError("Derive this format's addressable identifier from the title.")
    }

    func feedFilter(limit: Int, until: Int?) -> NostrFilter {
        fatalError("Relay filter for this format's recipe feed.")
    }

    func authorFeedFilter(author: String, limit: Int, until: Int?) -> NostrFilter {
        fatalError("Relay filter for this format's recipes scoped to one author.")
    }

    func coordinateFilter(author: String, dTag: String) -> NostrFilter {
        fatalError("Relay filter to resolve a single recipe by coordinate.")
    }

    func searchFilter(query: String, limit: Int) -> NostrFilter {
        fatalError("NIP-50 search filter for this format's recipes.")
    }

    func tagFeedFilter(tag: String, limit: Int, until: Int?) -> NostrFilter {
        fatalError("Relay filter for one category/tag feed in this format.")
    }
}
