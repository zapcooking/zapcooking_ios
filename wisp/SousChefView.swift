import SwiftUI

/// Sous Chef import screen (Concern 2.5, port of Android `SousChefScreen`,
/// URL mode only). Paste a recipe URL → free anonymous extraction → the
/// result renders in-place as a read-only preview (no byline/engagement —
/// an imported recipe has no event yet) with **Publish**, **Save to my
/// recipes**, **Edit**, and **Discard**.
///
/// Android's screen also carries the member-gated image/text modes and
/// their upsell banner; both are P2 on iOS, so this screen has no
/// membership machinery at all and its header/placeholder copy is the
/// URL-only cut of Android's. Presented as a full-screen cover from the
/// Recipes tab (entry hidden when `FeatureFlags.sousChefImportEnabled`
/// is off — `SousChefGate.entryVisible`).
struct SousChefView: View {
    /// Web `#a855f7` — the Sous Chef purple accent, mirroring Android's
    /// `SousChefPurple` / the web page header's sparkle.
    static let sousChefPurple = Color(red: 0xA8 / 255, green: 0x55 / 255, blue: 0xF7 / 255)

    let keypair: Keypair
    /// Called after a successful publish (either path, including Edit →
    /// compose). The host dismisses this cover and routes to the recipe.
    let onPublished: (_ author: String, _ dTag: String, _ savedToCookbook: Bool) -> Void
    let onDismiss: () -> Void

    @State private var viewModel = SousChefViewModel()
    @State private var input = ""
    @State private var confirmAction: ConfirmAction?
    @State private var composeSession: RecipeComposeSession?

    private enum ConfirmAction: Identifiable {
        case publish
        case saveToCookbook
        var id: Int { self == .publish ? 0 : 1 }
    }

