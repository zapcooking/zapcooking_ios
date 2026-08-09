import Foundation

/// Registry of recipe formats the app understands. The single extension
/// point: adding a second format is a one-line edit to `active` (plus a new
/// `RecipeFormat` implementation) — no screen / feed / domain-model rewrite.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 2 / 2.2):
/// - Today only `Nip23RecipeFormat` is registered.
/// - Future `Nip333RecipeFormat` stays compile-checked but **not** in
///   `active` until implemented (so stub bodies never run).
/// - Dual-write caveat: rank-before-recency can mask a newer low-rank edit.
///
/// Stub — Concern 1.0 scaffolding. Implementation lands in Concern 2.2.
enum RecipeFormats {
    static var active: [any RecipeFormat] {
        fatalError("unimplemented")
    }

    static var primary: any RecipeFormat {
        fatalError("unimplemented")
    }

    static func forEvent(_ event: NostrEvent) -> (any RecipeFormat)? {
        fatalError("unimplemented")
    }

    static func rankOf(_ event: NostrEvent) -> Int? {
        fatalError("unimplemented")
    }
}
