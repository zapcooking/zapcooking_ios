import Foundation

/// Inverse of `RecipeParser` — serializes a structured recipe into kind-30023
/// markdown body + tags for publish.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 2 / 2.1):
/// - `d = slug(title)` (spaces → `-` only; keep parens/slashes).
/// - Tags: `t:zapcooking` + `t:zapcooking-<slug>` + `t:zapcooking-<category>`,
///   image tags; **no `published_at`** on create.
/// - Round-trip tested (serialize → parse → equals) against the real Tuscan
///   Peposo event.
///
/// Stub — Concern 1.0 scaffolding. Implementation lands in Concern 2.1.
enum RecipeSerializer {
    static func slug(_ title: String) -> String {
        fatalError("unimplemented")
    }

    static func toContent(_ recipe: RecipeParser.Recipe) -> String {
        fatalError("unimplemented")
    }

    static func toTags(
        title: String,
        summary: String?,
        imageUrls: [String],
        categories: [String],
        identifier: String? = nil,
        publishedAt: Int64? = nil
    ) -> [[String]] {
        fatalError("unimplemented")
    }

    static func mergeForEdit(
        originalTags: [[String]],
        newTags: [[String]]
    ) -> [[String]] {
        fatalError("unimplemented")
    }
}