    private var canSign: Bool { !keypair.isWatchOnly }
    private var isLoading: Bool { viewModel.state == .loading }
    private var urlDetected: Bool { SousChefGate.isImportUrl(input) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inputSection
                Divider()
                stateSection
            }
            .background(Color.wispBackground)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Self.sousChefPurple)
                        Text("Sous Chef")
                            .font(AppFont.titleMedium)
                            .foregroundStyle(Color.wispOnSurface)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .accessibilityIdentifier("sous-chef-close")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: viewModel.publishState) { _, state in
            if case .published(let author, let dTag, let saved) = state {
                onPublished(author, dTag, saved)
            }
        }
        .fullScreenCover(item: $composeSession) { session in
            // Edit hand-off — same stacked presentation Android gets from
            // navigating compose on top of Sous Chef: dismissing compose
            // returns to the preview; publishing routes to the recipe.
            RecipeComposeView(
                keypair: keypair,
                session: session,
                onPublished: { author, dTag in
                    composeSession = nil
                    onPublished(author, dTag, false)
                },
                onDismiss: { composeSession = nil }
            )
        }
        .alert(
            confirmAction == .saveToCookbook ? "Save to My Kitchen?" : "Publish recipe?",
            isPresented: Binding(
                get: { confirmAction != nil },
                set: { if !$0 { confirmAction = nil } }
            ),
            presenting: confirmAction
        ) { action in
            Button(action == .saveToCookbook ? "Save" : "Publish") {
                confirmAction = nil
                run(action)
            }
            Button("Cancel", role: .cancel) { confirmAction = nil }
        } message: { action in
            Text(
                action == .saveToCookbook
                    ? SousChefGate.cookbookSaveConfirmMessage
                    : SousChefGate.publishConfirmMessage
            )
        }
    }

    private func run(_ action: ConfirmAction) {
        Task {
            switch action {
            case .publish:
                await viewModel.publish(
                    publisher: RecipePublisher.shared,
                    keypair: keypair,
                    includeClientTag: AppSettings.shared.clientTagEnabled
                )
            case .saveToCookbook:
                await viewModel.saveToCookbook(
                    publisher: RecipePublisher.shared,
                    bookmarks: RecipeBookmarkRepository.shared,
                    keypair: keypair,
                    includeClientTag: AppSettings.shared.clientTagEnabled
                )
            }
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Turn recipe links into ready-to-post recipes.")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                Text("A little extra help in the kitchen.")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }

            HStack(alignment: .top, spacing: 8) {
                TextField("Paste a recipe URL…", text: $input, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(urlDetected ? .go : .return)
                    .onSubmit {
                        if urlDetected && !isLoading { viewModel.importUrl(input) }
                    }
                    .disabled(isLoading)
                    .accessibilityIdentifier("sous-chef-input")
                Button {
                    if let pasted = UIPasteboard.general.string { input = pasted }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .padding(.top, 8)
                }
                .disabled(isLoading)
                .accessibilityLabel("Paste")
            }

            Button {
                viewModel.importUrl(input)
            } label: {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Fetching and extracting recipe from URL...")
                    } else {
                        Text(urlDetected ? "🤖 Get Recipe" : "Get Recipe")
                    }
                }
                .font(AppFont.titleMedium)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Self.sousChefPurple.opacity(urlDetected || isLoading ? 1 : 0.45),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .disabled(!urlDetected || isLoading)
            .accessibilityIdentifier("sous-chef-get-recipe")
        }
        .padding(16)
    }

    // MARK: - State

    @ViewBuilder
    private var stateSection: some View {
        switch viewModel.state {
        case .idle:
            Spacer(minLength: 0)
        case .loading:
            VStack {
                Spacer()
                ProgressView().tint(Self.sousChefPurple)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .error(let message):
            VStack {
                Spacer()
                Text(message)
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .preview(let recipe):
            preview(recipe)
        }
    }

    // MARK: - Preview

    private func preview(_ recipe: RecipeParser.Recipe) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                previewHeader(recipe)
                detailChips(recipe)
                scaleRow
                if let notes = recipe.content.chefNotes, !notes.isEmpty {
                    sectionTitle("Chef's notes")
                    Text(notes)
                        .font(AppFont.bodyLarge)
                        .foregroundStyle(Color.wispOnSurface)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                if !recipe.content.ingredients.isEmpty {
                    ingredientsSection
                }
                if !recipe.content.directions.isEmpty {
                    directionsSection(recipe)
                }
                actionsSection(recipe)
                Spacer().frame(height: 32)
            }
        }
    }

    private func previewHeader(_ recipe: RecipeParser.Recipe) -> some View {
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

            Spacer().frame(height: 16)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func detailChips(_ recipe: RecipeParser.Recipe) -> some View {
        let items: [(String, String)] = [
            recipe.content.details.prepTime.map { ("Prep", $0) },
            recipe.content.details.cookTime.map { ("Cook", $0) },
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
                    viewModel.scale = option
                } label: {
                    Text(RecipeDetailView.scaleLabel(option))
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

    private func directionsSection(_ recipe: RecipeParser.Recipe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Directions")
            ForEach(Array(recipe.content.directions.enumerated()), id: \.offset) { index, step in
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

    // MARK: - Actions

    private func actionsSection(_ recipe: RecipeParser.Recipe) -> some View {
        let hasImage = recipe.image?.isEmpty == false
        let publishing = viewModel.publishState == .publishing
        let actionsEnabled = SousChefGate.shouldOpenConfirm(
            canSign: canSign, hasImage: hasImage, publishing: publishing
        )

        return VStack(spacing: 8) {
            Divider()
                .padding(.bottom, 4)

            // Block reasons surfaced explicitly (never a silent disable).
            if let reason = blockReason(canSign: canSign, hasImage: hasImage) {
                Text(reason)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            if case .error(let message) = viewModel.publishState {
                Text(message)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                confirmAction = .publish
            } label: {
                Group {
                    if publishing {
                        ProgressView().controlSize(.small).tint(Color.wispBackground)
                    } else {
                        Text("Publish")
                    }
                }
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispBackground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Color.wispPrimary.opacity(actionsEnabled ? 1 : 0.45),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .disabled(!actionsEnabled)
            .accessibilityIdentifier("sous-chef-publish")

            Button {
                confirmAction = .saveToCookbook
            } label: {
                Text("Save to my recipes")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurface)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Color.wispSurfaceVariant.opacity(actionsEnabled ? 0.6 : 0.3),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!actionsEnabled)
            .accessibilityIdentifier("sous-chef-save")

            Button {
                composeSession = .prefillMarkdown(
                    SousChefViewModel.composeHandoffMarkdown(recipe, multiplier: viewModel.scale)
                )
            } label: {
                Text("Edit")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurface)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.wispSurfaceVariant, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(publishing)
            .accessibilityIdentifier("sous-chef-edit")

            Button("Discard") {
                viewModel.reset()
            }
            .font(AppFont.bodyMedium)
            .foregroundStyle(Color.wispOnSurfaceVariant)
            .disabled(publishing)
        }
        .padding(16)
    }

    /// Android `SousChefScreen` block reasons, copy verbatim.
    private func blockReason(canSign: Bool, hasImage: Bool) -> String? {
        if !canSign { return "Sign in to publish or save this recipe." }
        if !hasImage { return "Add an image to publish — or Edit to attach one." }
        return nil
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.titleMedium)
            .foregroundStyle(Color.wispOnSurface)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}
