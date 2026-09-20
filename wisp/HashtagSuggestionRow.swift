import SwiftUI
import UIKit

/// The OnlyFood composer's tag pills: one row, no wrap, no scroll. As many
/// of `OnlyFoodCompose.suggestedTags` as fit at the current width (four at
/// 375pt), in the measured-usage order, then a trailing "+" pill that will
/// open the full food-tag set. The composer stays calm and the overflow
/// becomes a discovery affordance instead of clutter.
///
/// Treatment: an **outlined** chip reads as "available, tap me"; a
/// **filled** orange chip reads as "on". Orange is reserved for the
/// selected state, so the row no longer competes with the accent
/// elsewhere in the composer. At the cap the unselected chips dim.
///
/// The fit is computed, not laid out: the pills' widths come from the same
/// font metrics the chips render with (`HashtagPillMetrics`), so the count
/// is deterministic for a given width and text size, and testable without
/// a window. The row's width arrives through `onGeometryChange`; until it
/// does, `assumedWidth` (the narrowest supported device minus the gutters)
/// keeps the first frame right on a 375pt phone.
struct HashtagSuggestionRow: View {
    @Bindable var viewModel: ComposeViewModel
    /// Row width before geometry lands: 375pt device minus the 16pt gutters.
    var assumedWidth: CGFloat = 375 - 2 * 16

    @State private var measuredWidth: CGFloat? = nil
    @State private var showTagPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(OnlyFoodCompose.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                countLabel
            }
            HStack(spacing: HashtagPillMetrics.spacing) {
                ForEach(visibleTags, id: \.self) { tag in
                    pill(tag)
                }
                morePill
                Spacer(minLength: 0)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
            if viewModel.suggestedTagsOverCap {
                Text("OnlyFood hides notes with more than \(OnlyFoodCompose.maxTags) tags.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("tag-over-cap")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tag-suggestions")
    }

    /// The pills that fit, in order.
    var visibleTags: [String] {
        let tags = viewModel.suggestedHashtags
        let count = HashtagPillMetrics.visibleCount(tags: tags, available: measuredWidth ?? assumedWidth)
        return Array(tags.prefix(count))
    }

    private var countLabel: some View {
        let count = viewModel.suggestedTagCount
        return Text("\(count)/\(OnlyFoodCompose.maxTags) tags")
            .font(.caption.monospacedDigit())
            .foregroundStyle(viewModel.suggestedTagsOverCap ? Color.red : Color.secondary)
            .accessibilityIdentifier("tag-count")
    }

    private func pill(_ tag: String) -> some View {
        let selected = viewModel.isSuggestedHashtagSelected(tag)
        let blocked = !selected && viewModel.suggestedTagsAtCap
        return Button {
            viewModel.toggleSuggestedHashtag(tag)
        } label: {
            Text("#\(tag)")
                .font(HashtagPillMetrics.font)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, HashtagPillMetrics.horizontalPadding)
                .padding(.vertical, HashtagPillMetrics.verticalPadding)
                .background(selected ? Color.wispPrimary : Color.clear, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        selected ? Color.clear : HashtagPillMetrics.outline,
                        lineWidth: HashtagPillMetrics.strokeWidth
                    )
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
                .opacity(blocked ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .accessibilityLabel("#\(tag)")
        .accessibilityValue(selected ? "added" : (blocked ? "tag limit reached" : "not added"))
        .accessibilityIdentifier("tag-pill-\(tag)")
    }

    /// The trailing "+": outlined like an unselected chip, so it reads as
    /// one more thing to tap. The picker it opens is a follow-up; the tap
    /// is wired to `showTagPicker` and presents nothing yet.
    private var morePill: some View {
        Button {
            showTagPicker = true
        } label: {
            Image(systemName: "plus")
                .font(HashtagPillMetrics.font.weight(.semibold))
                .frame(width: HashtagPillMetrics.plusGlyphWidth)
                .padding(.horizontal, HashtagPillMetrics.horizontalPadding)
                .padding(.vertical, HashtagPillMetrics.verticalPadding)
                .overlay(
                    Capsule().strokeBorder(HashtagPillMetrics.outline, lineWidth: HashtagPillMetrics.strokeWidth)
                )
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More tags")
        .accessibilityIdentifier("tag-pill-more")
    }
}

/// The chip geometry, shared by the view and the fit computation so the
/// count of pills that fit is exact for the font the chips draw with.
nonisolated enum HashtagPillMetrics {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let spacing: CGFloat = 8
    static let strokeWidth: CGFloat = 1
    static let plusGlyphWidth: CGFloat = 12
    /// Outline for unselected chips and the "+": visible on both schemes,
    /// quieter than text.
    static let outline = Color.secondary.opacity(0.55)
    static var font: Font { .caption.weight(.medium) }

    /// `UIFont` equivalent of `font` at the current Dynamic Type size.
    static func uiFont() -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption1)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]
        ])
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    /// A chip's width for `label`: text plus padding, rounded up, plus a
    /// point of slack so rounding can never push the row past its width.
    static func pillWidth(label: String, font: UIFont = uiFont()) -> CGFloat {
        let text = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + 2 * horizontalPadding + 1
    }

    static func plusWidth() -> CGFloat {
        plusGlyphWidth + 2 * horizontalPadding
    }

    /// How many of `tags` fit in `available` points alongside the "+".
    static func visibleCount(tags: [String], available: CGFloat) -> Int {
        let font = uiFont()
        let widths = tags.map { pillWidth(label: "#\($0)", font: font) }
        return OnlyFoodCompose.visiblePillCount(
            widths: widths, plusWidth: plusWidth(), spacing: spacing, available: available
        )
    }
}
