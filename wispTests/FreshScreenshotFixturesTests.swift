import Foundation
import Testing
@testable import wisp

/// The invented content behind the Fresh screenshots
/// (`FreshScreenshotFixtures`, DEBUG only): it must pass the real client's
/// checks and produce the states the screenshots need, with no real user.
@Suite @MainActor struct FreshScreenshotFixturesTests {
    @Test("every fixture event verifies, and every author has an invented profile")
    func fixturesVerifyAndHaveProfiles() {
        let all = FreshScreenshotFixtures.feed + FreshScreenshotFixtures.recipes
        #expect(!all.isEmpty)
        #expect(all.allSatisfy(FreshEventVerifier.isValid))
        let authors = Set(all.map(\.pubkey))
        #expect(authors.isSubset(of: Set(FreshScreenshotFixtures.profiles.keys)))
        #expect(FreshScreenshotFixtures.profiles.values.allSatisfy { $0.displayName?.isEmpty == false })
    }

    @Test("the feed is one short page with posts both sides of a 16-hour visit mark, and a long note")
    func fixturesMakeTheScreenshotStates() {
        let feed = FreshScreenshotFixtures.feed
        let now = NostrClock.now()
        #expect(feed.count < FreshRelayClient.pageSize, "short page: the finish line is reached")
        #expect(feed.allSatisfy { $0.createdAt > now - FreshRelayClient.freeWindowSeconds })
        let newer = feed.filter { $0.createdAt > now - 16 * 3600 }.count
        #expect(newer >= 3 && newer < feed.count, "the divider has posts above and below it")
        #expect(feed.contains { $0.content.count > 600 }, "a long note shows the Show more truncation")
        #expect(FreshScreenshotFixtures.recipes.count > FreshFeedViewModel.recipeRowLimit / 2)
        #expect(FreshScreenshotFixtures.recipes.allSatisfy(RecipeParser.isRecipe), "cards read RECIPE and open the recipe view")
    }

    @Test("the fixture relay answers a feed page and recipes like the contract, and nothing else")
    func fixtureRelayAnswers() async {
        let client = FreshRelayClient(transport: FreshFixtureTransport(events: FreshScreenshotFixtures.feed + FreshScreenshotFixtures.recipes))
        let page = await client.feedPage()
        #expect(page.outcome == .answered)
        #expect(page.events.count == FreshScreenshotFixtures.feed.count)
        #expect(page.isShortPage)
        let recipes = await client.recipes()
        #expect(recipes.outcome == .answered)
        #expect(recipes.events.allSatisfy { $0.kind == 30023 })
        #expect(recipes.events.count == FreshScreenshotFixtures.recipes.count)
        await client.close()
    }
}
