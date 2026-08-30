import Foundation

/// Navigation route for a recipe — `recipe/{author}/{dTag}`.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §2 / Concern 1.3): real d-tags carry
/// `(`, `)` and `/`, so the d-tag is **URL-encoded at every route boundary**.
/// The stored `dTag` stays raw — that is the coordinate `RecipeRepository`
/// joins on. Encoding here, decoding on parse; never sanitize in the
/// repository.
///
/// `kind` is not on the path. Recipes are kind 30023 today; the format seam
/// owns that, not the route.
struct RecipeRoute: Hashable {
    /// Hex pubkey of the recipe author.
    let author: String
    /// Addressable `d` tag, **raw** (parens and slashes intact).
    let dTag: String

    /// `recipe/{author}/{percent-encoded dTag}`.
    var path: String {
        "recipe/\(author)/\(Self.encodeDTag(dTag))"
    }

    /// RFC 3986 unreserved only, so `(`, `)` and `/` always encode.
    /// `CharacterSet.urlPathAllowed` keeps `/`, which would split the d-tag
    /// across path segments.
    static func encodeDTag(_ dTag: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return dTag.addingPercentEncoding(withAllowedCharacters: allowed) ?? dTag
    }

    static func decodeDTag(_ encoded: String) -> String {
        encoded.removingPercentEncoding ?? encoded
    }

    /// Parse `recipe/{author}/{encodedDTag}`. Returns nil when the path is
    /// the wrong shape or either half is empty.
    static func parse(_ path: String) -> RecipeRoute? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3, parts[0] == "recipe",
              !parts[1].isEmpty, !parts[2].isEmpty
        else { return nil }
        return RecipeRoute(author: parts[1], dTag: decodeDTag(parts[2]))
    }
}
