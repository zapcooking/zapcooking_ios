import SwiftUI

/// Cover picker for one collection (Concern 3.2) — Android's
/// `ChooseCoverSheet` (`CookbookManageDialogs.kt`): a sheet listing the
/// collection's member recipes, current cover checkmarked. Picking a member
/// hands its **a-coordinate** back (the `cover` tag stores the coordinate,
/// not an image URL); the repository re-guards membership before signing.
/// Unresolved members still appear, labelled by their d-tag (Android
/// parity), so a cache miss cannot hide a valid choice.
struct ChooseCoverSheet: View {
    let list: RecipeBookmarkRepository.CookbookList
    /// Called with the chosen member coordinate.
    let onPick: (String) -> Void

    @State private var bookmarks = RecipeBookmarkRepository.shared
    @State private var recipes = RecipeRepository.shared
    @State private var resolved: [String: NostrEvent] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .background(Color.wispBackground)
                .navigationTitle("Choose cover")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task { await resolveMembers() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        if list.coordinates.isEmpty {
            VStack {
                Spacer()
                // Android `cookbook_cover_empty`, verbatim.
                Text("Add recipes to this collection to choose a cover.")
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(list.coordinates, id: \.self) { coord in
                    Button {
                        onPick(coord)
                    } label: {
                        HStack(spacing: 12) {
                            memberThumbnail(coord)
                            Text(memberTitle(coord))
                                .font(AppFont.bodyLarge)
                                .foregroundStyle(Color.wispOnSurface)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if coord == list.coverCoord {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.wispPrimary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
    }

    private func memberTitle(_ coord: String) -> String {
        if let event = resolved[coord],
           let title = event.tags.first(where: { $0.count >= 2 && $0[0] == "title" })?[1],
           !title.isEmpty {
            return title
        }
        return RecipeBookmarkRepository.parseCoordinate(coord)?.dTag ?? coord
    }

    @ViewBuilder
    private func memberThumbnail(_ coord: String) -> some View {
        let imageURL = resolved[coord]?.tags
            .first(where: { $0.count >= 2 && $0[0] == "image" })?[1]
        Color.clear
            .frame(width: 44, height: 44)
            .overlay {
                if let imageURL, let url = URL(string: imageURL) {
                    RetryingAsyncImage(
                        url: url,
                        content: { image in
                            image
                                .resizable()
                                .scaledToFill()
                        },
                        loading: { RecipePosterSkeleton() },
                        failure: { RecipePlaceholderTile(seed: coord) }
                    )
                } else {
                    RecipePlaceholderTile(seed: coord)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private func resolveMembers() async {
        let events = await bookmarks.resolvedRecipes(coordinates: list.coordinates, using: recipes)
        guard !Task.isCancelled else { return }
        resolved = Dictionary(
            events.compactMap { event in
                RecipeBookmarkRepository.coordinateForEvent(event).map { ($0, event) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
