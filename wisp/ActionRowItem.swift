import SwiftUI

/// One control in a post's action row (unified feed §6). Android
/// `ui/component/ActionBar.kt` puts a 22dp glyph in a 48dp tap target with
/// an unbounded 24dp ripple, uniformly across the row; here it is a 20pt
/// glyph in a tap target that is at least 44×44 (Apple's minimum) with a
/// single `.caption` count style. Visual spacing comes from the 44pt frame,
/// not from per-icon padding — that is what makes the row consistent rather
/// than merely bigger. Every control in the row goes through this type,
/// including the gesture-driven zap control, which uses the item as its
/// label and owns its own gestures.
///
/// The count label sits INSIDE the target rather than beside a fixed 44pt
/// glyph box: a bare control is exactly 44×44, a labelled one is only as
/// much wider as its label needs. Six controls plus four wide counts must
/// fit a 375pt device inside the card's 16pt gutters (343pt) — a 44pt box
/// per glyph with the label outside it does not (`BottomBarAndActionRowTests`
/// measures the worst case).
struct ActionRowItem: View {
    static let targetSize: CGFloat = 44
    static let glyphSize: CGFloat = 20

    enum Glyph {
        /// SF Symbol, sized with `.font` so each symbol keeps its natural weight.
        case symbol(String)
        /// Bitmap / asset image (the zap glyph swap), fitted to the glyph box.
        case image(Image)
        /// A short string glyph (a reacted unicode emoji).
        case text(String)
        /// Anything else (a custom-emoji image, the zap pulse), fitted to the box.
        case custom(AnyView)
    }

    let glyph: Glyph
    /// Preformatted count / label shown after the glyph, or nil for none.
    var label: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 2) {
            glyphView
            if let label, !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minWidth: Self.targetSize, minHeight: Self.targetSize)
        .foregroundStyle(tint ?? .secondary)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: Self.glyphSize))
        case .image(let image):
            image
                .resizable()
                .scaledToFit()
                .frame(width: Self.glyphSize, height: Self.glyphSize)
        case .text(let string):
            Text(string)
                .font(.system(size: Self.glyphSize))
        case .custom(let view):
            view
                .frame(width: Self.glyphSize, height: Self.glyphSize)
        }
    }
}

/// `ActionRowItem` as a plain button — the shape every tap-only control in
/// the row uses.
struct ActionRowButton: View {
    let item: ActionRowItem
    let action: () -> Void

    var body: some View {
        Button(action: action) { item }
            .buttonStyle(.plain)
    }
}
