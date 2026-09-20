import SwiftUI
import UIKit

/// The OnlyFood composer's tag pills: one row, no wrap, no scroll. Selected
/// food tags come first (so a tag from the picker or the keyboard is never
/// hidden), then as many of `OnlyFoodCompose.suggestedTags` as fit at the
/// current width (three at 375pt), then a trailing "+" pill that opens the
/// full food-tag set (`FoodTagPickerView`). When more tags are selected
/// than fit, the "+" reads "+N": N selected tags are past the cut.
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
    /// The "+" pill's action: the composer presents `FoodTagPickerView`.
    var onMore: () -> Void = {}

    @State private var measuredWidth: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(OnlyFoodCompose.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                countLabel
            }
            // No trailing Spacer: it would add one more `spacing` gap the
            // fit computation does not count. The frame leads the row.
            HStack(spacing: HashtagPillMetrics.spacing) {
                ForEach(layout.visible, id: \.self) { tag in
                    pill(tag)
                }
                morePill
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.2), value: layout.visible)
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

    /// The pills that fit, in order, and how many selected tags are hidden.
    var layout: (visible: [String], hiddenSelected: Int) {
        HashtagPillMetrics.layout(
            order: OnlyFoodCompose.rowOrder(bodyTags: viewModel.hashtags, suggested: viewModel.suggestedHashtags),
            isSelected: { viewModel.isSuggestedHashtagSelected($0) },
            available: measuredWidth ?? assumedWidth
        )
    }

    /// The pills that fit, in order.
    var visibleTags: [String] { layout.visible }

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
        return HashtagChip(tag: tag, selected: selected, blocked: blocked) {
            viewModel.toggleSuggestedHashtag(tag)
        }
        .accessibilityIdentifier("tag-pill-\(tag)")
    }

    /// The trailing "+": outlined like an unselected chip, so it reads as
    /// one more thing to tap. "+N" when N selected tags are past the cut.
    private var morePill: some View {
        let hidden = layout.hiddenSelected
        return Button(action: onMore) {
            Group {
                if hidden > 0 {
                    Text("+\(hidden)")
                        .font(HashtagPillMetrics.font)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Image(systemName: "plus")
                        .font(HashtagPillMetrics.font.weight(.semibold))
                        .frame(width: HashtagPillMetrics.plusGlyphWidth)
                }
            }
            .padding(.horizontal, HashtagPillMetrics.horizontalPadding)
            .padding(.vertical, HashtagPillMetrics.verticalPadding)
            .overlay(
                Capsule().strokeBorder(HashtagPillMetrics.outline, lineWidth: HashtagPillMetrics.strokeWidth)
            )
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hidden > 0 ? "More tags, \(hidden) selected not shown" : "More tags")
        .accessibilityIdentifier("tag-pill-more")
    }
}

/// One tag chip, shared by the row and the picker: outlined when
/// available, filled with the brand orange when selected, dimmed and
/// inert when the note is at the cap.
struct HashtagChip: View {
    let tag: String
    let selected: Bool
    let blocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
    /// quieter than text. Deliberately not the palette `outline`
    /// (`Color.borderSubtle`): that is a hairline tier (0x343338 on the
    /// custom dark preset) and reads as nothing on a chip, which would
    /// undo the "tap me" affordance the stroke exists for.
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

    /// The "+" pill's width: the glyph, or "+N" measured like a chip.
    static func plusWidth(hidden: Int = 0, font: UIFont = uiFont()) -> CGFloat {
        guard hidden > 0 else { return plusGlyphWidth + 2 * horizontalPadding }
        return pillWidth(label: "+\(hidden)", font: font)
    }

    /// How many of `tags` fit in `available` points alongside the "+".
    static func visibleCount(tags: [String], available: CGFloat) -> Int {
        let font = uiFont()
        let widths = tags.map { pillWidth(label: "#\($0)", font: font) }
        return OnlyFoodCompose.visiblePillCount(
            widths: widths, plusWidth: plusWidth(), spacing: spacing, available: available
        )
    }

    /// The row: the leading entries of `order` that fit, and how many
    /// selected entries are past the cut (the "+N").
    static func layout(
        order: [String], isSelected: (String) -> Bool, available: CGFloat
    ) -> (visible: [String], hiddenSelected: Int) {
        let font = uiFont()
        let widths = order.map { pillWidth(label: "#\($0)", font: font) }
        let result = OnlyFoodCompose.rowLayout(
            widths: widths, selected: order.map(isSelected),
            plusWidth: { plusWidth(hidden: $0, font: font) },
            spacing: spacing, available: available
        )
        return (Array(order.prefix(result.count)), result.hiddenSelected)
    }
}
