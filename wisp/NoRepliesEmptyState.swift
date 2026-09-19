import SwiftUI

/// The thread's "No replies yet" dead end.
///
/// Cheffy in the **neutral** expression — a dead end is nowhere to grin.
/// Replaces the dashed Wisp-flame outline (`NoReplies` imageset, added in
/// eff92c6 and deleted with this view) that C-J's `WispLogo` sweep could not
/// see. Cheffy is drawn on a `Canvas`, so no asset is involved, and it has
/// no white structural element to lose on a light ground the way `ZcLogo`'s
/// ring and handle did: its only white is the eye highlight, which sits on
/// ink. `EmptyStateGroundTests` measures face, hat and ink against every
/// theme's light and dark background from rendered pixels.
struct NoRepliesEmptyState: View {
    static let iconSize: CGFloat = 64
    static let expression: Cheffy.Expression = .neutral

    var body: some View {
        VStack(spacing: 8) {
            CheffyIcon(size: Self.iconSize, expression: Self.expression)
            Text("No replies yet")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread-no-replies")
    }
}
