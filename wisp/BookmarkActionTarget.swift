import SwiftUI

/// Where the engagement-bar bookmark goes.
///
/// ⚠️ Corrected assumption (Concern 3.1b): `ArticleActionBar` previously
/// always opened `AddToNoteListSheet` (NIP-51 kind **30003**). Recipes must
/// use `RecipeBookmarkRepository` (kind **30001**, `d=nostrcooking-bookmarks`).
/// Plain long-form articles keep the inherited 30003 sheet.
enum BookmarkActionTarget: Equatable {
    /// Canonical recipe Saved list / named collections (kind 30001).
    case recipeBookmark
    /// Inherited note bookmark sets (kind 30003).
    case noteList

    static func of(event: NostrEvent) -> Self {
        RecipeParser.isRecipe(event) ? .recipeBookmark : .noteList
    }
}

/// Watch-only / no signing key. Same classification as `ReportOutcome.needsKey`
/// (4.1): the affordance is present, the write is refused, and the user is
/// told to sign in with a key. Android's recipe bookmark is a silent no-op
/// for READ_ONLY — this toast is a deliberate iOS divergence.
enum RecipeSaveGate: Equatable {
    case canWrite
    case needsKey

    static func of(canSign: Bool) -> Self {
        canSign ? .canWrite : .needsKey
    }

    static func of(keypair: Keypair) -> Self {
        of(canSign: !keypair.isWatchOnly)
    }
}

enum RecipeSaveActions {
    /// Parallel to `ReportSheet`'s `.needsKey` toast, save-specific copy.
    static let needsKeyMessage =
        "Saving is signed with your key. Sign in with a key to save this."

    static func presentNeedsKey() {
        SuccessToast.shared.show(
            needsKeyMessage,
            icon: "exclamationmark.triangle.fill",
            accent: .red
        )
    }

    /// Android `WRITE_UNCONFIRMED_MESSAGE` (and any other `lastWriteError`)
    /// via the same pill `ReportSheet` uses for `.failed`.
    static func presentWriteError(_ message: String) {
        SuccessToast.shared.show(
            message,
            icon: "exclamationmark.triangle.fill",
            accent: .red
        )
    }
}
