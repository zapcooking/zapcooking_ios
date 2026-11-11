import XCTest

/// Screenshots for the Fresh default (AGENTS.md "Screenshots for UI
/// changes"): a brand-new account's first screen, the feed picker, the
/// last-visit divider and the finish line, on iPhone and on iPad in both
/// orientations. Drives the real app through `FreshScreenshotHarness`: a
/// watch-only account (it cannot sign, so nothing is published) and invented
/// content (`FreshScreenshotFixtures`, an in-app relay; no real user). Slow,
/// so it is not part of the gate; run it with
/// `-only-testing:wispUITests/FreshScreenshotsUITests` on a simulator with no
/// saved account.
final class FreshScreenshotsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FreshScreenshotAccount", "-FreshScreenshotFixtures"] + extra
        app.launch()
        return app
    }

    private func shot(_ name: String, _ orientation: UIDeviceOrientation) {
        let device = isPad ? "ipad" : "iphone"
        let suffix = isPad ? (orientation.isLandscape ? "-landscape" : "-portrait") : ""
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "fresh-\(name)-\(device)\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The feed is up: the picker reads "Fresh" and posts had time to load.
    private func waitForFresh(_ app: XCUIApplication) {
        let picker = app.buttons["feed-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 60), "feed never appeared:\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Fresh"].waitForExistence(timeout: 10), "landing feed is not Fresh")
        sleep(3)
    }

    /// The system's notification prompt covers the feed on first launch.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        if dontAllow.waitForExistence(timeout: 4) { dontAllow.tap() }
    }

    /// Short drags until `element` sits in the band [low, high] of the screen
    /// height (fractions), below the frosted header.
    private func bring(_ element: XCUIElement, in app: XCUIApplication,
                       low: CGFloat, high: CGFloat, max: Int = 80) -> Bool {
        let window = app.windows.firstMatch.frame
        var lastY: CGFloat?
        for _ in 0..<max {
            if element.exists {
                let y = element.frame.midY / window.height
                if y >= low && y <= high { return true }
                // The end of the list: it can't go any higher.
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

    /// Drag the feed by a fraction of the screen height (negative = up).
    private func drag(_ app: XCUIApplication, by fraction: CGFloat) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let end = start.withOffset(CGVector(dx: 0, dy: fraction * app.windows.firstMatch.frame.height))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    func testFreshScreens() {
        let orientations: [UIDeviceOrientation] = isPad ? [.portrait, .landscapeLeft] : [.portrait]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation

            // 1. A brand-new account's first screen, and the picker.
            var app = launch(["-FreshScreenshotNewAccount"])
            dismissSystemAlerts()
            waitForFresh(app)
            dismissSystemAlerts()
            shot("first-screen", orientation)
            app.buttons["feed-picker"].tap()
            XCTAssertTrue(app.buttons["Fresh"].waitForExistence(timeout: 5), "picker has no Fresh entry")
            sleep(1)
            shot("picker", orientation)
            app.terminate()

            // 2. The divider: the last visit was 16 hours ago (six newer posts).
            app = launch(["-FreshVisitMarkSecondsAgo", "57600"])
            waitForFresh(app)
            let divider = app.descendants(matching: .any)["fresh-new-since-divider"].firstMatch
            if bring(divider, in: app, low: 0.35, high: 0.6) {
                sleep(3)
                shot("divider", orientation)
            } else {
                XCTFail("no divider found")
            }
            app.terminate()

            // 3. The finish line: the fixture window is one short page.
            app = launch([])
            waitForFresh(app)
            let caughtUp = app.descendants(matching: .any)["fresh-caught-up"].firstMatch
            if bring(caughtUp, in: app, low: 0.2, high: 0.45, max: 120) {
                sleep(4)
                shot("finish-line", orientation)
            } else {
                XCTFail("no finish line found")
            }
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
