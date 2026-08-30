import SwiftUI

/// The Recipes tab. Cookbook-style poster grid, cache-seeded first paint,
/// pull-to-refresh, infinite scroll.
///
/// Empty vs loading are different screens: "No recipes yet" only after a
/// load has completed with nothing to show. A slow union shows the skeleton
/// (or the cache-seeded grid), never the empty copy.
struct RecipeFeedView: View {
    let keypair: Keypair
    @Binding var path: NavigationPath
    var onOpenDrawer: () -> Void
    var avatarURL: String?

    @Bindable var viewModel: RecipeFeedViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(
        keypair: Keypair,
        path: Binding<NavigationPath>,
        onOpenDrawer: @escaping () -> Void,
        avatarURL: String? = nil,
        viewModel: RecipeFeedViewModel? = nil
    ) {
        self.keypair = keypair
        self._path = path
        self.onOpenDrawer = onOpenDrawer
        self.avatarURL = avatarURL
        self.viewModel = viewModel ?? RecipeFeedViewModel()
    }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        content
            .background(Color.wispBackground)
            .wispTopHeader { header }
            .toolbar(.hidden, for: .navigationBar)
            .task { viewModel.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onOpenDrawer) {
                CachedAvatarView(url: avatarURL, size: 32, alwaysLoad: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open menu")

            Text("Recipes")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isAwaitingFirstPaint {
            loadingGrid
        } else if viewModel.isEmpty {
            emptyState
        } else {
            recipeGrid
        }
    }

    /// Skeleton tiles — "still fetching", never the empty copy.
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
        .accessibilityLabel("Fetching recipes")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("🍳")
                .font(.system(size: 40))
            Text("No recipes yet")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await viewModel.refresh() }
    }

    private var recipeGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(viewModel.events.enumerated()), id: \.element.id) { index, event in
                    RecipeCardView(event: event)
                        .onAppear {
                            viewModel.loadMoreIfNeeded(
                                currentIndex: index,
                                total: viewModel.events.count
                            )
                        }
                }
                if viewModel.isLoading {
                    RecipePosterSkeleton()
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .gridCellColumns(columns.count)
                        .frame(maxWidth: 150)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(16)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .refreshable { await viewModel.refresh() }
    }
}
