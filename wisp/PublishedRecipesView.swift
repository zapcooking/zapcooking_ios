import SwiftUI

/// My Kitchen › Published — the signed-in author's recipes through
/// `RecipeRepository`'s authored session (Concern 3.2, contract 2).
///
/// The author filter is a repository query (`loadAuthoredFeed`), never a
/// view-side `.filter`, so Published inherits the same dedup, NIP-01
/// tiebreaker, and HiddenRecipes reduction as the feed. Relayed events
/// only — Android shows no drafts either (`RecipeComposeViewModel.kt`: v1
/// has no draft autosave; confirmed absence, not a gap).
///
/// Android parity: 12 skeleton tiles while loading; empty state is the
/// single centered line "No published recipes yet" (`strings.xml:765`).
struct PublishedRecipesView: View {
    let keypair: Keypair

    @State private var repository = RecipeRepository.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var isAwaitingFirstPaint: Bool {
        repository.authoredRecipes.isEmpty && !repository.hasAuthoredLoaded
    }

    private var isEmpty: Bool {
        repository.authoredRecipes.isEmpty && repository.hasAuthoredLoaded
    }

    var body: some View {
        content
            .task { repository.loadAuthoredFeed(author: keypair.pubkey) }
    }

    @ViewBuilder
    private var content: some View {
        if isAwaitingFirstPaint {
            loadingGrid
        } else if isEmpty {
            emptyState
        } else {
            recipeGrid
        }
    }

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<12, id: \.self) { _ in
                    RecipePosterSkeleton()
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                }
            }
            .padding(16)
        }
        .disabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fetching your recipes")
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No published recipes yet")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await refresh() }
    }

    private var recipeGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(repository.authoredRecipes, id: \.id) { event in
                    RecipeCardView(event: event)
                }
            }
            .padding(16)
        }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        repository.refreshAuthoredFeed()
        await repository.authoredInFlight?.value
    }
}
