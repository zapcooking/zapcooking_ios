import Foundation

/// The Gadgets converter's units and arithmetic, ported from Zap Cooking
/// Android's `CookingUtilitiesSheet` (`MeasUnit` / `ALL_UNITS` / `convert`).
///
/// Kept free of SwiftUI so the conversions are testable on their own — the
/// temperature branch in particular is the one that cannot be a plain scale
/// factor, and it is the one worth pinning.
enum CookingConverter {

    enum Category: String, CaseIterable, Equatable {
        case volume, weight, temperature
    }

    /// A unit and its ratio to the category's base (mL for volume, g for
    /// weight). Temperature carries no factor — it converts through an
    /// offset instead, so `toBase` is unused there.
    struct Unit: Identifiable, Equatable, Hashable {
        let abbrev: String
        let category: Category
        var toBase: Double = 1

        var id: String { abbrev }

        /// Fahrenheit is the one unit that is not a plain multiple of its
        /// base: it carries a 32° offset as well as a ratio.
        func toBaseValue(_ value: Double) -> Double {
            isFahrenheit ? (value - 32) * 5 / 9 : value * toBase
        }

        func fromBaseValue(_ base: Double) -> Double {
            isFahrenheit ? base * 9 / 5 + 32 : base / toBase
        }

        private var isFahrenheit: Bool { category == .temperature && abbrev == "°F" }
    }

    /// Android's `ALL_UNITS`, same order — the pickers list them like this.
    static let allUnits: [Unit] = [
        Unit(abbrev: "tsp", category: .volume, toBase: 4.92892),
        Unit(abbrev: "tbsp", category: .volume, toBase: 14.7868),
        Unit(abbrev: "cup", category: .volume, toBase: 236.588),
        Unit(abbrev: "fl oz", category: .volume, toBase: 29.5735),
        Unit(abbrev: "mL", category: .volume, toBase: 1),
        Unit(abbrev: "L", category: .volume, toBase: 1000),
        Unit(abbrev: "g", category: .weight, toBase: 1),
        Unit(abbrev: "kg", category: .weight, toBase: 1000),
        Unit(abbrev: "oz", category: .weight, toBase: 28.3495),
        Unit(abbrev: "lb", category: .weight, toBase: 453.592),
        Unit(abbrev: "°C", category: .temperature),
        Unit(abbrev: "°F", category: .temperature),
    ]

    struct QuickPreset: Identifiable, Equatable {
        let amount: Double
        let unit: Unit
        var id: String { "\(amount)-\(unit.abbrev)" }
        var label: String { "\(formatResult(amount)) \(unit.abbrev)" }
    }

    static let quickPresets: [QuickPreset] = [
        QuickPreset(amount: 1, unit: unit("tsp")),
        QuickPreset(amount: 1, unit: unit("tbsp")),
        QuickPreset(amount: 1, unit: unit("cup")),
        QuickPreset(amount: 250, unit: unit("mL")),
        QuickPreset(amount: 100, unit: unit("g")),
        QuickPreset(amount: 1, unit: unit("oz")),
    ]

    static let defaultFrom = "cup"
    static let defaultTo = "mL"

    /// Lookup by abbreviation. Traps on an unknown name — every caller passes
    /// a literal from `allUnits`, so a miss is a programming error, not input.
    static func unit(_ abbrev: String) -> Unit {
        guard let u = allUnits.first(where: { $0.abbrev == abbrev }) else {
            preconditionFailure("no unit \(abbrev)")
        }
        return u
    }

    /// Resolves a stored abbreviation, falling back when it names a unit this
    /// build no longer ships.
    static func unit(stored: String?, fallback: String) -> Unit {
        allUnits.first { $0.abbrev == stored } ?? unit(fallback)
    }

    /// Nil when the units are of different kinds — grams into millilitres is
    /// not a conversion, it is a density question.
    static func convert(_ amount: Double, from: Unit, to: Unit) -> Double? {
        guard from.category == to.category else { return nil }
        guard from != to else { return amount }
        return to.fromBaseValue(from.toBaseValue(amount))
    }

    /// Whole numbers print bare; everything else gets four significant digits
    /// with trailing zeros trimmed. Matches Android's `formatResult`.
    static func formatResult(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var s = String(format: "%.4g", value)
        if s.contains(".") && !s.lowercased().contains("e") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// The partner unit to switch to when a pick changes category — the first
    /// other unit in the new category, as Android does.
    static func partner(for unit: Unit) -> Unit {
        allUnits.first { $0.category == unit.category && $0 != unit } ?? unit
    }

    /// Digits and at most one decimal point, capped at 12 characters like
    /// Android's `take(12)`. Extra separators are dropped rather than
    /// left in, so `"1..2"` cannot sit in the field and fail to parse.
    static func sanitizeAmount(_ raw: String) -> String {
        var seenDot = false
        var out = ""
        for ch in raw {
            if ch.isNumber {
                out.append(ch)
            } else if ch == ".", !seenDot {
                out.append(ch)
                seenDot = true
            } else {
                continue
            }
            if out.count == 12 { break }
        }
        return out
    }
}
