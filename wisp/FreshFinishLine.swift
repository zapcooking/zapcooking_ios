import Foundation

/// The end of the 14-day window, ported from web
/// `src/lib/freshFeed/finishLine.ts` for the free tier only.
///
/// Web shows "You're all caught up", then an opt-in "Keep exploring" (the
/// archive's recipes), then for members "Older posts" and for everyone else
/// a membership / log-in card. iOS is free tier only (build spec §2: no
/// login, no membership copy, pitch, floor card or link-out), and the ruling
/// for v1 is the caught-up card followed by a recipe row. So:
/// - `caughtUp` and `recipeRow` both follow `reached`;
/// - there is no floor card, no "Older posts" and no membership wait (web
///   waits for `membershipKnown`; on iOS the answer is always "not a member").
nonisolated struct FreshFinishLine: Equatable, Sendable {
    /// The caught-up card.
    let caughtUp: Bool
    /// The recipe row after it.
    let recipeRow: Bool

    static let none = FreshFinishLine(caughtUp: false, recipeRow: false)

    /// `reached`: the feed reached the end of the free window (a short page,
    /// or the relay's `auth-required` floor close).
    static func of(reached: Bool) -> FreshFinishLine {
        reached ? FreshFinishLine(caughtUp: true, recipeRow: true) : .none
    }
}
