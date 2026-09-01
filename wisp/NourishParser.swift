import Foundation

/// One of the 8 Nourish health dimensions: display name + 0–10 score.
nonisolated struct NourishDimension: Equatable, Sendable {
    var name: String
    var score: Int
}

/// Per-serving macro estimate (honest rounding applied server-side).
nonisolated struct NourishMacroPerServing: Equatable, Sendable {
    var kcal: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
}

/// Additive macro block (prompt v4). Sibling to scores — not a ninth dimension.
nonisolated struct NourishMacros: Equatable, Sendable {
    var perServing: NourishMacroPerServing
    var servingsUsed: Int
    var servingsParsed: Bool
    /// `estimate` (default) or `rough`.
    var confidence: String
    var method: String
}

/// Resolved macros-row view for `NourishCard`. `nil` means "do not render".
nonisolated struct MacrosRowView: Equatable, Sendable {
    var label: String
    var tone: String
    var kcal: Int
    var proteinG: Int
    var carbsG: Int
    var fatG: Int
}

/// A recipe's Nourish health analysis.
nonisolated struct NourishScore: Equatable, Sendable {
    var overall: Int
    var overallLabel: String
    var dimensions: [NourishDimension]
    var improvements: [String]
    var macros: NourishMacros?
}

/// Parses kind-30078 Nourish JSON. Port of Android `NourishParser.kt`.
/// **Trust the stored `overall`** — never recompute from dimensions.
nonisolated enum NourishParser {
    /// Zap Cooking service account that publishes Nourish events.
    /// Frontend `NOURISH_SERVICE_PUBKEY` / member-relay `nourishServicePubkey`.
    static let servicePubkey =
        "fdd263f69f9e95a2a0a58ec3e7e8053011214fa66007d93b26d2f4717d31917b"

    static let kind = 30078

    /// (content key, display name), Android/web display order.
    static let dimensions: [(key: String, name: String)] = [
        ("realFood", "Real Food"),
        ("gut", "Gut"),
        ("protein", "Protein"),
        ("antiInflammatory", "Anti-Inflammatory"),
        ("bloodSugar", "Blood Sugar"),
        ("immuneSupportive", "Immune"),
        ("brainHealth", "Brain"),
        ("heartHealth", "Heart"),
    ]

    static func dTag(recipeAuthor: String, recipeDTag: String) -> String {
        "nourish:30023:\(recipeAuthor):\(recipeDTag)"
    }

    static func parse(_ content: String) -> NourishScore? {
        guard let data = content.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any]
        else { return nil }
        guard var score = parseScores(obj, improvements: extractImprovements(obj)) else {
            return nil
        }
        score.macros = parseMacros(obj["macros"])
        return score
    }

    /// Shared core for pantry content (dims at top level) and compute
    /// responses (`scores` nested). Trusts stored `overall`.
    static func parseScores(
        _ scores: [String: Any],
        improvements: [String]
    ) -> NourishScore? {
        guard let overallObj = scores["overall"] as? [String: Any],
              let overallRaw = number(overallObj["score"])
        else { return nil }
        let overall = clampScore(overallRaw)
        let overallLabel = (overallObj["label"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? labelFor(overall)
        let dims = dimensions.map { key, name in
            let s = (scores[key] as? [String: Any]).flatMap { number($0["score"]) } ?? 0
            return NourishDimension(name: name, score: clampScore(s))
        }
        return NourishScore(
            overall: overall,
            overallLabel: overallLabel,
            dimensions: dims,
            improvements: improvements,
            macros: nil
        )
    }

    static func extractImprovements(_ obj: [String: Any]) -> [String] {
        guard let arr = obj["improvements"] as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(5)
            .map { $0 }
    }

    static func parseMacros(_ raw: Any?) -> NourishMacros? {
        guard let m = raw as? [String: Any],
              let ps = m["perServing"] as? [String: Any],
              let kcal = nonNegInt(ps["kcal"]),
              let proteinG = nonNegInt(ps["protein_g"]),
              let carbsG = nonNegInt(ps["carbs_g"]),
              let fatG = nonNegInt(ps["fat_g"]),
              let servingsUsed = positiveInt(m["servingsUsed"]),
              let servingsParsed = bool(m["servingsParsed"])
        else { return nil }
        guard let confidence = m["confidence"] as? String,
              confidence == "estimate" || confidence == "rough"
        else { return nil }
        let methodRaw = m["method"] as? String
        let method = methodRaw == "llm-per100g-v1" ? methodRaw! : "llm-per100g-v1"
        return NourishMacros(
            perServing: NourishMacroPerServing(
                kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG
            ),
            servingsUsed: servingsUsed,
            servingsParsed: servingsParsed,
            confidence: confidence,
            method: method
        )
    }

    static func macrosRowView(_ macros: NourishMacros?) -> MacrosRowView? {
        guard let macros else { return nil }
        let per = macros.perServing
        let tone = macros.confidence == "rough" ? "rough" : "estimate"
        let base = tone == "rough" ? "Rough estimate" : "Estimated per serving"
        let label = macros.servingsParsed
            ? base
            : "\(base) (servings assumed: \(macros.servingsUsed))"
        return MacrosRowView(
            label: label,
            tone: tone,
            kcal: per.kcal,
            proteinG: per.proteinG,
            carbsG: per.carbsG,
            fatG: per.fatG
        )
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private static func bool(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }

    private static func nonNegInt(_ any: Any?) -> Int? {
        guard let n = number(any), n.isFinite, n >= 0 else { return nil }
        return Int(n.rounded())
    }

    private static func positiveInt(_ any: Any?) -> Int? {
        guard let n = number(any), n.isFinite, n > 0 else { return nil }
        return Int(n.rounded())
    }

    private static func clampScore(_ raw: Double) -> Int {
        min(10, max(0, Int(raw.rounded())))
    }

    static func labelFor(_ score: Int) -> String {
        switch score {
        case ...2: "Low"
        case ...4: "Fair"
        case ...6: "Moderate"
        case ...8: "Strong"
        default: "Excellent"
        }
    }
}

/// Kill switch seam — call sites branch here, not on `FeatureFlags` literals.
enum NourishGate {
    static func entryVisible(flagEnabled: Bool = FeatureFlags.nourishEnabled) -> Bool {
        flagEnabled
    }
}

/// Pinned public pantry filter. Adding a tag to `publicCorpus` fails
/// `NourishFilterShapeTests`.
enum NourishFilter {
    /// Corpus REQ: `authors=[service]`, `kinds=[30078]`, `limit=200`.
    /// Narrowing `#d`/`#l` are constructed separately; they must never land here.
    static let publicCorpus = NostrFilter(
        kinds: [NourishParser.kind],
        authors: [NourishParser.servicePubkey],
        limit: 200
    )

    static func recipeScore(author: String, dTag: String) -> NostrFilter {
        NostrFilter(
            kinds: [NourishParser.kind],
            authors: [NourishParser.servicePubkey],
            dTags: [NourishParser.dTag(recipeAuthor: author, recipeDTag: dTag)],
            limit: 1
        )
    }

    static func labeled(_ label: String) -> NostrFilter {
        var filter = publicCorpus
        filter.lTags = [label]
        return filter
    }

    static func encodedKeys(_ filter: NostrFilter) -> Set<String> {
        guard let data = filter.toJSON().data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(obj.keys)
    }
}
