import Foundation

/// Best-effort serving scaler for recipe ingredient lines.
///
/// Port of Android `nostr/IngredientScaler.kt` @ `68242f5` (byte-identical at
/// Android HEAD `e98c010`). Behaviour is intended to be identical; only syntax
/// is translated.
///
/// The frontend has no ingredient scaler to mirror, and recipe quantities are
/// free-text authored by humans, so this is deliberately conservative:
///
///  - It scales **only the leading quantity token** of a line. Secondary
///    alt-measures (`"60 mL water ¼ cup"`), oven temps (`"350°F"`), and prose
///    numbers (`"speed 2 or 3"`) are left untouched — scaling every number
///    would corrupt them. The leading qty is the one the cook actually adjusts.
///  - It understands integers, decimals, unicode vulgar fractions (`½ ⅓ ¾`…),
///    mixed numbers (`1½`, `1 ½`, `1 1/2`), simple fractions (`1/2`), and
///    ranges (`2-3`).
///  - On ANYTHING it can't parse, it returns the line **verbatim** — never
///    throws, never drops the ingredient. A recipe that renders but doesn't
///    scale a line is fine; a crash is not.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.4): ½× / 1× / 2× / 3×
/// chips scale the leading numeric token only. Servings chip scales; free-text
/// prep/cook do not.
///
/// Pure (no UIKit, no I/O) — unit-tested against the real Tuscan Peposo and
/// Japanese Milk Bread ingredient lines plus fraction/mixed/range/no-number
/// edges.
enum IngredientScaler {

    private static let eps = 1e-6

    /// Unicode vulgar fractions → value.
    private static let unicodeFractions: [Character: Double] = [
        "¼": 0.25, "½": 0.5, "¾": 0.75,
        "⅓": 1.0 / 3, "⅔": 2.0 / 3,
        "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8,
        "⅙": 1.0 / 6, "⅚": 5.0 / 6,
        "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
        "⅐": 1.0 / 7, "⅑": 1.0 / 9, "⅒": 0.1,
    ]

    /// (numerator, denominator) → unicode glyph, for reformatting scaled values.
    ///
    /// Kotlin keys this on `Pair<Int, Int>`; Swift tuples are not `Hashable`, so
    /// the pair is a named type. Same table, same lookups.
    private struct Ratio: Hashable {
        let numerator: Int
        let denominator: Int
    }

    private static let fractionGlyphs: [Ratio: Character] = [
        Ratio(numerator: 1, denominator: 2): "½",
        Ratio(numerator: 1, denominator: 3): "⅓", Ratio(numerator: 2, denominator: 3): "⅔",
        Ratio(numerator: 1, denominator: 4): "¼", Ratio(numerator: 3, denominator: 4): "¾",
        Ratio(numerator: 1, denominator: 8): "⅛", Ratio(numerator: 3, denominator: 8): "⅜",
        Ratio(numerator: 5, denominator: 8): "⅝", Ratio(numerator: 7, denominator: 8): "⅞",
    ]

    /// Scale the leading quantity of `line` by `multiplier`. Returns `line`
    /// unchanged when `multiplier` is 1.0 or the line has no leading quantity.
    static func scaleLine(_ line: String, multiplier: Double) -> String {
        if abs(multiplier - 1.0) < eps { return line }

        // Kotlin indexes `String` by `Int`; Swift does not. Scanning a
        // `[Character]` keeps every offset in the port identical to the source
        // and keeps `consumed` counts meaningful.
        let chars = Array(line)
        var leadCount = 0
        while leadCount < chars.count, chars[leadCount] == " " || chars[leadCount] == "\t" {
            leadCount += 1
        }
        let lead = String(chars[..<leadCount])
        let body = Array(chars[leadCount...])

        guard let first = parseQuantity(body) else { return line }
        let afterFirst = Array(body[first.consumed...])

        // Range: "2-3", "2 – 3" → scale both ends, keep the separator verbatim.
        if let sepLength = rangeSeparatorLength(afterFirst) {
            let rest = Array(afterFirst[sepLength...])
            if let second = parseQuantity(rest) {
                let a = formatQuantity(first.value * multiplier)
                let b = formatQuantity(second.value * multiplier)
                let separator = String(afterFirst[..<sepLength])
                let tail = String(rest[second.consumed...])
                return lead + a + separator + b + tail
            }
        }
        return lead + formatQuantity(first.value * multiplier) + String(afterFirst)
    }

    /// Length of a leading range separator — Kotlin's `Regex("^\\s*[-–—]\\s*")`
    /// — or nil when `s` does not start with one.
    private static func rangeSeparatorLength(_ s: [Character]) -> Int? {
        var i = 0
        while i < s.count, s[i].isWhitespace { i += 1 }
        guard i < s.count, s[i] == "-" || s[i] == "\u{2013}" || s[i] == "\u{2014}" else { return nil }
        i += 1
        while i < s.count, s[i].isWhitespace { i += 1 }
        return i
    }

    private struct Quantity {
        let value: Double
        let consumed: Int
    }

