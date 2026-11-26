import XCTest

/// Screenshot evidence for the GIF picker's loading placeholders: each cell
/// holds its real aspect-ratio height while its preview downloads, instead
/// of collapsing flat. The collapse was not just cosmetic — with every cell
/// at zero height the whole page fit on screen at once, every cell fired
/// onAppear, and the tail check paged in (and started downloading) the
/// entire result set the moment the picker opened.
///
/// Launches into `-ComposerDragHarness` (DEBUG) and searches
/// gifs.nostr.build live with the gitignored bundled key. Without the key
/// or a connection the picker shows its status line instead of results, and
/// the test skips rather than fails. The placeholder shot is taken the
/// moment the first cell exists — previews land over the following seconds,
/// so the second shot documents the settled grid.
final class GifPickerPlaceholderScreenshotsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testPlaceholderCellsHoldTheirHeight() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ComposerDragHarness"]
        app.launch()

        let order = app.staticTexts["harness-order"]
        XCTAssertTrue(order.waitForExistence(timeout: 15), "harness did not come up")

        app.buttons["Add GIF"].tap()
        XCTAssertTrue(app.textFields["gif-picker-search"].waitForExistence(timeout: 5),
                      "GIF picker did not open")

        let chip = app.buttons["gif-chip-gm"]
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "no topic chips in the picker")
        chip.tap()

        // Cells exist from the placeholder phase on — the shot is racy by
        // design (previews start landing immediately), but on an uncached
        // install the first frames show placeholder cells holding height.
        let cell = app.buttons["gif-cell"].firstMatch
        if !cell.waitForExistence(timeout: 20) {
            let status = app.staticTexts["gif-picker-status"]
            if status.exists {
                throw XCTSkip("GIF search unavailable here (no key, offline, or rate-limited): \(status.label)")
            }
            XCTFail("no GIFs loaded for the topic chip:\n\(app.debugDescription)")
            return
        }
        // Previews land fast on a simulator, so the open shot usually shows
        // the settled first page; the definitive placeholder evidence is the
        // tail: flinging down materializes the next page's cells, which are
        // still gray placeholders (holding their real heights) for the beat
        // before their previews land.
        attach(app, "gif-picker-open")

        app.swipeUp(velocity: .fast)
        attach(app, "gif-picker-placeholders")

        Thread.sleep(forTimeInterval: 8)
        attach(app, "gif-picker-results")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
