import XCTest

/// Selecting a GIF in the composer's gifs.nostr.build picker, driven by real
/// touch events through the real picker and the real composer (launched into
/// `-ComposerDragHarness`).
///
/// The picker's cell is a SwiftUI `Button` whose whole label is the UIKit
/// `UIImageView` an animated preview draws in once loaded. A touch landing on
/// that view never reaches SwiftUI's gesture system — the attachment strip hit
/// the same wall first (see `testGIFThumbnailsDrag`) — so a loaded cell had
/// nothing left to hit and picking was a visible-but-dead tap: the sheet
/// stayed open and no attachment landed.
///
/// Live: the picker searches gifs.nostr.build with the gitignored bundled key.
/// Without the key or a connection the picker shows its status line instead
/// of results, and the test skips rather than fails.
final class GifPickerSelectUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testTappingAGifAttachesIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ComposerDragHarness"]
        app.launch()

        let order = app.staticTexts["harness-order"]
        XCTAssertTrue(order.waitForExistence(timeout: 15), "harness did not come up")
        XCTAssertEqual(order.label, "order:A,B,C")

        app.buttons["Add GIF"].tap()
        XCTAssertTrue(app.textFields["gif-picker-search"].waitForExistence(timeout: 5),
                      "GIF picker did not open")

        // Tap a topic chip rather than typing: no keyboard arbitration.
        let chip = app.buttons["gif-chip-gm"]
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "no topic chips in the picker")
        chip.tap()

        let cell = app.buttons["gif-cell"].firstMatch
        if !cell.waitForExistence(timeout: 20) {
            let status = app.staticTexts["gif-picker-status"]
            if status.exists {
                throw XCTSkip("GIF search unavailable here (no key, offline, or rate-limited): \(status.label)")
            }
            XCTFail("no GIFs loaded for the topic chip:\n\(app.debugDescription)")
            return
        }

        // Let the w240 previews load before tapping: the cell is tappable
        // while its SwiftUI placeholder color is up and goes dead only when
        // the UIKit image view takes the label over — that is the regression
        // this test guards.
        Thread.sleep(forTimeInterval: 6)

        cell.tap()

        // A picked GIF appends a slot the harness didn't seed, so the order
        // readout grows to a fourth entry.
        let grew = NSPredicate { _, _ in
            app.staticTexts["harness-order"].label.hasPrefix("order:A,B,C,")
        }
        let attached = XCTNSPredicateExpectation(predicate: grew, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [attached], timeout: 8), .completed,
                       "tapping a loaded GIF attached nothing; order=\(order.label)")
    }
}
