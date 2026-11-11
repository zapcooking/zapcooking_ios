import SwiftUI

// The Fresh feed's own rows (`MainView.freshList`): the last-visit divider,
// the caught-up card and the recipe row. Free tier only: nothing here, or
// anywhere in Fresh, mentions membership, logging in or older posts
// (`FreshCopyTests` scans for it).

/// "N new since your last visit": a hairline either side of a small label,
/// placed before the first post the reader already saw.
struct FreshNewSinceDivider: View {
    let newCount: Int

    static func label(_ newCount: Int) -> String {
        newCount == 1 ? "1 new since your last visit" : "\(newCount) new since your last visit"
    }

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(Self.label(newCount))
                .font(AppFont.labelSmall)
                .foregroundStyle(Color.wispPrimary)
                .lineLimit(1)
                .fixedSize()
            line
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(newCount))
        .accessibilityIdentifier("fresh-new-since-divider")
    }

    private var line: some View {
        Rectangle()
            .fill(Color.wispPrimary.opacity(0.35))
            .frame(height: 1)
    }
}

/// The end of the window: what the reader has seen is everything new.
struct FreshCaughtUpCard: View {
    static let title = "You're all caught up"
    static let subtitle = "That's everything fresh for now."

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.wispPrimary)
            Text(Self.title)
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
            Text(Self.subtitle)
                .font(AppFont.bodyMedium)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .background(Color.wispSurfaceVariant.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fresh-caught-up")
    }
}

/// Recipe posters in a horizontal row, after the caught-up card. Each tile
/// is the app's `RecipeCardView` (poster, title, Report / Block menu).
struct FreshRecipeRow: View {
    let recipes: [NostrEvent]

    static let tileWidth: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recipes")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(recipes, id: \.id) { event in
                        RecipeCardView(event: event)
                            .frame(width: Self.tileWidth)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        .accessibilityIdentifier("fresh-recipe-row")
    }
}
