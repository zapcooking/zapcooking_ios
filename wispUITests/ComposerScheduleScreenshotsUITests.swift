import XCTest

/// Screenshot evidence for the composer's scheduling changes: the picker's
/// 5-minutes-to-90-days limits, the notice shown when a saved schedule time
/// has passed, and a scheduled poll's "Ends…" line counting from the publish
/// time.
///
/// Launches into `-ComposerDragHarness` (DEBUG): the real `ComposeView`, no
/// login, a throwaway keypair. Nothing is published: no test taps Publish.
/// Screenshots are kept in the result bundle (`.keepAlways`) for export to
/// `docs/screenshots/composer/` (see AGENTS.md).
final class ComposerScheduleScreenshotsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ComposerDragHarness"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["harness-order"].waitForExistence(timeout: 15), "harness did not come up")
        return app
    }

    private func attachScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSchedulePickerShowsItsLimits() {
        let app = launch()
        let more = app.descendants(matching: .any).matching(identifier: "compose-more").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More button not found:\n\(app.debugDescription)")
        more.tap()
        let row = app.staticTexts["Schedule post"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Schedule row not found:\n\(app.debugDescription)")
        row.tap()
        let limits = app.staticTexts["schedule-limits"]
        XCTAssertTrue(limits.waitForExistence(timeout: 8), "schedule sheet did not open:\n\(app.debugDescription)")
        XCTAssertEqual(limits.label, "Pick a time from 5 minutes to 90 days from now.")
        XCTAssertTrue(app.buttons["Set"].exists)
        attachScreen("composer-schedule-picker-limits")
    }

    func testARestoredDraftWhoseTimeHasPassedSaysSo() {
        let app = launch(["-ComposerHarnessStaleSchedule", "YES"])
        let notice = app.descendants(matching: .any).matching(identifier: "schedule-notice").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "no notice for the passed time:\n\(app.debugDescription)")
        XCTAssertTrue(
            app.staticTexts["The time you picked for this post has passed, so it's no longer scheduled. Pick a new time, or post it now."].exists,
            "notice text missing:\n\(app.debugDescription)"
        )
        // The time is gone, not just flagged: no "Scheduled for" banner.
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Scheduled for'")).firstMatch.exists)
        attachScreen("composer-schedule-time-passed")
    }

    func testAScheduledPollEndsCountingFromThePublishTime() {
        let app = launch(["-ComposerHarnessScheduledPoll", "3"])
        let ends = app.staticTexts["poll-ends"]
        XCTAssertTrue(ends.waitForExistence(timeout: 8), "poll end line not found:\n\(app.debugDescription)")
        XCTAssertTrue(ends.label.hasPrefix("Ends "), ends.label)
        // The editor sits under the keyboard when the composer opens.
        // The editor opens half under the keyboard. Drag the composer's
        // scroll area (above the keyboard) up until the line is in view.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        for _ in 0..<5 where !ends.isHittable {
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTAssertTrue(ends.isHittable, "poll end line is not on screen: \(ends.frame)")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Scheduled for'")).firstMatch.exists)
        // A one-day poll scheduled three days out is not closing early.
        XCTAssertFalse(app.staticTexts["poll-closes-early"].exists)
        attachScreen("composer-schedule-poll-ends")
    }
}
