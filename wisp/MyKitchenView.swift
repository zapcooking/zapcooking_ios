import SwiftUI

/// The My Kitchen hub behind `BottomTab.kitchen` (Concern 3.2 / 3.5).
///
/// Android (`RecipeFeedScreen.kt` COOKBOOK segment) has five sub-tabs in
/// order Saved · Published · Grocery · Planner · Nourish. Grocery and
/// Planner are Phase 5; iOS ships Saved · Published · Nourish, preserving
/// Android's relative order. Nourish is an entry card into Explore
/// (Concern 3.5). The tab is hidden when `nourishEnabled` is off.
///
/// The selected section is plain `@State`: this view stays mounted at the
/// kitchen stack's root, so the selection survives pushing a recipe and
/// coming back (Android's `rememberSaveable` parity).
enum MyKitchenSection: String, CaseIterable, Identifiable {
    case saved
    case published
    case nourish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saved: "Saved"
        case .published: "Published"
        case .nourish: "Nourish"
        }
    }

    static func visibleCases(nourishEnabled: Bool = FeatureFlags.nourishEnabled) -> [MyKitchenSection] {
        allCases.filter { $0 != .nourish || nourishEnabled }
    }
}

struct MyKitchenView: View {
    let keypair: Keypair
    @Binding var path: NavigationPath
    var onOpenDrawer: () -> Void
    var avatarURL: String?

    @State private var section: MyKitchenSection = .saved

    var body: some View {
        content
            .background(Color.wispBackground)
            .wispTopHeader { header }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: RecipeCollectionRoute.self) { route in
                RecipeCollectionDetailView(route: route)
            }
            .navigationDestination(for: NourishExploreRoute.self) { _ in
                NourishExploreView()
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onOpenDrawer) {
                    CachedAvatarView(url: avatarURL, size: 32, alwaysLoad: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open menu")

                Text("My Kitchen")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurface)

                Spacer(minLength: 0)
            }
            sectionTabs
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MyKitchenSection.visibleCases()) { tab in
                    let selected = section == tab
                    Button {
                        section = tab
                    } label: {
                        Text(tab.title)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selected ? Color.wispPrimary : Color.wispSurfaceVariant.opacity(0.6),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Color.wispBackground : Color.wispOnSurface)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("kitchen-tab-\(tab.rawValue)")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .saved:
            SavedRecipesView(keypair: keypair, path: $path)
        case .published:
            PublishedRecipesView(keypair: keypair)
        case .nourish:
            NourishPlaceholderView(path: $path)
        }
    }
}
