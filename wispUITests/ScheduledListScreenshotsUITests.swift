import XCTest

/// Screenshot evidence for the Scheduled tab: every kind of scheduled post
/// with its preview, time and status; a failed post with its explanation; a
/// cancel that waits for the server; a cancel refused because the post has
/// already gone out; and the empty list.
///
/// Launches into `-ScheduledListHarness` (DEBUG): the real
/// `DraftsScheduledView` over a scripted scheduler. No network, no login.
/// Screenshots are kept in the result bundle (`.keepAlways`) for export to
/// `docs/screenshots/scheduled/` (see AGENTS.md).
final class ScheduledListScreenshotsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ScheduledListHarness"] + extra
        app.launch()
        return app
    }

    private func attachScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "scheduled-row")
    }

    /// A post's text is drawn by a text view, so it is a `value`, not a label.
    private func shows(_ app: XCUIApplication, _ text: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch.exists
    }

    func testListShowsEveryKindSoonestFirst_andTheFailedPost() {
        let app = launch()
        XCTAssertTrue(rows(app).firstMatch.waitForExistence(timeout: 15), "no rows:\n\(app.debugDescription)")
        // Soonest first: the note due in 40 minutes, then the poll.
        XCTAssertTrue(app.staticTexts["POLL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Brisket"].exists)
        XCTAssertTrue(app.staticTexts["Ribs"].exists)
        attachScreen("scheduled-list-kinds")

        // The failed post is under the pending ones, with plain words.
        let failure = app.descendants(matching: .any).matching(identifier: "scheduled-failure").firstMatch
        for _ in 0..<4 where !failure.isHittable { app.swipeUp() }
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "failed post not shown:\n\(app.debugDescription)")
        XCTAssertTrue(failure.label.contains("This post wasn't published."), failure.label)
        XCTAssertTrue(failure.label.contains("blocked: spam filter"), failure.label)
        attachScreen("scheduled-list-failed")
    }

    func testCancelRemovesTheRowOnlyAfterTheServerAnswers_andSaysWhenItIsTooLate() {
        let app = launch()
        XCTAssertTrue(rows(app).firstMatch.waitForExistence(timeout: 15), "no rows:\n\(app.debugDescription)")
        let cancels = app.buttons.matching(identifier: "scheduled-cancel")
        XCTAssertEqual(cancels.count, 5, "one cancel per pending post, none on the failed one")

        // The first row cancels: gone once the scripted server has answered.
        XCTAssertTrue(shows(app, "Sunday roast"), "first row is not the soonest post:\n\(app.debugDescription)")
        cancels.element(boundBy: 0).tap()
        let gone = NSPredicate(format: "count == 4")
        expectation(for: gone, evaluatedWith: cancels)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "scheduled-notice").firstMatch.exists)
        XCTAssertFalse(shows(app, "Sunday roast"))

        // The poll (now first) has already gone out: the list says so.
        cancels.element(boundBy: 0).tap()
        let notice = app.descendants(matching: .any).matching(identifier: "scheduled-notice").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "no notice for a refused cancel:\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["This post has already been published."].exists)
        // …and has refreshed: the poll is no longer listed as pending.
        expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: cancels)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.staticTexts["POLL"].exists)
        attachScreen("scheduled-cancel-too-late")
    }

    func testEmptyListSaysSo_andCanBePulledToRefresh() {
        let app = launch(["-ScheduledListHarnessEmpty", "YES"])
        let empty = app.descendants(matching: .any).matching(identifier: "scheduled-empty").firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 15), "empty state missing:\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["No scheduled posts"].exists)
        attachScreen("scheduled-empty")

        // The empty list scrolls, so it can be pulled.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        from.press(forDuration: 0.05, thenDragTo: to)
        // The scripted scheduler has a post by the second fetch: seeing it
        // is the proof that the pull reloaded.
        XCTAssertTrue(rows(app).firstMatch.waitForExistence(timeout: 8),
                      "pulling the empty list did not reload it:\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Scheduled on zap.cooking"), "the refreshed post is not shown:\n\(app.debugDescription)")
        attachScreen("scheduled-empty-after-pull")
    }
}
