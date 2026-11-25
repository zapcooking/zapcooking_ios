import XCTest
import ObjectiveC

/// XCUITest waits for the app to go idle before each event, which lets any
/// fling finish before a tap lands. For the mid-fling test only, swap the
/// private quiescence wait for a no-op so the tap arrives while the list is
/// still coasting.
private enum Quiescence {
    static func disable() {
        guard let cls = NSClassFromString("XCUIApplicationProcess") else { return }
        let noop1: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
        let noop2: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
        if let m = class_getInstanceMethod(cls, NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")) {
            method_setImplementation(m, imp_implementationWithBlock(noop1))
        }
        if let m = class_getInstanceMethod(cls, NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")) {
            method_setImplementation(m, imp_implementationWithBlock(noop2))
        }
    }
}

/// Feed chrome auto-hide (`FeedBarsAutoHide`), driven by real drags on a
/// simulator that has a saved account: scroll down past the threshold and
/// both bars collapse; scroll back up and both return — read from the
/// chrome's own `up` / `down` accessibility value, because a collapsed row
/// (clipped, accessibility-hidden) stays in the element tree and its
/// hittability is not a dependable signal. The returned header must also
/// still take a tap. Skipped when no saved account or no hydrated cards.
final class FeedBarsAutoHideUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A finger drag on the screen center, clear of the FAB and the bars.
    /// `dyFrom` > `dyTo` scrolls down (hides), the reverse scrolls up.
    private func drag(app: XCUIApplication, from dyFrom: CGFloat, to dyTo: CGFloat) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dyFrom))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dyTo))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func wait(until condition: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    @MainActor
    func testScrollDownHidesBothBars_ScrollUpReturnsThem() throws {
        let app = XCUIApplication()
        app.launch()

        let feedTab = app.buttons["tab-feed"]
        guard feedTab.waitForExistence(timeout: 25) else {
            throw XCTSkip("No saved account on this simulator — the feed is not reachable")
        }
        feedTab.tap()

        let any = app.descendants(matching: .any)
        let topChrome = any["feed-top-chrome"]
        let bottomChrome = any["feed-bottom-chrome"]
        XCTAssertTrue(topChrome.waitForExistence(timeout: 10), "header chrome missing")
        XCTAssertTrue(bottomChrome.exists, "bottom chrome missing")
        XCTAssertEqual(topChrome.value as? String, "up")
        XCTAssertEqual(bottomChrome.value as? String, "up")

        guard app.buttons["post-overflow-menu"].firstMatch.waitForExistence(timeout: 25) else {
            throw XCTSkip("Feed has no hydrated cards to scroll")
        }

        // Scroll down: both bars collapse together.
        for _ in 0..<3 { drag(app: app, from: 0.65, to: 0.2) }
        XCTAssertTrue(wait(until: {
            (topChrome.value as? String) == "down" && (bottomChrome.value as? String) == "down"
        }, timeout: 6), "both bars should collapse on scroll down")
        // Settled (past the 200ms animation), for the shot: the collapsed
        // state must hold, not flicker.
        XCTAssertTrue(wait(until: {
            (topChrome.value as? String) == "down" && (bottomChrome.value as? String) == "down"
        }, timeout: 3), "the collapsed state should hold while reading")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(topChrome.value as? String, "down", "collapse should be sustained")
        XCTAssertEqual(bottomChrome.value as? String, "down", "collapse should be sustained")
        attach(app, "bars-collapsed")

        // Scroll back up: both return together.
        for _ in 0..<3 { drag(app: app, from: 0.3, to: 0.75) }
        XCTAssertTrue(wait(until: {
            (topChrome.value as? String) == "up" && (bottomChrome.value as? String) == "up"
        }, timeout: 6), "both bars should return on scroll up")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(topChrome.value as? String, "up", "the returned state should hold")
        XCTAssertEqual(bottomChrome.value as? String, "up", "the returned state should hold")
        attach(app, "bars-returned")

        // The returned header still takes a tap: the avatar opens the drawer.
        app.buttons["feed-gadgets-entry"].tap()
        XCTAssertTrue(app.otherElements["drawer-feed-relay"].waitForExistence(timeout: 6)
                      || app.descendants(matching: .any)["drawer-feed-relay"].waitForExistence(timeout: 2),
                      "the returned header should be tappable")
    }

    /// The compose FAB survives the collapse. Needs a signing account (the
    /// FAB is hidden for watch-only), so this launches a throwaway signing
    /// keypair on invented Fresh content; nothing is published. Run it on a
    /// simulator whose saved account you don't mind joining a new one.
    @MainActor
    func testComposeFabStays_AndRestoreChipBringsBarsBack() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FreshScreenshotAccount", "-FreshScreenshotNewAccount",
            "-FreshScreenshotSigningAccount", "-FreshScreenshotFixtures",
        ]
        app.launch()

        let any = app.descendants(matching: .any)
        let topChrome = any["feed-top-chrome"]
        let bottomChrome = any["feed-bottom-chrome"]
        XCTAssertTrue(topChrome.waitForExistence(timeout: 25), "header chrome missing")

        let fab = app.buttons["new-post"]
        XCTAssertTrue(fab.waitForExistence(timeout: 10), "FAB missing with bars up")
        XCTAssertTrue(fab.isHittable, "FAB not hittable with bars up")
        attach(app, "restore-bars-up")

        for _ in 0..<3 { drag(app: app, from: 0.65, to: 0.2) }
        guard wait(until: {
            (topChrome.value as? String) == "down" && (bottomChrome.value as? String) == "down"
        }, timeout: 6) else {
            throw XCTSkip("Fixture feed too short to collapse the bars")
        }
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "restore-bars-collapsed")
        XCTAssertTrue(fab.exists, "FAB gone with bars collapsed")
        XCTAssertTrue(fab.isHittable, "FAB not hittable with bars collapsed")
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThan(fab.frame.maxY, screen.maxY, "FAB pushed off screen")

        // The minimized tab bar: bottom-left, level with the FAB; a tap
        // brings both bars back and the chip goes away.
        let chip = app.buttons["feed-bars-restore"]
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "restore chip missing with bars collapsed")
        XCTAssertTrue(chip.isHittable, "restore chip not hittable")
        XCTAssertLessThan(chip.frame.midX, screen.midX, "restore chip should sit on the left")
        XCTAssertEqual(chip.frame.midY, fab.frame.midY, accuracy: 2, "chip and FAB centers should be level")
        chip.tap()
        XCTAssertTrue(wait(until: {
            (topChrome.value as? String) == "up" && (bottomChrome.value as? String) == "up"
        }, timeout: 3), "tapping the chip should bring both bars back")
        XCTAssertTrue(wait(until: { !chip.exists }, timeout: 3), "chip should go away with the bars up")
        Thread.sleep(forTimeInterval: 0.5)
        attach(app, "restore-bars-restored")

        // And the next scroll down hides them again.
        for _ in 0..<2 { drag(app: app, from: 0.65, to: 0.2) }
        XCTAssertTrue(wait(until: { (bottomChrome.value as? String) == "down" }, timeout: 6),
                      "bars should collapse again after a chip restore")
    }

    /// Tapping the restore circle mid-fling: the tap must stop the list (as
    /// a tap on a coasting scroll view does) and the bars must stay up —
    /// the fling's leftover travel must not hide them again.
    @MainActor
    func testRestoreTapDuringFling_stopsScroll_andBarsStayUp() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FreshScreenshotAccount", "-FreshScreenshotNewAccount",
            "-FreshScreenshotSigningAccount", "-FreshScreenshotFixtures",
        ]
        app.launch()
        let any = app.descendants(matching: .any)
        let topChrome = any["feed-top-chrome"]
        let bottomChrome = any["feed-bottom-chrome"]
        XCTAssertTrue(topChrome.waitForExistence(timeout: 25))
        // Collapse with a slow drag first so the circle is there.
        drag(app: app, from: 0.6, to: 0.4)
        let chip = app.buttons["feed-bars-restore"]
        guard chip.waitForExistence(timeout: 4) else { throw XCTSkip("bars did not collapse") }

        // Resolve the chip's frame while the app is idle; after this,
        // events no longer wait for the fling to end.
        let chipPoint = chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        _ = chip.frame
        Quiescence.disable()

        // A hard fling, then the tap while it coasts.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
        chipPoint.tap()

        // Right after the tap, a visible card must already be still.
        Thread.sleep(forTimeInterval: 0.25)
        let card = app.buttons["post-overflow-menu"].firstMatch
        let y1 = card.frame.minY
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(card.frame.minY, y1, accuracy: 1, "the tap should stop the fling")

        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "fling-restore")
        XCTAssertEqual(topChrome.value as? String, "up", "bars should stay up after a mid-fling restore")
        XCTAssertEqual(bottomChrome.value as? String, "up", "bars should stay up after a mid-fling restore")
    }
}
