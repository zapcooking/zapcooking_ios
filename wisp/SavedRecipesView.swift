import SwiftUI

/// Navigation route for one saved collection — pushed from the Saved grid,
/// resolved in `MyKitchenView`'s stack. Carries the `d`-tag only; the view
/// re-reads the live list from `RecipeBookmarkRepository` so a rename or
/// membership change while pushed stays current.
struct RecipeCollectionRoute: Hashable {
    let dTag: String
}

/// My Kitchen › Saved (Concern 3.2). The user's kind-30001 recipe lists —
/// the default Saved list first, then named collections — as a card grid
/// with Android's management overflow (`CookbookCollectionCard.kt`):
/// Rename · Edit description · Choose cover · Delete, with Rename and
/// Delete hidden for the default list, and the whole menu hidden for
/// watch-only accounts (Android's `canManage = LocalCanSign`).
///
/// Management lives **only** on these grid cards — the collection detail
/// route has no manage affordances (Android parity, confirmed absence).
///
/// The 3.1b save picker is `RecipeListChooserSheet` (Android checklist),
/// not this grid. Injected tap/menu handlers stay so the card remains a
/// Saved-tab tile only.
struct SavedRecipesView: View {
    let keypair: Keypair
    @Binding var path: NavigationPath

    @State private var bookmarks = RecipeBookmarkRepository.shared
    @State private var recipes = RecipeRepository.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Resolved cover image URLs, keyed by list d-tag. The `cover` tag is a
    /// member recipe's a-coordinate; the URL comes from that recipe's own
    /// `image` tag, falling back to the first member.
    @State private var coverURLs: [String: String] = [:]

    @State private var renameTarget: RecipeBookmarkRepository.CookbookList?
    @State private var renameText = ""
    @State private var descriptionTarget: RecipeBookmarkRepository.CookbookList?
    @State private var descriptionText = ""
    @State private var coverTarget: CoverSheetTarget?
    @State private var deleteTarget: RecipeBookmarkRepository.CookbookList?
    @State private var manageError: String?
    @State private var isWorking = false

