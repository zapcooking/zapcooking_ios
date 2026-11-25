import XCTest

/// A recipe card's poster takes taps for its own card only.
///
/// The bug: the poster image is scaled to fill a 2:3 frame, so a landscape
/// photo overflows it sideways. Clipping hid the overflow but left it
/// hit-testable, and the right-hand card is drawn above the left one — so a
/// tap on a left-column poster opened the right-column recipe.
///
/// Launches into `-RecipeGridHarness` (DEBUG): the real `RecipeCardView` in a
/// two-column grid, each with a 3:1 photo, no login and no network.
final class RecipeGridHitAreaUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RecipeGridHarness"]
        app.launch()
        XCTAssertTrue(app.buttons["Left One"].waitForExistence(timeout: 15),
                      "grid never appeared:\n\(app.debugDescription)")
        return app
    }

    /// Tap `card` at a normalized offset and report which recipe opened.
    private func open(_ card: String, at offset: CGVector, in app: XCUIApplication) -> String? {
        let button = app.buttons[card]
        guard button.waitForExistence(timeout: 5) else { return nil }
        button.coordinate(withNormalizedOffset: offset).tap()
        let opened = app.staticTexts["opened-recipe"]
        guard opened.waitForExistence(timeout: 5) else { return nil }
        let label = opened.label
        app.navigationBars.buttons.firstMatch.tap()
        _ = button.waitForExistence(timeout: 5)
        return label
    }

    func testEveryPosterOpensItsOwnRecipe() {
        let app = launch()

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "recipe-grid-landscape-photos"
        shot.lifetime = .keepAlways
        add(shot)

        // The card is the poster (about the top 85%) with the title under it.
        let cards: [(label: String, dTag: String, innerEdge: CGFloat)] = [
            ("Left One", "left-one", 0.93),
            ("Right One", "right-one", 0.07),
            ("Left Two", "left-two", 0.93),
            ("Right Two", "right-two", 0.07),
        ]
        for card in cards {
            let points: [(String, CGVector)] = [
                ("poster centre", CGVector(dx: 0.5, dy: 0.4)),
                ("poster inner edge", CGVector(dx: card.innerEdge, dy: 0.4)),
                ("poster outer edge", CGVector(dx: 1 - card.innerEdge, dy: 0.4)),
                ("title", CGVector(dx: 0.2, dy: 0.89)),
            ]
            for (name, offset) in points {
                XCTAssertEqual(open(card.label, at: offset, in: app), "Opened \(card.dTag)",
                               "\(card.label): tapping the \(name) opened the wrong recipe")
            }
        }
    }

    func testLongPressStillOffersReportAndBlock() {
        let app = launch()
        for card in ["Left One", "Right One"] {
            app.buttons[card].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["report-recipe-card"].waitForExistence(timeout: 5),
                          "\(card): no Report in the context menu")
            XCTAssertTrue(app.buttons["block-recipe-card"].exists,
                          "\(card): no Block User in the context menu")
            // Dismiss without choosing anything.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
            XCTAssertTrue(app.buttons["report-recipe-card"].waitForNonExistence(timeout: 5))
        }
    }
}
