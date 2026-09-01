import SwiftUI

/// Recipe save control: tap toggles the default Saved list, long-press
/// opens `RecipeListChooserSheet`. Pending spinner on the button only.
/// Watch-only taps route through `RecipeSaveGate.needsKey`.
///
/// Extracted so `RecipeDetailView` can show this alone for watch-only
/// accounts without the rest of `ArticleActionBar` (reply / react / zap).
struct RecipeBookmarkButton: View {
    let event: NostrEvent
    let keypair: Keypair

    @State private var bookmarks = RecipeBookmarkRepository.shared
    @State private var showPicker = false
    @State private var suppressTap = false

    private var filled: Bool { bookmarks.isRecipeBookmarked(event) }
    private var pending: Bool { bookmarks.isWriting }

    var body: some View {
        Button {
            if suppressTap {
                suppressTap = false
                return
            }
            Task { await toggle() }
        } label: {
            ZStack {
                Image(systemName: filled ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16))
                    .foregroundStyle(filled ? Color.wispPrimary : Color.secondary)
                    .opacity(pending ? 0 : 1)
                if pending {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                suppressTap = true
                openPicker()
            }
        )
        .accessibilityLabel("Add to List")
        .accessibilityIdentifier("recipe-save-toggle")
        .accessibilityAddTraits(filled ? [.isSelected] : [])
        .task {
            bookmarks.paintFromCache(pubkey: keypair.pubkey)
            if !bookmarks.hasLoaded, !bookmarks.isLoading {
                await bookmarks.load(pubkey: keypair.pubkey)
            }
        }
        .sheet(isPresented: $showPicker) {
            RecipeListChooserSheet(event: event, keypair: keypair) {
                showPicker = false
            }
        }
    }

    private func toggle() async {
        switch RecipeSaveGate.of(keypair: keypair) {
        case .needsKey:
            RecipeSaveActions.presentNeedsKey()
        case .canWrite:
            _ = await bookmarks.toggle(event: event, keypair: keypair)
            if let message = bookmarks.lastWriteError {
                RecipeSaveActions.presentWriteError(message)
            }
        }
    }

    private func openPicker() {
        switch RecipeSaveGate.of(keypair: keypair) {
        case .needsKey:
            RecipeSaveActions.presentNeedsKey()
        case .canWrite:
            showPicker = true
        }
    }
}
