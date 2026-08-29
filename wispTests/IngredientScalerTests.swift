import Foundation
import Testing
@testable import wisp

/// Golden conformance for `IngredientScaler`, ported from Android
/// `IngredientScalerTest` @ `68242f5`
/// (`app/src/test/kotlin/cooking/zap/app/nostr/IngredientScalerTest.kt`,
/// 11 tests, byte-identical at Android HEAD `e98c010`).
///
/// `IngredientScaler` is best-effort and must never corrupt or drop a line.
/// These cases use the REAL ingredient lines from the Tuscan Peposo and
/// Japanese Milk Bread events (Step-0 capture) plus the fraction / mixed /
/// range / no-number edges the parser has to survive.
///
/// The passthrough golden matters at least as much as the scaling ones: an
/// implementation that quietly mangles an unparseable line corrupts a recipe,
/// and every scaling test stays green while it does.
///
/// **Confusable characters are written as `\u{...}` escapes, not pasted
/// glyphs.** `-` (U+002D), `–` (U+2013) and `—` (U+2014) are all range
/// separators the scaler must keep *verbatim*, and they are indistinguishable
/// by eye in a diff. An editor pass that "normalized" them would silently
/// change what the range golden tests. Same convention `RecipeParserTests`
/// uses for the emoji variation selectors.
struct IngredientScalerTests {

    private func x2(_ line: String) -> String { IngredientScaler.scaleLine(line, multiplier: 2.0) }
    private func half(_ line: String) -> String { IngredientScaler.scaleLine(line, multiplier: 0.5) }

    @Test func multiplierOne_isIdentity() {
        let line = "1 kg beef for stewing (chuck or similar)"
        #expect(IngredientScaler.scaleLine(line, multiplier: 1.0) == line)
    }

    // MARK: - Real Tuscan Peposo lines

    @Test func realTuscanLines_scaleLeadingQuantityOnly() {
        #expect(x2("1 kg beef for stewing (chuck or similar)") == "2 kg beef for stewing (chuck or similar)")
        #expect(x2("750 ml red wine") == "1500 ml red wine")
        #expect(x2("4 garlic cloves") == "8 garlic cloves")
        #expect(x2("2 tbsp black pepper (coarsely ground)") == "4 tbsp black pepper (coarsely ground)")
        // No leading quantity -> verbatim.
        #expect(x2("Salt") == "Salt")
        #expect(x2("Extra virgin olive oil") == "Extra virgin olive oil")
    }

    @Test func realTuscanLines_halve() {
        #expect(half("1 kg beef for stewing (chuck or similar)") == "½ kg beef for stewing (chuck or similar)")
        #expect(half("750 ml red wine") == "375 ml red wine")
        #expect(half("4 garlic cloves") == "2 garlic cloves")
        #expect(half("2 tbsp black pepper (coarsely ground)") == "1 tbsp black pepper (coarsely ground)")
    }

    // MARK: - Real Milk Bread lines: only the LEADING measure scales

    @Test func realMilkBreadLines_secondaryMeasuresUntouched() {
        // "60 mL water ¼ cup" -> the ¼ cup alt-measure must NOT scale.
        #expect(x2("60 mL water ¼ cup") == "120 mL water ¼ cup")
        #expect(x2("23 g bread flour 2 tbsp") == "46 g bread flour 2 tbsp")
        // "58 g unsalted butter softened, 4 tbsp / ½ stick" -> only the 58 g.
        #expect(x2("58 g unsalted butter softened, 4 tbsp / ½ stick") == "116 g unsalted butter softened, 4 tbsp / ½ stick")
        #expect(x2("1 tsp sea salt") == "2 tsp sea salt")
        // Header-ish lines with no number stay verbatim.
        #expect(x2("For the Tangzhong") == "For the Tangzhong")
    }

    // MARK: - Fraction / mixed-number forms

    @Test func unicodeFraction_scales() {
        #expect(x2("½ cup sugar") == "1 cup sugar")                                    // ½ * 2 = 1
        #expect(x2("⅓ cup milk") == "⅔ cup milk")                                      // ⅓ * 2 = ⅔
        #expect(IngredientScaler.scaleLine("⅓ cup flour", multiplier: 3.0) == "1 cup flour") // ⅓ * 3 = 1
        #expect(half("½ cup oil") == "¼ cup oil")                                       // ½ * 0.5 = ¼
    }

    @Test func mixedNumbers_allForms_scale() {
        #expect(x2("1½ cups flour") == "3 cups flour")       // adjacent unicode
        #expect(x2("1 ½ cups flour") == "3 cups flour")      // spaced unicode
        #expect(x2("1 1/2 cups flour") == "3 cups flour")    // spaced ascii
        #expect(IngredientScaler.scaleLine("¾ cups flour", multiplier: 2.0) == "1½ cups flour") // ¾*2 = 1½ -> glyph
    }

    @Test func simpleAsciiFraction_scales() {
        #expect(x2("1/2 tsp vanilla") == "1 tsp vanilla")
        #expect(half("1/2 tsp salt") == "¼ tsp salt")  // ½ * 0.5 = ¼ glyph
    }

    @Test func decimal_scales() {
        #expect(x2("0.5 L stock") == "1 L stock")
        #expect(x2("1.5 lb roast") == "3 lb roast")
    }

    @Test func range_scalesBothEnds_keepsSeparator() {
        // U+002D HYPHEN-MINUS, no surrounding spaces.
        #expect(x2("2\u{002D}3 cloves garlic") == "4\u{002D}6 cloves garlic")
        // U+2013 EN DASH, spaces on both sides — separator preserved verbatim.
        #expect(x2("2 \u{2013} 3 eggs") == "4 \u{2013} 6 eggs")
    }

    // MARK: - Robustness: never crash, never drop

    @Test func noLeadingNumber_returnedVerbatim() {
        #expect(x2("Pinch of salt") == "Pinch of salt")
        #expect(x2("A couple eggs") == "A couple eggs")
        #expect(x2("") == "")
        #expect(x2("Salt to taste (about 350°F oven)") == "Salt to taste (about 350°F oven)")
    }

    @Test func mixedFractionAdjacent_oneAndAHalf_rendersWithGlyph() {
        // 0.75 (¾) -> scale x2 -> 1.5 -> "1½"
        #expect(IngredientScaler.formatQuantity(1.5) == "1½")
        #expect(IngredientScaler.formatQuantity(2.0) == "2")
        #expect(IngredientScaler.formatQuantity(1.0 / 3) == "⅓")
    }
}
