import Foundation

/// Best-effort serving scaler for recipe ingredient lines.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.4):
/// - ½× / 1× / 2× / 3× chips scale the **leading numeric token only**
///   (secondary alt-measures stay unscaled).
/// - Understands integers, decimals, unicode + mixed + ascii fractions,
///   and ranges.
/// - Returns the line **verbatim when unparseable** — never crashes, never
///   mangles. Servings chip scales; free-text prep/cook do not.
///
/// Stub — Concern 1.0 scaffolding. Implementation lands in Concern 1.4.
enum IngredientScaler {
    static func scaleLine(_ line: String, multiplier: Double) -> String {
        fatalError("unimplemented")
    }
}