    /// ASCII digits only.
    ///
    /// Kotlin's `Char.isDigit()` is true for Unicode `Nd` and false for vulgar
    /// fractions. Swift's `Character.isNumber` is true for `½` and friends
    /// (category `No`), which would make `parseQuantity` consume a fraction
    /// glyph as an integer and change the port's behaviour.
    private static func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

    /// Parse a quantity at the start of `s`, or nil if there isn't one.
    private static func parseQuantity(_ s: [Character]) -> Quantity? {
        var i = 0
        while i < s.count, isDigit(s[i]) { i += 1 }
        let hasInt = i > 0
        let intText = String(s[..<i])

        // "1/2" — the leading integer is a fraction numerator (no space).
        if hasInt, i < s.count, s[i] == "/" {
            if let frac = matchAsciiFraction(s, from: 0) {
                return Quantity(value: frac.value, consumed: frac.consumed)
            }
        }

        // Decimal: "1.5", "0.25", ".5".
        if i < s.count, s[i] == "." {
            var j = i + 1
            let fracStart = j
            while j < s.count, isDigit(s[j]) { j += 1 }
            if j > fracStart {
                let text = (hasInt ? intText : "0") + "." + String(s[fracStart..<j])
                if let value = Double(text) {
                    return Quantity(value: value, consumed: j)
                }
            }
        }

        if hasInt {
            guard let whole = Double(intText) else { return nil }
            // Mixed with whitespace: "1 ½" or "1 1/2".
            var j = i
            while j < s.count, s[j] == " " { j += 1 }
            if j > i {
                if j < s.count, let fraction = unicodeFractions[s[j]] {
                    return Quantity(value: whole + fraction, consumed: j + 1)
                }
                if let frac = matchAsciiFraction(s, from: j) {
                    return Quantity(value: whole + frac.value, consumed: frac.consumed)
                }
            }
            // Adjacent mixed: "1½".
            if i < s.count, let fraction = unicodeFractions[s[i]] {
                return Quantity(value: whole + fraction, consumed: i + 1)
            }
            return Quantity(value: whole, consumed: i)
        }

        // No integer: bare unicode fraction "½", or bare "a/b".
        if i < s.count, let fraction = unicodeFractions[s[i]] {
            return Quantity(value: fraction, consumed: i + 1)
        }
        guard let frac = matchAsciiFraction(s, from: 0) else { return nil }
        return Quantity(value: frac.value, consumed: frac.consumed)
    }

    private struct AsciiFraction {
        let value: Double
        let consumed: Int
    }

    /// Match `\d+/\d+` starting at `start`.
    private static func matchAsciiFraction(_ s: [Character], from start: Int) -> AsciiFraction? {
        var i = start
        let numStart = i
        while i < s.count, isDigit(s[i]) { i += 1 }
        if i == numStart { return nil }
        if i >= s.count || s[i] != "/" { return nil }
        i += 1
        let denStart = i
        while i < s.count, isDigit(s[i]) { i += 1 }
        if i == denStart { return nil }
        guard let num = Double(String(s[numStart..<(denStart - 1)])),
              let den = Double(String(s[denStart..<i])) else { return nil }
        if den == 0 { return nil }
        return AsciiFraction(value: num / den, consumed: i)
    }

    /// Render a scaled value back to a clean integer / mixed-fraction / decimal
    /// string.
    ///
    /// Not private: golden `mixedFractionAdjacent_oneAndAHalf_rendersWithGlyph`
    /// calls it directly, matching Android where it is `internal fun`.
    static func formatQuantity(_ value: Double) -> String {
        if value < 0 { return trimDecimal(value) }
        let whole = Int(floor(value + eps))
        let frac = value - Double(whole)
        if frac < eps { return String(whole) }

        if let (text, isUnicode) = fractionString(frac) {
            if whole == 0 { return text }
            return isUnicode ? "\(whole)\(text)"      // "1½"
                             : "\(whole) \(text)"     // "1 1/3"
        }
        return trimDecimal(value)
    }

    /// A fraction in [0,1) as (renderedText, isUnicodeGlyph), or nil if not a
    /// tidy fraction.
    private static func fractionString(_ frac: Double) -> (String, Bool)? {
        for den in [2, 3, 4, 8] {
            let num = Int((frac * Double(den)).rounded())
            if num <= 0 || num >= den { continue }
            if abs(frac - Double(num) / Double(den)) > eps { continue }
            let g = gcd(num, den)
            let rn = num / g
            let rd = den / g
            if let glyph = fractionGlyphs[Ratio(numerator: rn, denominator: rd)] {
                return (String(glyph), true)
            }
            return ("\(rn)/\(rd)", false)
        }
        return nil
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Kotlin uses `String.format(Locale.US, "%.2f", …)`.
    ///
    /// `String(format:)` without a locale is POSIX and always emits `.` as the
    /// decimal separator, which is what this needs. `NumberFormatter` would
    /// **not** work here: it is locale-aware, emits `1,50` under a
    /// comma-decimal locale, and still passes every golden on a US simulator
    /// while mangling quantities for a European member.
    private static func trimDecimal(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
