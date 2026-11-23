import XCTest

/// Screenshots for the recipient-address zap gate (AGENTS.md "Screenshots
/// for UI changes"): a note whose author publishes a lud16 keeps the
/// action-bar bolt; a note whose author doesn't offers no zap affordance
/// at all — every zap would fail with "Recipient has no lightning address".
/// Drives the real `PostCardView` through `-ZapGatingHarness`: two fixture
/// cards, Marisol Vega (lud16) and Theo Brandt (no lud16), no login and
/// nothing signed or sent. Slow, so it is not part of the gate; run it with
/// `-only-testing:wispUITests/ZapGatingScreenshotsUITests`.
final class ZapGatingScreenshotsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZapGatingHarness"]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Author bylines render as private TextKit nodes that `staticTexts`
    /// can't coerce ("Automation type mismatch"), so match the label across
    /// every element type instead.
    private func named(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", label))
            .firstMatch
    }

    /// Bolts that are actually on screen (the accessibility tree can keep
    /// off-screen lazy rows around, so existence alone proves nothing).
    private func boltsOnScreen(in app: XCUIApplication) -> [XCUIElement] {
        let window = app.windows.firstMatch.frame
        let bolts = app.descendants(matching: .any).matching(identifier: "post-zap-action")
        return (0..<bolts.count).map { bolts.element(boundBy: $0) }.filter {
            $0.exists && window.intersects($0.frame)
        }
    }

    /// Bolts on `author`'s own card: a card's action bar sits below its
    /// byline, so only bolts at or below the name's top belong to it.
    private func boltsOnCard(of author: XCUIElement, in app: XCUIApplication) -> [XCUIElement] {
        let cardTop = author.frame.minY
        return boltsOnScreen(in: app).filter { $0.frame.minY >= cardTop - 8 }
    }

    /// Short drags until `element` sits in the band [low, high] of the screen
    /// height, so its card's action bar is in view.
    private func bring(_ element: XCUIElement, in app: XCUIApplication,
                       low: CGFloat, high: CGFloat, max: Int = 60) -> Bool {
        let window = app.windows.firstMatch.frame
        var lastY: CGFloat?
        for _ in 0..<max {
            if element.exists {
                let y = element.frame.midY / window.height
                if y >= low && y <= high { return true }
                if y > high, let lastY, abs(lastY - y) < 0.01 { return true }
                lastY = y
                drag(app, by: y > high ? -0.25 : 0.15)
            } else {
                lastY = nil
                drag(app, by: -0.35)
            }
        }
        return false
    }

    /// Drag by a fraction of the screen height (negative = up).
    private func drag(_ app: XCUIApplication, by fraction: CGFloat) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let end = start.withOffset(CGVector(dx: 0, dy: fraction * app.windows.firstMatch.frame.height))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    func testZapGatingScreenshots() {
        let app = launch()

        // 1. Marisol Vega publishes a lud16: her card keeps the bolt. Her
        //    card is first, so the harness opens on it.
        let marisol = named("Marisol Vega", in: app)
        XCTAssertTrue(marisol.waitForExistence(timeout: 30), "harness cards never loaded:\n\(app.debugDescription)")
        sleep(2)
        XCTAssertTrue(!boltsOnCard(of: marisol, in: app).isEmpty,
                      "no bolt on a card whose author has a lightning address")
        shot("zap-gating-address-present")

        // 2. Theo Brandt publishes no lud16: his card offers no zap at all.
        let theo = named("Theo Brandt", in: app)
        XCTAssertTrue(bring(theo, in: app, low: 0.05, high: 0.3),
                      "could not bring Theo's card into view")
        sleep(2)
        XCTAssertTrue(boltsOnCard(of: theo, in: app).isEmpty,
                      "bolt offered on a card whose author has no lightning address")
        shot("zap-gating-no-address")

        app.terminate()
    }
}
