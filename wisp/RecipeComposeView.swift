import SwiftUI
import PhotosUI

/// How the compose form was opened. Create is the Recipes-tab FAB;
/// edit is the author's own recipe detail; markdown prefill is the
/// 2.5 Sous Chef hand-off.
enum RecipeComposeSession: Identifiable {
    case create
    case edit(NostrEvent)
    case editUnavailable
    case prefillMarkdown(String)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let event): return "edit:\(event.id)"
        case .editUnavailable: return "edit-unavailable"
        case .prefillMarkdown: return "prefill"
        }
    }
}

/// Dedicated full-screen recipe form — not an extension of the note
/// composer. Fields and copy mirror the web `/create` form and Android
/// `RecipeComposeScreen`. Publish runs through ``RecipeComposeViewModel``
/// → ``RecipePublisher``.
struct RecipeComposeView: View {
    let keypair: Keypair
    let session: RecipeComposeSession
    var onPublished: (_ author: String, _ dTag: String) -> Void
    var onDismiss: () -> Void

    @State private var store: RecipeComposeViewModel
    @State private var categoryDraft = ""
    @State private var showDiscard = false
    @State private var didApplySession = false

    init(
        keypair: Keypair,
        session: RecipeComposeSession,
        viewModel: RecipeComposeViewModel? = nil,
        onPublished: @escaping (_ author: String, _ dTag: String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.keypair = keypair
        self.session = session
        self.onPublished = onPublished
        self.onDismiss = onDismiss
        _store = State(initialValue: viewModel ?? RecipeComposeViewModel())
    }

    private var canSign: Bool { !keypair.isWatchOnly }

    private var reason: String? {
        store.blockReason(canSign: canSign)
    }

    private var publishing: Bool {
        store.publishState == .publishing
    }

    private var errorMessage: String? {
        if case .error(let message) = store.publishState { return message }
        return nil
    }

    var body: some View {
        @Bindable var viewModel = store
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let notice = viewModel.prefillNotice {
                        Text(notice)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(Color.wispOnSurface)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.wispSurfaceVariant.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    }

                    fieldSection("Title*", caption: "Remember to make your title unique!") {
                        TextField("Title", text: $viewModel.title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("recipe-title")
                    }

                    fieldSection(
                        "Tags*",
                        caption: "Add at least one category that describes your recipe"
                    ) {
                        categoryEditor
                    }

                    fieldSection("Brief Summary", caption: nil) {
                        TextField(
                            "Some brief description of the dish",
                            text: $viewModel.summary,
                            axis: .vertical
                        )
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                    }

                    fieldSection("Chef's Notes", caption: "Markdown is supported") {
                        TextField(
                            "Eg. where the recipe is from, or any extra info",
                            text: $viewModel.chefNotes,
                            axis: .vertical
                        )
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                    }

                    fieldSection("Details", caption: nil) {
                        VStack(spacing: 8) {
                            labeledField("Prep time", placeholder: "20 min", text: $viewModel.prepTime)
                            labeledField("Cooking time", placeholder: "1 hour and 5 min", text: $viewModel.cookTime)
                            labeledField("Servings", placeholder: "4", text: $viewModel.servings)
                        }
                    }

                    fieldSection("Ingredients*", caption: nil) {
                        rowEditor(
                            rows: viewModel.ingredients,
                            placeholder: "2 eggs",
                            addLabel: "Add ingredient",
                            ordered: false,
                            onUpdate: viewModel.updateIngredient,
                            onRemove: viewModel.removeIngredient,
                            onAdd: viewModel.addIngredient
                        )
                    }

                    fieldSection("Directions*", caption: nil) {
                        rowEditor(
                            rows: viewModel.directions,
                            placeholder: "Bake for 30 min",
                            addLabel: "Add direction",
                            ordered: true,
                            onUpdate: viewModel.updateDirection,
                            onRemove: viewModel.removeDirection,
                            onAdd: viewModel.addDirection
                        )
                    }

                    fieldSection("Photos*", caption: "First image will be your cover photo") {
                        photoEditor
                    }

                    fieldSection("Additional Resources", caption: nil) {
                        TextField(
                            "Eg. where the recipe is from, or links",
                            text: $viewModel.additionalResources,
                            axis: .vertical
                        )
                        .lineLimit(2...8)
                        .textFieldStyle(.roundedBorder)
                    }

                    publishBlock
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color.wispBackground)
            .navigationTitle(viewModel.isEditing ? "Edit recipe" : "Create recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: requestDismiss)
                        .accessibilityIdentifier("recipe-compose-close")
                }
            }
            .interactiveDismissDisabled()
        }
        .onAppear(perform: applySession)
        .onChange(of: store.publishState) { _, state in
            if case .published(let author, let dTag) = state {
                onPublished(author, dTag)
            }
        }
        .alert("Discard this recipe?", isPresented: $showDiscard) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive, action: onDismiss)
        } message: {
            Text("You have unsaved changes. Closing now loses them — this form does not save drafts.")
        }
    }

    private func applySession() {
        guard !didApplySession else { return }
        didApplySession = true
        switch session {
        case .create:
            break
        case .edit(let event):
            if !store.prefillFromEvent(event) {
                store.markEditUnavailable()
            }
        case .editUnavailable:
            store.markEditUnavailable()
        case .prefillMarkdown(let markdown):
            store.prefillFromMarkdown(markdown)
        }
    }

    private func requestDismiss() {
        if store.isDirty {
            showDiscard = true
        } else {
            onDismiss()
        }
    }

    @ViewBuilder
    private func fieldSection<Content: View>(
        _ title: String,
        caption: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
            if let caption {
                Text(caption)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppFont.bodySmall)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var categoryEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.categories.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(store.categories, id: \.self) { cat in
                        Button {
                            store.removeCategory(cat)
                        } label: {
                            HStack(spacing: 4) {
                                Text(cat)
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                            .foregroundStyle(Color.wispOnSurface)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(cat)")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("e.g. italian", text: $categoryDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitCategory)
                    .accessibilityIdentifier("recipe-category-field")
                Button("Add", action: commitCategory)
                    .disabled(categoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func commitCategory() {
        store.addCategory(categoryDraft)
        categoryDraft = ""
    }

    private func rowEditor(
        rows: [RecipeComposeViewModel.Row],
        placeholder: String,
        addLabel: String,
        ordered: Bool,
        onUpdate: @escaping (Int, String) -> Void,
        onRemove: @escaping (Int) -> Void,
        onAdd: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 4) {
                    if ordered {
                        Text("\(index + 1).")
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                            .frame(width: 24, alignment: .trailing)
                    }
                    TextField(placeholder, text: Binding(
                        get: { row.text },
                        set: { onUpdate(row.id, $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        onRemove(row.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove")
                }
            }
            Button(action: onAdd) {
                Label(addLabel, systemImage: "plus")
                    .font(AppFont.bodyMedium)
            }
            .buttonStyle(.bordered)
        }
    }

    private var photoEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.images.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(store.images) { item in
                        photoThumb(item)
                    }
                }
            }
            Button {
                PhotoPickerService.present(
                    maxCount: 8,
                    filter: .images
                ) { providers in
                    store.addPickedProviders(providers, keypair: keypair)
                }
            } label: {
                Label("Add photos", systemImage: "plus")
                    .font(AppFont.bodyMedium)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("recipe-add-photos")
            .disabled(!canSign)
        }
    }

    private func photoThumb(_ item: RecipeComposeViewModel.ImageItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch item.status {
                case .done(let url):
                    if let parsed = URL(string: url) {
                        RetryingAsyncImage(
                            url: parsed,
                            content: { image in
                                image.resizable().scaledToFill()
                            },
                            loading: { thumbPlaceholder(progress: true) },
                            failure: { thumbPlaceholder(progress: false, label: "Failed") }
                        )
                    } else {
                        thumbPlaceholder(progress: false, label: "Failed")
                    }
                case .uploading:
                    thumbPlaceholder(progress: true)
                case .failed:
                    thumbPlaceholder(progress: false, label: "Failed")
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                store.removeImage(id: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove photo")
            .offset(x: 4, y: -4)
        }
        .frame(width: 96, height: 96)
    }

    private func thumbPlaceholder(progress: Bool, label: String? = nil) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.wispSurfaceVariant.opacity(0.5))
            if progress {
                ProgressView().controlSize(.small)
            } else if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }

    private var publishBlock: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("recipe-publish-error")
            }
            Button {
                Task {
                    await store.publish(
                        publisher: RecipePublisher.shared,
                        keypair: keypair,
                        includeClientTag: AppSettings.shared.clientTagEnabled
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    if publishing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(publishLabel)
                        .font(AppFont.titleMedium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.wispPrimary)
            .disabled(reason != nil || publishing)
            .accessibilityIdentifier("recipe-publish")
            .accessibilityLabel(publishLabel)
        }
    }

    /// The reason lives **on the button**. A greyed-out "Publish recipe"
    /// with no explanation is the failure mode this form exists to avoid.
    private var publishLabel: String {
        if publishing { return "Publishing…" }
        if let reason { return reason }
        return store.isEditing ? "Save changes" : "Publish recipe"
    }
}
