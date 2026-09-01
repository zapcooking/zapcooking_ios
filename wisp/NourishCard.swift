import SwiftUI

/// Green-island Nourish card — port of Android `NourishCard.kt`.
/// Quiet miss is handled by the caller (renders nothing).
struct NourishCard: View {
    let score: NourishScore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 8)
            header
            strengths
            macros
            profile
            upgrades
            Text("Profiles are estimates based on ingredients. Not medical advice.")
                .font(AppFont.bodySmall)
                .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.6))
                .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier("nourish-card")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NourishGreen.strong)
            Text("Nourish")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
            Spacer(minLength: 0)
            Text("\(score.overall)/10")
                .font(AppFont.titleMedium)
                .fontWeight(.bold)
                .foregroundStyle(NourishGreen.strong)
            if let label = affirmingLabel(overall: score.overall, label: score.overallLabel) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NourishGreen.strong)
            }
        }
    }

    @ViewBuilder
    private var strengths: some View {
        let pills = topStrengths(score.dimensions)
        if !pills.isEmpty {
            sectionLabel("What this meal brings")
                .padding(.top, 14)
            FlowWrap(pills) { label in
                HStack(spacing: 4) {
                    Image(systemName: "leaf")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NourishGreen.strong)
                    Text(label)
                        .font(AppFont.bodySmall)
                        .fontWeight(.medium)
                        .foregroundStyle(NourishGreen.strong)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(NourishGreen.strong.opacity(0.10), in: Capsule())
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var macros: some View {
        if let view = NourishParser.macrosRowView(score.macros) {
            let rough = view.tone == "rough"
            VStack(alignment: .leading, spacing: 6) {
                Text(rough ? view.label : view.label.uppercased())
                    .font(.caption.weight(rough ? .medium : .semibold))
                    .italic(rough)
                    .foregroundStyle(
                        Color.wispOnSurfaceVariant.opacity(rough ? 0.85 * 0.72 : 0.6)
                    )
                HStack(spacing: 6) {
                    macroFigure("\(view.kcal)", "kcal", rough: rough)
                    macroFigure("\(view.proteinG)", "g protein", rough: rough)
                    macroFigure("\(view.carbsG)", "g carbs", rough: rough)
                    macroFigure("\(view.fatG)", "g fat", rough: rough)
                }
            }
            .padding(.top, 14)
        }
    }

    private func macroFigure(_ value: String, _ unit: String, rough: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(AppFont.bodyLarge.weight(rough ? .medium : .semibold))
                .foregroundStyle(Color.wispOnSurface.opacity(rough ? 0.72 : 1))
            Text(unit)
                .font(.caption)
                .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Nourish Profile")
                .padding(.top, 14)
            let rows = stride(from: 0, to: score.dimensions.count, by: 2).map { i in
                Array(score.dimensions[i..<min(i + 2, score.dimensions.count)])
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowDims in
                HStack(spacing: 8) {
                    ForEach(rowDims, id: \.name) { dim in
                        dimensionTile(dim)
                    }
                    if rowDims.count == 1 { Spacer().frame(maxWidth: .infinity) }
                }
            }
        }
    }

    private func dimensionTile(_ dim: NourishDimension) -> some View {
        let meta = Self.dimensionMeta[dim.name] ?? DimMeta(icon: "🌱", label: dim.name, strength: dim.name)
        let tier = Self.tier(for: dim.score)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(meta.icon)
                Text(meta.label)
                    .font(AppFont.bodySmall)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.wispOnSurface)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.wispOnSurface.opacity(0.08))
                    let fraction: CGFloat = dim.score == 0 ? 0 : max(0.12, CGFloat(dim.score) * 0.10)
                    if fraction > 0 {
                        Capsule()
                            .fill(tier.color.opacity(tier.alpha))
                            .frame(width: geo.size.width * fraction)
                    }
                }
            }
            .frame(height: 5)
            if let soft = Self.softLabel(dim.score) {
                Text(soft)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.7))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.wispOnSurface.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.wispOnSurface.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var upgrades: some View {
        if !score.improvements.isEmpty {
            sectionLabel("Simple upgrades")
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(score.improvements.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(NourishGreen.strong.opacity(0.22))
                            .frame(width: 2)
                        Text(tip)
                            .font(AppFont.bodyLarge)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.6))
    }

    private func affirmingLabel(overall: Int, label: String) -> String? {
        overall >= 5 ? label : nil
    }

    private func topStrengths(_ dimensions: [NourishDimension]) -> [String] {
        dimensions
            .filter { $0.score >= 5 }
            .sorted { $0.score > $1.score }
            .prefix(3)
            .compactMap { Self.dimensionMeta[$0.name]?.strength }
    }

    private struct DimMeta {
        var icon: String
        var label: String
        var strength: String
    }

    private struct Tier {
        var color: Color
        var alpha: Double
    }

    private static func tier(for score: Int) -> Tier {
        if score >= 7 { return Tier(color: NourishGreen.strong, alpha: 1) }
        if score >= 4 { return Tier(color: NourishGreen.moderate, alpha: 0.85) }
        return Tier(color: NourishGreen.light, alpha: 0.55)
    }

    private static func softLabel(_ score: Int) -> String? {
        switch score {
        case 0: "Not a focus here"
        case ...2: "Lightly present"
        default: nil
        }
    }

    private static let dimensionMeta: [String: DimMeta] = [
        "Real Food": DimMeta(icon: "🥬", label: "Real Food", strength: "Whole foods"),
        "Gut": DimMeta(icon: "🌱", label: "Gut Health", strength: "Gut-friendly"),
        "Protein": DimMeta(icon: "💪", label: "Protein", strength: "Protein-rich"),
        "Anti-Inflammatory": DimMeta(icon: "🧘", label: "Anti-inflammatory", strength: "Anti-inflammatory"),
        "Blood Sugar": DimMeta(icon: "⚖️", label: "Blood Sugar", strength: "Steady energy"),
        "Immune": DimMeta(icon: "🛡️", label: "Immune-supportive", strength: "Immune-supporting"),
        "Brain": DimMeta(icon: "🧠", label: "Brain Health", strength: "Brain-supporting"),
        "Heart": DimMeta(icon: "🫀", label: "Heart-healthy", strength: "Heart-healthy"),
    ]
}

private enum NourishGreen {
    static let strong = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
    static let moderate = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
    static let light = Color(red: 0x86 / 255, green: 0xEF / 255, blue: 0xAC / 255)
}

/// Compact wrap of pills without a custom Layout when the set is tiny (≤3).
private struct FlowWrap<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

/// Recipe-detail Nourish section mapping. Loading and quiet miss both render nothing.
nonisolated enum RecipeNourishUi: Equatable {
    case hidden
    case scored(NourishScore)
    case authError

    static func from(_ result: NourishFetchResult, enabled: Bool = true) -> RecipeNourishUi {
        guard enabled else { return .hidden }
        switch result {
        case .miss: return .hidden
        case .scored(let score): return .scored(score)
        case .authRequired: return .authError
        }
    }
}
