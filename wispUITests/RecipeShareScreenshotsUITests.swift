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

    /// Watch-only account: no signing key, so no "Share in Note".
    func testRecipeOverflowOffersShare() {
        openRecipeOverflow(extra: ["-FreshScreenshotNewAccount"])
        let app = XCUIApplication()
        XCTAssertTrue(app.buttons["share-recipe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["copy-recipe-link"].exists)
        XCTAssertTrue(app.buttons["copy-recipe-event-id"].exists)
        XCTAssertFalse(app.buttons["share-recipe-in-note"].exists)
        shot("recipe-detail-overflow-share")
    }

    /// Signed-in account: the full set, including "Share in Note".
    func testRecipeOverflowOffersShareInNote() {
        openRecipeOverflow(extra: ["-FreshScreenshotNewAccount", "-FreshScreenshotSigningAccount"])
        let app = XCUIApplication()
        XCTAssertTrue(app.buttons["share-recipe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["share-recipe-in-note"].exists)
        XCTAssertTrue(app.buttons["copy-recipe-link"].exists)
        XCTAssertTrue(app.buttons["copy-recipe-event-id"].exists)
        shot("recipe-detail-overflow-share-signed-in")
    }

    /// The real flow end to end: recipe → ⋯ → Share in Note → type a comment,
    /// then look at the live preview. Nothing is published.
    func testShareInNotePreview() {
        openRecipeOverflow(extra: ["-FreshScreenshotNewAccount", "-FreshScreenshotSigningAccount"])
        let app = XCUIApplication()
        let item = app.buttons["share-recipe-in-note"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "composer did not open")
        sleep(8) // let the embedded recipe card resolve from relays
        shot("share-in-note-composer-empty")
        // The composer opens focused; type straight into it.
        XCUIApplication().typeText("Making this tonight.")
        sleep(2)
        shot("share-in-note-composer-with-comment")
    }

    /// The cooking-pot icon in the top bar and on the Start cooking button.
    func testCookingPotIcon() {
        openRecipe(extra: ["-FreshScreenshotNewAccount"])
        let app = XCUIApplication()
        XCTAssertTrue(app.buttons["start-cooking"].waitForExistence(timeout: 30))
        shot("recipe-detail-cooking-pot-top-bar")
        let button = app.buttons["start-cooking-button"]
        var swipes = 0
        // Until the whole button clears the tab bar (isHittable alone is true
        // while it is still half behind it).
        let screenH = app.windows.firstMatch.frame.height
        while !(button.exists && button.frame.maxY < screenH * 0.88) && swipes < 20 {
            app.swipeUp(velocity: .slow); swipes += 1
        }
        XCTAssertTrue(button.exists, "Start cooking button not reached")
        sleep(1)
        shot("recipe-detail-cooking-pot-button")
    }

    private func openRecipeOverflow(extra: [String]) {
        openRecipe(extra: extra)
        let app = XCUIApplication()
        let o = app.buttons["recipe-overflow"]
        XCTAssertTrue(o.waitForExistence(timeout: 30), "no recipe overflow button")
        o.tap()
    }

    private func openRecipe(extra: [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["-FreshScreenshotAccount", "-FreshScreenshotFixtures"] + extra
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        if dontAllow.waitForExistence(timeout: 20) { dontAllow.tap() }

        // A brand-new account lands on the "You're all set" finish step first.
        let letsGo = app.buttons["Let’s go"]
        if letsGo.waitForExistence(timeout: 45) { letsGo.tap() }

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

    }
}
