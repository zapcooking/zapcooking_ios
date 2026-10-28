#if DEBUG
import SwiftUI

/// Debug-only hosts for the emoji surfaces, reached with launch arguments —
/// the `-ComposerDragHarness` pattern applied to reactions: the real views,
/// no login, so UI tests and screenshot passes can reach them without an
/// account.
///
/// `-EmojiLibraryHarness` presents the real `EmojiLibrarySheet` as a sheet.
/// `-EmojiReactionHarness` hosts the real `EmojiReactionPicker` — normally a
/// post-card popover — centered on a plain background with the default
/// quick-reaction set.
struct EmojiLibraryHarness: View {
    @State private var presented = true

    var body: some View {
        Color.wispBackground
            .ignoresSafeArea()
            .sheet(isPresented: $presented) {
                EmojiLibrarySheet(mode: .pickForQuickList)
                    .environment(AppSettings.shared)
            }
    }
}

struct EmojiReactionHarness: View {
    @State private var emojiRepo = EmojiRepository.shared

    var body: some View {
        Color.wispBackground
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                // The picker is a popover-sized card in the app; host it the
                // same way (pinned top-leading, with popover-like chrome) so
                // the screenshot test can crop to just the card.
                EmojiReactionPicker(
                    onSelect: { _ in },
                    onPlus: {}
                )
                .padding(12)
                .background(
                    Color.wispSurfaceVariant.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .shadow(color: .black.opacity(0.35), radius: 12)
                .padding(12)
                .accessibilityIdentifier("emoji-reaction-harness")
            }
            .onAppear {
                // The real app seeds defaults in `refresh(for:)` at login;
                // the harness never logs in, so seed here instead.
                if emojiRepo.quickReactions.isEmpty {
                    emojiRepo.setQuickList(EmojiData.defaultQuickReactions)
                }
            }
    }
}
#endif
