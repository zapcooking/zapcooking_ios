import SwiftUI

/// Poster-style recipe tile: a 2:3 portrait image with the title below it.
/// Title-only — the engagement bar lives on the detail screen (Concern 1.3).
///
/// Missing or broken images fall back to a deterministic, offline placeholder
/// seeded by the event id, so a recipe always shows the same tile and the
/// grid never has holes. Port of Android `RecipeCard.kt`.
struct RecipeCardView: View {
    let event: NostrEvent

    private var dTag: String { RecipeParser.dTag(event) }

    private var title: String {
        event.tags.first(where: { $0.count >= 2 && $0[0] == "title" })?[1]
            ?? dTag
    }

    private var imageURL: URL? {
        guard let raw = event.tags.first(where: { $0.count >= 2 && $0[0] == "image" })?[1],
              !raw.isEmpty
        else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        NavigationLink(value: RecipeRoute(author: event.pubkey, dTag: dTag)) {
            VStack(alignment: .leading, spacing: 8) {
                poster
                Text(title)
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .contextMenu {
            if event.pubkey != NostrKey.load()?.pubkey {
                Button(role: .destructive) {
                    ReportPresenter.shared.present(.event(event))
                } label: {
                    Label("Report", systemImage: "flag")
                }
                .accessibilityIdentifier("report-recipe-card")
                Button(role: .destructive) {
                    MuteRepository.shared.blockUser(event.pubkey)
                } label: {
                    Label("Block User", systemImage: "person.crop.circle.badge.xmark")
                }
                .accessibilityIdentifier("block-recipe-card")
            }
        }
    }

    private var poster: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let imageURL {
                    RetryingAsyncImage(
                        url: imageURL,
                        content: { image in
                            image
                                .resizable()
                                .scaledToFill()
                        },
                        loading: { RecipePosterSkeleton() },
                        failure: { RecipePlaceholderTile(seed: event.id) }
                    )
                } else {
                    RecipePlaceholderTile(seed: event.id)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

/// Emoji + label chip for a curated browse category.
struct RecipeTagChip: View {
    let tag: RecipeTag

    var body: some View {
        Text("\(tag.emoji) \(tag.label)")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Color.wispSurfaceVariant.opacity(0.6),
                in: Capsule()
            )
            .foregroundStyle(Color.wispOnSurface)
            .accessibilityLabel(tag.label)
    }
}

/// Neutral pulsing 2:3 tile used while an image loads and for the grid's
/// initial loading state.
struct RecipePosterSkeleton: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.wispSurfaceVariant.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.wispSurfaceVariant.opacity(0.35))
                    .phaseAnimator([0.35, 0.75]) { content, phase in
                        content.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    }
            )
    }
}

/// Deterministic food-toned placeholder for recipes with no usable image.
/// The tint is picked from the event id, so it's stable per recipe and
/// needs no network — part of the Guideline 4.2 offline paint.
struct RecipePlaceholderTile: View {
    let seed: String

    private static let tints: [Color] = [
        Color(red: 0xE2 / 255, green: 0x55 / 255, blue: 0x2E / 255),
        Color(red: 0x6F / 255, green: 0xA0 / 255, blue: 0x3C / 255),
        Color(red: 0xE0 / 255, green: 0xA5 / 255, blue: 0x2B / 255),
        Color(red: 0x3E / 255, green: 0x8E / 255, blue: 0x9E / 255),
        Color(red: 0xB5 / 255, green: 0x57 / 255, blue: 0x2E / 255),
        Color(red: 0x8E / 255, green: 0x6D / 255, blue: 0xB0 / 255),
    ]

    var body: some View {
        let n = Self.tints.count
        let hashed = seed.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let tint = Self.tints[((hashed % n) + n) % n]
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.wispSurfaceVariant)
            .overlay(tint.opacity(0.18))
            .overlay {
                Image(systemName: "fork.knife")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(tint.opacity(0.55))
            }
    }
}
