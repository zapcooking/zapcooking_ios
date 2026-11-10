import Testing
@testable import wisp

/// Port of web `src/lib/freshFeed/finishLine.test.ts` for the free tier.
/// Web's four member / membership-wait cases have no iOS counterpart (no
/// login, no membership: build spec §2); see the PR body.
@MainActor
struct FreshFinishLineTests {
    @Test func nothingUntilTheEndOfThe14DayWindow() {
        let f = FreshFinishLine.of(reached: false)
        #expect(!f.caughtUp)
        #expect(!f.recipeRow)
    }

    /// Web: "non-members: caught-up card, explore (recipes), the membership
    /// card, never Older posts". iOS keeps the caught-up card and the recipe
    /// row; there is no membership card and no Older posts to show.
    @Test func freeTier_caughtUpCardThenRecipeRow_noFloorCardNoOlderPosts() {
        #expect(FreshFinishLine.of(reached: true) == FreshFinishLine(caughtUp: true, recipeRow: true))
    }
}
