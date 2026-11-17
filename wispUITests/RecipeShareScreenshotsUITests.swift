import XCTest

/// Screenshots for #222 (recipe Share / Copy Link). Drives the real app
/// through `FreshScreenshotHarness` (watch-only account, invented recipes
/// from `FreshScreenshotFixtures`): Recipes tab → open a recipe → overflow.
/// Slow, so not part of the gate; run with
/// `-only-testing:wispUITests/RecipeShareScreenshotsUITests` on a simulator
/// with no saved account.
final class RecipeShareScreenshotsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRecipeOverflowOffersShare() {
        let app = XCUIApplication()
        app.launchArguments = ["-FreshScreenshotAccount", "-FreshScreenshotFixtures"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        if dontAllow.waitForExistence(timeout: 20) { dontAllow.tap() }

        let recipesTab = app.buttons["tab-recipes"]
        XCTAssertTrue(recipesTab.waitForExistence(timeout: 60), "tab bar never appeared")
        recipesTab.tap()

        // Live recipes load into the grid; any card will do, so take the first
        // one that shows up rather than pinning a title.
        let titles = ["Pizza Dough", "Shrimp Étouffée", "Sheet-Pan Grilled Cheese", "Tomato-Parmesan Soup"]
        var tapped = false
        let deadline = Date().addingTimeInterval(45)
        while !tapped && Date() < deadline {
            for title in titles {
                let card = app.buttons[title].firstMatch
                if card.exists && card.isHittable { card.tap(); tapped = true; break }
            }
            if !tapped { sleep(1) }
        }
        XCTAssertTrue(tapped, "no recipe card appeared in the Recipes grid")

        let overflow = app.buttons["recipe-overflow"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 30), "no recipe overflow button")
        overflow.tap()

        XCTAssertTrue(app.buttons["share-recipe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["copy-recipe-link"].exists)
        shot("recipe-detail-overflow-share")
    }
}
