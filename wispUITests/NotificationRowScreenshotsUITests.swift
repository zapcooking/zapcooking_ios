import XCTest

/// Screenshot evidence for the notification row's merged-zaps pill: a long
/// actor display name must not crush the "+N more" capsule into a vertical
/// character stack (the bug in the row's flexible HStack, where the pill
/// used to wrap one glyph per line).
///
/// Launches into `-NotificationRowHarness` (DEBUG): the real
/// `NotificationRowView`, no login, fixture data seeded by the harness —
/// a zap folded with two duplicates under the display name
/// "Sondre | satoshiconsult.com". Screenshots are kept in the result
/// bundle (`.keepAlways`) for export to `docs/screenshots/notifications/`
/// — UI changes ship screenshots alongside tests (see AGENTS.md).
final class NotificationRowScreenshotsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testMergedZapsPillStaysHorizontalBesideLongName() {
        let app = XCUIApplication()
        app.launchArguments = ["-NotificationRowHarness"]
        app.launch()

        let pill = app.staticTexts["2 more zaps"]
        XCTAssertTrue(pill.waitForExistence(timeout: 15),
                      "merged-zaps pill not found:\n\(app.debugDescription)")

        // The pill must be wider than it is tall. The old bug collapsed it
        // to one glyph per line, flipping that ratio.
        let frame = pill.frame
        XCTAssertGreaterThan(frame.width, frame.height,
                             "pill wrapped vertically instead of staying horizontal: \(frame)")

        XCTAssertTrue(app.staticTexts["Sondre | satoshiconsult.com"].exists,
                      "long display name missing from the fixture row")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "merged-zaps-pill-horizontal"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
