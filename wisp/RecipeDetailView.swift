import SwiftUI

/// Recipe reader — branched from `ArticleView`. Hero, summary, prep / cook /
/// servings chips, chef's notes, scaled ingredients, numbered directions,
/// reused engagement bar.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.3):
/// - Data from `RecipeRepository` via `RecipeDetailViewModel`. No relay
///   queries from this view.
/// - Scale chips ½× / 1× / 2× / 3×; servings scale, prep / cook do not.
/// - Zap affordance respects `FeatureFlags.zapsOnPosts` (Gate 0-F).
/// - Cook mode is Concern 1.8b — launched from this screen, snapshotted
///   at the current scale. Android's equivalent button is unwired.
struct RecipeDetailView: View {
    let route: RecipeRoute
    let keypair: Keypair
    @Binding var path: NavigationPath

    @State private var viewModel = RecipeDetailViewModel()
    @State private var cookSession: CookModeSession?
    @State private var muteRepo = MuteRepository.shared
    @Environment(\.dismiss) private var dismiss

    private var activeUserIsWatchOnly: Bool {
        NostrKey.isWatchOnly(pubkey: keypair.pubkey)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: route) {
            await viewModel.load(author: route.author, dTag: route.dTag)
        }
        .onChange(of: viewModel.event?.id) { _, _ in
            if let event = viewModel.event {
                EngagementRepository.shared.markVisible(eventId: event.id, author: event.pubkey)
            }
        }
        .onDisappear { viewModel.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .contentHidden)) { _ in
            if let event = viewModel.event, ReportedContent.shared.isHidden(event) {
                dismiss()
            }
        }
        .fullScreenCover(item: $cookSession) { session in
            CookModeView(session: session)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            BackChevronButton { dismiss() }
            Text(viewModel.recipe?.title ?? "Recipe")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .lineLimit(1)
            Spacer(minLength: 0)
            if canStartCooking {
                Button(action: startCooking) {
                    Image(systemName: "cooktop.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.wispPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start cooking")
                .accessibilityIdentifier("start-cooking")
            }
            if let event = viewModel.event, event.pubkey != keypair.pubkey {
                Menu {
                    Button(role: .destructive) {
                        ReportPresenter.shared.present(.event(event))
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                    .accessibilityIdentifier("report-recipe")
                    let blocked = muteRepo.isBlocked(event.pubkey)
                    Button(role: blocked ? nil : .destructive) {
                        if blocked {
                            muteRepo.unblockUser(event.pubkey)
                        } else {
                            muteRepo.blockUser(event.pubkey)
                        }
                    } label: {
                        Label(
                            blocked ? "Unblock User" : "Block User",
                            systemImage: blocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark"
                        )
                    }
                    .accessibilityIdentifier("block-recipe")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.wispOnSurface)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Recipe actions")
                .accessibilityIdentifier("recipe-overflow")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.wispBackground)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.recipe == nil {
            VStack {
                Spacer()
                ProgressView().tint(Color.wispPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if viewModel.notFound && viewModel.recipe == nil {
            VStack {
                Spacer()
                Text("Recipe not found")
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let recipe = viewModel.recipe, let event = viewModel.event {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(recipe, event: event)
                    chips
                    scaleRow
                    if let notes = recipe.content.chefNotes, !notes.isEmpty {
                        sectionTitle("Chef's notes")
                        Text(notes)
                            .font(AppFont.bodyLarge)
                            .foregroundStyle(Color.wispOnSurface)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                    ingredientsSection
                    directionsSection
                    if canStartCooking {
                        startCookingButton
                    }
                    if let extra = recipe.content.additionalMarkdown, !extra.isEmpty {
                        sectionTitle("Additional resources")
                        Text(extra)
                            .font(AppFont.bodyLarge)
                            .foregroundStyle(Color.wispOnSurface)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                    if !activeUserIsWatchOnly {
                        Divider()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        ArticleActionBar(
                            article: event,
                            keypair: keypair,
                            replyCount: 0,
                            authorProfile: viewModel.authorProfile,
                            zapsOnPosts: FeatureFlags.zapsOnPosts
                        )
                        .padding(.horizontal, 8)
                    }
                    Spacer().frame(height: 32)
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ recipe: RecipeParser.Recipe, event: NostrEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cover = recipe.image, let coverUrl = URL(string: cover) {
                RetryingAsyncImage(
                    url: coverUrl,
                    content: { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    },
                    loading: {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.wispSurfaceVariant.opacity(0.4))
                            .frame(height: 180)
                            .overlay(ProgressView().controlSize(.small))
                    },
                    failure: { EmptyView() }
                )
                .padding(.top, 8)
                Spacer().frame(height: 16)
            }

            Text(recipe.title ?? "Untitled")
                .font(AppFont.titleLarge)
                .foregroundStyle(Color.wispOnSurface)

            if let summary = recipe.summary, !summary.isEmpty {
                Spacer().frame(height: 8)
                Text(summary)
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }

            Spacer().frame(height: 12)

            Button {
                path.append(ProfileRoute(pubkey: event.pubkey))
            } label: {
                HStack(spacing: 8) {
                    CachedAvatarView(url: viewModel.authorProfile?.picture, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            viewModel.authorProfile?.displayString
                                ?? Nip19.shortNpub(hex: event.pubkey)
                        )
                        .font(AppFont.titleMedium)
                        .foregroundStyle(Color.wispOnSurface)
                        Text(ArticleView.formatArticleDate(Int(recipe.publishedAt)))
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                    }
                }
            }
            .buttonStyle(.plain)

            if !recipe.categories.isEmpty {
                Spacer().frame(height: 12)
                FlowLayout(spacing: 6) {
                    ForEach(recipe.categories, id: \.self) { category in
                        Button {
                            path.append(RecipeTagFeedRoute(tag: category))
                        } label: {
                            Text(category)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Color.wispSurfaceVariant.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                                .foregroundStyle(Color.wispPrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Browse \(category) recipes")
                    }
                }
            }

            Spacer().frame(height: 16)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var chips: some View {
        let items: [(String, String)] = [
            viewModel.prepTime.map { ("Prep", $0) },
            viewModel.cookTime.map { ("Cook", $0) },
            viewModel.scaledServings.map { ("Servings", $0) },
        ].compactMap { $0 }

        if !items.isEmpty {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { label, value in
                    VStack(spacing: 2) {
                        Text(label)
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                        Text(value)
                            .font(AppFont.titleMedium)
                            .foregroundStyle(Color.wispOnSurface)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        Color.wispSurfaceVariant.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var scaleRow: some View {
        HStack(spacing: 8) {
            ForEach(RecipeDetailViewModel.scaleOptions, id: \.self) { option in
                let selected = abs(viewModel.scale - option) < 0.001
                Button {
                    viewModel.setScale(option)
                } label: {
                    Text(Self.scaleLabel(option))
                        .font(AppFont.titleMedium)
                        .foregroundStyle(selected ? Color.wispBackground : Color.wispOnSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selected ? Color.wispPrimary : Color.wispSurfaceVariant.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Ingredients")
            ForEach(Array(viewModel.scaledIngredients.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundStyle(Color.wispPrimary)
                    Text(line)
                        .font(AppFont.bodyLarge)
                        .foregroundStyle(Color.wispOnSurface)
                }
                .padding(.horizontal, 16)
            }
            Spacer().frame(height: 8)
        }
    }

    private var directionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Directions")
            ForEach(Array((viewModel.recipe?.content.directions ?? []).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(AppFont.titleMedium)
                        .foregroundStyle(Color.wispBackground)
                        .frame(width: 24, height: 24)
                        .background(Color.wispPrimary, in: Circle())
                    Text(step)
                        .font(AppFont.bodyLarge)
                        .foregroundStyle(Color.wispOnSurface)
                }
                .padding(.horizontal, 16)
            }
            Spacer().frame(height: 8)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.titleMedium)
            .foregroundStyle(Color.wispOnSurface)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private var canStartCooking: Bool {
        guard let recipe = viewModel.recipe else { return false }
        return !recipe.content.directions.isEmpty
    }

    private var startCookingButton: some View {
        Button(action: startCooking) {
            Label("Start cooking", systemImage: "cooktop.fill")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispBackground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.wispPrimary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .accessibilityIdentifier("start-cooking-button")
    }

    private func startCooking() {
        guard let recipe = viewModel.recipe, !recipe.content.directions.isEmpty else { return }
        cookSession = CookModeSession.snapshot(recipe: recipe, scale: viewModel.scale)
    }

    static func scaleLabel(_ value: Double) -> String {
        switch value {
        case 0.5: return "½×"
        case 1.0: return "1×"
        case 2.0: return "2×"
        case 3.0: return "3×"
        default: return "\(IngredientScaler.formatQuantity(value))×"
        }
    }
}

extension View {
    /// Registers `RecipeRoute` → `RecipeDetailView` on a tab's stack.
    /// Concern 1.5 / 1.6 push this route; 1.3 only registers the destination.
    func recipeNavigation(keypair: Keypair, path: Binding<NavigationPath>) -> some View {
        navigationDestination(for: RecipeRoute.self) { route in
            RecipeDetailView(route: route, keypair: keypair, path: path)
        }
        .navigationDestination(for: RecipeTagFeedRoute.self) { route in
            RecipeTagFeedView(tag: route.tag, keypair: keypair, path: path)
        }
    }
}
