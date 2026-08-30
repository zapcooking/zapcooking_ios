import SwiftUI

/// Recipes in one curated category. Same poster grid as the Recipes tab;
/// the repository owns the query.
struct RecipeTagFeedView: View {
    let keypair: Keypair
    @Binding var path: NavigationPath
    @State private var viewModel: RecipeTagFeedViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(
        tag: String,
        keypair: Keypair,
        path: Binding<NavigationPath>,
        viewModel: RecipeTagFeedViewModel? = nil
    ) {
        self.keypair = keypair
        self._path = path
        _viewModel = State(initialValue: viewModel ?? RecipeTagFeedViewModel(tag: tag))
    }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackFromLeftEdge()
        .task { viewModel.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                BackChevronButton { dismiss() }
                Text("\(viewModel.tagInfo.emoji) \(viewModel.tagInfo.label)")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurface)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if !viewModel.tag.isEmpty {
                Text("#\(viewModel.tag)")
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 12)
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
        .accessibilityLabel("Fetching \(viewModel.tagInfo.label) recipes")
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