    private var canManage: Bool { !NostrKey.isWatchOnly(pubkey: keypair.pubkey) }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        content
            .task {
                bookmarks.paintFromCache(pubkey: keypair.pubkey)
                if !bookmarks.hasLoaded, !bookmarks.isLoading {
                    await bookmarks.load(pubkey: keypair.pubkey)
                }
            }
            .task(id: coverResolutionKey) { await resolveCovers() }
            .alert(
                "Rename",
                isPresented: presentedBinding($renameTarget),
                presenting: renameTarget
            ) { list in
                TextField("Collection name", text: $renameText)
                Button("Save") {
                    let title = renameText
                    Task { await run { await bookmarks.renameList(dTag: list.dTag, newTitle: title, keypair: keypair) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Edit description",
                isPresented: presentedBinding($descriptionTarget),
                presenting: descriptionTarget
            ) { list in
                TextField("Description", text: $descriptionText)
                Button("Save") {
                    let summary = descriptionText
                    Task { await run { await bookmarks.setListDescription(dTag: list.dTag, summary: summary, keypair: keypair) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Delete collection?",
                isPresented: presentedBinding($deleteTarget),
                presenting: deleteTarget
            ) { list in
                Button("Delete", role: .destructive) {
                    Task { await run { await bookmarks.deleteList(dTag: list.dTag, keypair: keypair) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { list in
                Text("Delete \"\(list.title)\"? This removes the collection but won't delete the recipes themselves.")
            }
            .alert(
                "Couldn't update collection",
                isPresented: Binding(
                    get: { manageError != nil },
                    set: { if !$0 { manageError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(manageError ?? "")
            }
            .sheet(item: $coverTarget) { target in
                ChooseCoverSheet(
                    list: target.list,
                    onPick: { coord in
                        coverTarget = nil
                        Task { await run { await bookmarks.setListCover(dTag: target.list.dTag, coverCoord: coord, keypair: keypair) } }
                    }
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if bookmarks.lists.isEmpty, !bookmarks.hasLoaded {
            VStack {
                Spacer()
                ProgressView().tint(Color.wispPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if bookmarks.lists.isEmpty {
            emptyState
        } else {
            collectionGrid
        }
    }

    /// Android `cookbook_saved_empty_*` copy, verbatim.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("📖")
                .font(.system(size: 40))
            Text("Start saving recipes")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
            Text("Save recipes you love and organize them into collections.")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await bookmarks.load(pubkey: keypair.pubkey) }
    }

    private var collectionGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(bookmarks.lists, id: \.dTag) { list in
                    CookbookCollectionCard(
                        list: list,
                        coverURL: coverURLs[list.dTag],
                        onTap: { path.append(RecipeCollectionRoute(dTag: list.dTag)) },
                        menu: canManage ? manageMenu(for: list) : nil
                    )
                }
            }
            .padding(16)
        }
        .refreshable { await bookmarks.load(pubkey: keypair.pubkey) }
        .disabled(isWorking)
    }

    /// Android menu order: Rename · Edit description · Choose cover ·
    /// Delete; Rename and Delete hidden for the default Saved list.
    private func manageMenu(for list: RecipeBookmarkRepository.CookbookList) -> CollectionManageMenu {
        CollectionManageMenu(
            onRename: list.isDefault ? nil : {
                renameText = list.title
                renameTarget = list
            },
            onEditDescription: {
                descriptionText = list.summary ?? ""
                descriptionTarget = list
            },
            onChooseCover: { coverTarget = CoverSheetTarget(list: list) },
            onDelete: list.isDefault ? nil : { deleteTarget = list }
        )
    }

    private func run(_ operation: () async -> Bool) async {
        isWorking = true
        defer { isWorking = false }
        if await !operation() {
            manageError = bookmarks.lastWriteError ?? "Couldn't update this collection. Try again in a moment."
        }
    }

    /// Re-resolve covers when list membership or cover choices change.
    private var coverResolutionKey: String {
        bookmarks.lists
            .map { "\($0.dTag)|\($0.coverCoord ?? "")|\($0.coordinates.first ?? "")" }
            .joined(separator: ",")
    }

    private func resolveCovers() async {
        for list in bookmarks.lists {
            guard let coord = list.coverCoord ?? list.coordinates.first,
                  let parsed = RecipeBookmarkRepository.parseCoordinate(coord)
            else { continue }
            var event = recipes.cached(author: parsed.pubkey, dTag: parsed.dTag)
            if event == nil {
                event = await recipes.requestRecipe(author: parsed.pubkey, dTag: parsed.dTag)
            }
            guard !Task.isCancelled else { return }
            if let url = event?.tags.first(where: { $0.count >= 2 && $0[0] == "image" })?[1],
               !url.isEmpty {
                coverURLs[list.dTag] = url
            }
        }
    }

    private func presentedBinding<T>(_ target: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { target.wrappedValue != nil },
            set: { if !$0 { target.wrappedValue = nil } }
        )
    }
}

/// Identifiable wrapper so the cover picker can drive `sheet(item:)`.
struct CoverSheetTarget: Identifiable {
    let list: RecipeBookmarkRepository.CookbookList
    var id: String { list.dTag }
}

/// The manage-overflow actions a card offers. Nil handlers hide their menu
/// entry (Rename / Delete for the default Saved list).
struct CollectionManageMenu {
    var onRename: (() -> Void)?
    var onEditDescription: () -> Void
    var onChooseCover: () -> Void
    var onDelete: (() -> Void)?
}

/// One collection tile: square cover (resolved from the cover recipe's own
/// image, deterministic placeholder otherwise), title, recipe count, and
/// the manage overflow. Injected tap/menu handlers keep management on the
/// card without baking Saved-tab navigation into the tile.
struct CookbookCollectionCard: View {
    let list: RecipeBookmarkRepository.CookbookList
    let coverURL: String?
    let onTap: () -> Void
    let menu: CollectionManageMenu?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                cover
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.title)
                            .font(AppFont.titleMedium)
                            .foregroundStyle(Color.wispOnSurface)
                            .lineLimit(1)
                        Text(countLabel)
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                    if let menu {
                        Menu {
                            if let onRename = menu.onRename {
                                Button("Rename", action: onRename)
                            }
                            Button("Edit description", action: menu.onEditDescription)
                            Button("Choose cover", action: menu.onChooseCover)
                            if let onDelete = menu.onDelete {
                                Button("Delete", role: .destructive, action: onDelete)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.wispOnSurfaceVariant)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Manage collection")
                        .accessibilityIdentifier("manage-collection-\(list.dTag)")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(list.title)
    }

    private var countLabel: String {
        let count = list.coordinates.count
        return count == 1 ? "1 recipe" : "\(count) recipes"
    }

    private var cover: some View {
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let coverURL, let url = URL(string: coverURL) {
                    RetryingAsyncImage(
                        url: url,
                        content: { image in
                            image
                                .resizable()
                                .scaledToFill()
                        },
                        loading: { RecipePosterSkeleton() },
                        failure: { RecipePlaceholderTile(seed: list.dTag) }
                    )
                } else {
                    RecipePlaceholderTile(seed: list.dTag)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

/// Read-only member grid for one collection. No manage affordances here —
/// management lives on the Saved grid cards (Android parity).
struct RecipeCollectionDetailView: View {
    let route: RecipeCollectionRoute

    @State private var bookmarks = RecipeBookmarkRepository.shared
    @State private var recipes = RecipeRepository.shared
    @State private var members: [NostrEvent] = []
    @State private var isResolving = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    private var list: RecipeBookmarkRepository.CookbookList? {
        bookmarks.lists.first { $0.dTag == route.dTag }
    }

    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: list?.coordinates ?? []) { await resolveMembers() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            BackChevronButton { dismiss() }
            Text(list?.title ?? "Collection")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.wispBackground)
    }

    @ViewBuilder
    private var content: some View {
        if members.isEmpty, isResolving {
            VStack {
                Spacer()
                ProgressView().tint(Color.wispPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if members.isEmpty {
            VStack {
                Spacer()
                Text("No recipes in this collection yet.")
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(members, id: \.id) { event in
                        RecipeCardView(event: event)
                    }
                }
                .padding(16)
            }
        }
    }

    private func resolveMembers() async {
        guard let list else {
            members = []
            return
        }
        isResolving = true
        defer { isResolving = false }
        members = await bookmarks.resolvedRecipes(coordinates: list.coordinates, using: recipes)
    }
}
