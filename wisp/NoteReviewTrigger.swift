import Foundation

/// Gates for the Cheffy Note Review entry points (port of Android
/// `cheffy/NoteReviewTrigger.kt`, issue #150 there): an overflow-menu item
/// that is always present when the note is eligible, plus an adaptive
/// inline slot in the card's action row that renders only when the
/// measured row is wide enough.
///
/// Pure so the whole decision matrix is testable. Production splits the
/// conjunction across where the data lives — `isEligible` in `PostCardView`
/// (the SINGLE eligibility source feeding both the menu entry and the
/// inline slot) and `meetsInlineWidth` against the action row's measured
/// width — while `showInline` composes them for the tests. Watch-only
/// accounts are gated upstream: the action row is hidden for them and the
/// menu entry checks it explicitly. Main-actor like `ZapGate` / `CheffyGate`,
/// since the flag it defaults to is.
enum NoteReviewTrigger {

    /// Minimum measured action-row width (points) for the inline slot.
    ///
    /// Derived from measurement, not hand-tuned. The row is `PostCardView`'s
    /// `HStack(spacing: 0)` of `ActionRowItem`s separated by zero-minimum
    /// spacers; `BottomBarAndActionRowTests` requires the count-heavy worst
    /// case to fit the row with 4pt per gap. Control widths measured with
    /// `ImageRenderer` on 2026-09-19 (MacBook Air, Xcode 26.3, iPhone 17 /
    /// iOS 26.2 simulator):
    ///
    /// ```
    ///   reply "1.2k" ........ 51pt      bookmark (bare) ....... 44pt
    ///   react 🔥 "1.2k" ..... 50pt      Cheffy (bare) ......... 44pt
    ///   repost "1.2k" ....... 54pt      expand (bare) ......... 44pt
    ///   zap "1.2k" .......... 45pt      any "0" / "12" count .. 44pt
    ///   reply "999" ......... 51pt
    ///
    ///   six-control worst case (today's row) ...... 288pt
    ///   seven-control worst case (+ Cheffy) ....... 332pt
    ///   seven controls, ordinary counts ........... 308pt
    ///
    ///   7 × 44pt targets .......................... 308pt  a11y floor
    ///   6 × 4pt gaps .............................. 24pt   the test's gap rule
    ///   ------------------------------------------------
    ///   seven-slot hard minimum ................... 332pt
    ///   + count headroom (worst case − bare) ...... 24pt
    ///   ================================================
    ///   inlineMinRowWidth ......................... 356pt
    /// ```
    ///
    /// The card inset is 16pt per side, so a 375pt device (iPhone SE class)
    /// has a 343pt row: **menu-only**, the analogue of Android's 360dp
    /// class staying overflow-only. A 390pt device has 358pt: **clears**, as
    /// does every wider iPhone. Below the threshold the slot is ABSENT —
    /// never shrunk below 44pt and never left to `HStack` squeeze semantics.
    static let inlineMinRowWidth: CGFloat = 356

    /// The single eligibility source: flag ∧ image detected. `flagEnabled`
    /// is parameterized so the flag-off behavior stays testable while the
    /// kill switch remains a compile-time constant.
    static func isEligible(
        noteContent: String,
        flagEnabled: Bool = FeatureFlags.noteReviewEnabled
    ) -> Bool {
        flagEnabled && !ImageUrls.extractImageUrls(noteContent).isEmpty
    }

    /// The width half of the inline gate — the action row's measured width.
    static func meetsInlineWidth(_ rowWidth: CGFloat) -> Bool {
        rowWidth >= inlineMinRowWidth
    }

    /// The full inline-slot decision, composed for tests: eligible, not a
    /// quoted (reduced-width) render, and the row measured wide enough.
    static func showInline(
        noteContent: String,
        rowWidth: CGFloat,
        isQuoted: Bool,
        flagEnabled: Bool = FeatureFlags.noteReviewEnabled
    ) -> Bool {
        isEligible(noteContent: noteContent, flagEnabled: flagEnabled)
            && !isQuoted
            && meetsInlineWidth(rowWidth)
    }
}
