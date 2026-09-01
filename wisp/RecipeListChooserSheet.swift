import SwiftUI

/// Long-press (and overflow) collection picker. Port of Android
/// `RecipeListChooserSheet.kt`: a checklist of the user's kind-30001 recipe
/// lists plus an inline "New list" row. A recipe can sit in several lists
/// at once.
///
/// Not the 3.2 `CookbookCollectionCard` cover-grid seam — that card stays
/// the Saved-tab tile. This sheet is the save picker.
struct RecipeListChooserSheet: View {
    let event: NostrEvent
    let keypair: Keypair
    var onDismiss: () -> Void = {}

    @State private var bookmarks = RecipeBookmarkRepository.shared
    @State private var creating = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    private var coordinate: String? {
        RecipeBookmarkRepository.coordinateForEvent(event)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Save to collection")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurface)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                if bookmarks.lists.isEmpty {
                    Text("No collections yet")
                        .font(AppFont.bodyLarge)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(bookmarks.lists, id: \.dTag) { list in
                                listRow(list)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }

                Divider()
                    .padding(.vertical, 8)

                if creating {
                    createForm
                } else {
                    newListRow
                }
            }
            .padding(.bottom, 16)
            .background(Color.wispBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { close() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            bookmarks.paintFromCache(pubkey: keypair.pubkey)
            if !bookmarks.hasLoaded, !bookmarks.isLoading {
                await bookmarks.load(pubkey: keypair.pubkey)
            }
        }
    }

    private func listRow(_ list: RecipeBookmarkRepository.CookbookList) -> some View {
        let checked = coordinate.map { list.coordinates.contains($0) } ?? false
        return Button {
            Task { await toggle(list.dTag) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(checked ? Color.wispPrimary : Color.wispOnSurfaceVariant)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.title)
                        .font(AppFont.bodyLarge)
                        .foregroundStyle(Color.wispOnSurface)
                        .lineLimit(1)
                    Text(countLabel(list.coordinates.count))
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bookmarks.isWriting)
        .accessibilityLabel(list.title)
        .accessibilityAddTraits(checked ? [.isSelected] : [])
        .accessibilityIdentifier("recipe-list-chooser-\(list.dTag)")
    }

    private var newListRow: some View {
        Button {
            creating = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.wispPrimary)
                    .frame(width: 24, height: 24)
                Text("New list")
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(Color.wispPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New list")
        .accessibilityIdentifier("recipe-list-chooser-new")
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Collection name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { Task { await submitCreate() } }
            HStack {
                Spacer()
                Button("Cancel") {
                    creating = false
                    newName = ""
                }
                Button("Create") {
                    Task { await submitCreate() }
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bookmarks.isWriting)
            }
        }
        .padding(.horizontal, 16)
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 recipe" : "\(count) recipes"
    }

    private func toggle(_ dTag: String) async {
        if RecipeSaveGate.of(keypair: keypair) == .needsKey {
            RecipeSaveActions.presentNeedsKey()
            return
        }
        _ = await bookmarks.toggleRecipeInList(dTag: dTag, event: event, keypair: keypair)
        if let message = bookmarks.lastWriteError {
            RecipeSaveActions.presentWriteError(message)
        }
    }

    private func submitCreate() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if RecipeSaveGate.of(keypair: keypair) == .needsKey {
            RecipeSaveActions.presentNeedsKey()
            return
        }
        let dTag = await bookmarks.createList(title: name, seedEvent: event, keypair: keypair)
        if dTag == nil, let message = bookmarks.lastWriteError {
            RecipeSaveActions.presentWriteError(message)
            return
        }
        newName = ""
        creating = false
    }

    private func close() {
        dismiss()
        onDismiss()
    }
}
