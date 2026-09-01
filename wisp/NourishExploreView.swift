import SwiftUI

private let nourishGreen = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)

struct NourishExploreRoute: Hashable {}

/// Nourish Explore — port of Android `NourishExploreScreen.kt`.
struct NourishExploreView: View {
    @State private var viewModel: NourishExploreViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(viewModel: NourishExploreViewModel? = nil) {
        _viewModel = State(initialValue: viewModel ?? NourishExploreViewModel())
    }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var sortOptions: [(NourishDiscovery.SortDimension, String)] {
        [
            (.overall, "Overall"),
            (.realFood, "Real Food"),
            (.gut, "Gut"),
            (.protein, "Protein"),
        ]
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                BackChevronButton { dismiss() }
                Text("Nourish Explore")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurface)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text("AI-generated estimates — guidance, not gospel")
                .font(AppFont.bodySmall)
                .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.55))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(NourishDiscovery.filterChips) { chip in
                        nourishChip(
                            label: chip.label,
                            selected: viewModel.ui.activeChipIds.contains(chip.id)
                        ) {
                            viewModel.toggleChip(chip.id)
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sortOptions, id: \.0) { dim, label in
                        nourishChip(
                            label: label,
                            selected: viewModel.ui.sortBy == dim,
                            enabled: !viewModel.ui.loading
                        ) {
                            viewModel.setSort(dim)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.ui.loading {
            loadingState
        } else if viewModel.ui.error {
            errorState
        } else if viewModel.ui.recipes.isEmpty {
            emptyState
        } else {
            recipeGrid
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().tint(nourishGreen)
            Text("Finding analyzed recipes…")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("nourish-explore-loading")
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Something went wrong. Please try again.")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
            Button("Retry") { viewModel.retry() }
                .font(AppFont.titleMedium)
                .foregroundStyle(nourishGreen)
                .accessibilityIdentifier("nourish-explore-retry")
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("nourish-explore-error")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No analyzed recipes yet.")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            Text("Once recipes are analyzed with Nourish, they'll appear here ranked by their nutrition profile.")
                .font(AppFont.bodySmall)
                .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("nourish-explore-empty")
    }

    private var recipeGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                if viewModel.ui.degraded {
                    Text("More recipes being analyzed — showing the full ranked list for now.")
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .gridCellColumns(columns.count)
                }
                if viewModel.ui.refreshing {
                    Text("Updating…")
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.5))
                        .gridCellColumns(columns.count)
                }
                ForEach(viewModel.ui.recipes) { item in
                    NourishExploreRecipeCard(item: item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)

            footer
                .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        let count = viewModel.ui.recipes.count
        let text: String
        if !viewModel.ui.activeChipIds.isEmpty && !viewModel.ui.degraded {
            text = "\(count) recipes matching your filters"
        } else {
            text = "\(count) recipes with Nourish profiles"
        }
        return Text(text)
            .font(AppFont.bodySmall)
            .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.4))
            .frame(maxWidth: .infinity)
    }

    private func nourishChip(
        label: String,
        selected: Bool,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    selected ? nourishGreen.opacity(0.14) : Color.wispSurfaceVariant.opacity(0.6),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        selected ? nourishGreen.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
                )
                .foregroundStyle(selected ? nourishGreen : Color.wispOnSurface)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Explore tile: recipe poster + leaf mark + optional macros snippet.
struct NourishExploreRecipeCard: View {
    let item: NourishDiscovery.RankedRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RecipeCardView(event: item.event)
            if let macros = NourishParser.macrosRowView(item.score.macros) {
                Text("\(macros.kcal) kcal · \(macros.proteinG)g protein")
                    .font(AppFont.bodySmall)
                    .foregroundStyle(
                        macros.tone == "rough"
                            ? Color.wispOnSurfaceVariant.opacity(0.7)
                            : Color.wispOnSurfaceVariant
                    )
                Text(macros.label)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.55))
            }
        }
    }
}
