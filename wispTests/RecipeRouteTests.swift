import Foundation
import Testing
@testable import wisp

/// Gate for Concern 1.3 — the recipe route encodes hostile d-tag characters
/// at the boundary and keeps the stored d-tag raw for the repository join.
struct RecipeRouteTests {

    @Test func path_encodesParenthesesAndSlashes() {
        let route = RecipeRoute(
            author: String(repeating: "a", count: 64),
            dTag: "tuscan-peposo-(black-pepper-beef-stew)/v2"
        )
        #expect(route.path.contains("%28"))
        #expect(route.path.contains("%29"))
        #expect(route.path.contains("%2F"))
        #expect(!route.path.contains("("))
        #expect(!route.path.contains(")"))
        // The slash between recipe/author is the only raw slash.
        let slashes = route.path.filter { $0 == "/" }
        #expect(slashes.count == 2)
    }

    @Test func storedDTag_staysRaw() {
        let dTag = "tuscan-peposo-(black-pepper-beef-stew)/v2"
        let route = RecipeRoute(author: "ab", dTag: dTag)
        #expect(route.dTag == dTag)
    }

    @Test func parse_roundTripsHostileDTag() {
        let author = String(repeating: "b", count: 64)
        let dTag = "tuscan-peposo-(black-pepper-beef-stew)/v2"
        let route = RecipeRoute(author: author, dTag: dTag)
        let parsed = RecipeRoute.parse(route.path)
        #expect(parsed?.author == author)
        #expect(parsed?.dTag == dTag)
    }

    @Test func parse_rejectsWrongShape() {
        #expect(RecipeRoute.parse("article/aa/bb") == nil)
        #expect(RecipeRoute.parse("recipe/aa") == nil)
        #expect(RecipeRoute.parse("recipe/") == nil)
        #expect(RecipeRoute.parse("") == nil)
        // Extra `/` segment: an unencoded slash-bearing d-tag is malformed.
        #expect(RecipeRoute.parse("recipe/aa/a/b") == nil)
        #expect(RecipeRoute.parse("recipe/aa/bb/") == nil)
    }

    @Test func encodeDTag_leavesUnreservedAlone() {
        #expect(RecipeRoute.encodeDTag("simple-slug") == "simple-slug")
    }

    /// `CharacterSet.alphanumerics` is Unicode-wide and would leave these
    /// unescaped. The encoder must not.
    @Test func encodeDTag_percentEncodesNonASCII() {
        let encoded = RecipeRoute.encodeDTag("café")
        #expect(!encoded.contains("é"))
        #expect(encoded.contains("%"))
        #expect(RecipeRoute.decodeDTag(encoded) == "café")
    }
}
