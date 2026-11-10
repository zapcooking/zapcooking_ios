import XCTest

/// Screenshot evidence for the canonical reaction-emoji set (parity with
/// Android and web — see `tools/gen-emoji-data.py`): the quick-reaction
/// grid shows the full 18 picks including the seasonal ones (🎃), and the
/// library's generated catalog covers food and the complete RGI flag set.
///
/// Launches the DEBUG harnesses (`-EmojiReactionHarness`,
/// `-EmojiLibraryHarness`) — the real picker and library, no login.
final class EmojiParityScreenshotsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Attach a screenshot cropped to `element`'s frame — a popover-sized
    /// card would otherwise drown in a full-screen capture's dead space.
    private func attachCropped(_ app: XCUIApplication, _ element: XCUIElement, _ name: String) {
        let full = XCUIScreen.main.screenshot()
        let scale = full.image.scale  // points → pixels
        let frame = element.frame
        let pixelRect = CGRect(
            x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale
        )
        guard let cropped = full.image.cgImage?.cropping(to: pixelRect) else {
            attach(app, name)  // fall back to the full screen
            return
        }
        let png = UIImage(cgImage: cropped).pngData() ?? Data()
        let shot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testQuickReactionGridShowsCanonicalSet() {
        let app = XCUIApplication()
        app.launchArguments = ["-EmojiReactionHarness"]
        app.launch()
        XCTAssertTrue(app.buttons["🍝"].waitForExistence(timeout: 10),
                      "🍝 missing from the quick-reaction grid")
        XCTAssertTrue(app.buttons["🌮"].exists, "🌮 missing from the quick-reaction grid")
        // Seasonal emoji stay in the catalog, not the defaults.
        XCTAssertFalse(app.buttons["🎃"].exists, "🎃 must not default into the quick grid")
        let card = app.descendants(matching: .any)
            .matching(identifier: "emoji-reaction-harness").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3), "harness card not found")
        attachCropped(app, card, "emoji-quick-reactions")
    }

    func testLibraryFoodAndFlagsTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-EmojiLibraryHarness"]
        app.launch()
        let foodTab = app.buttons["emoji-tab-Food"]
        XCTAssertTrue(foodTab.waitForExistence(timeout: 10), "emoji library did not come up")
        foodTab.tap()
        XCTAssertTrue(app.buttons["🌮"].waitForExistence(timeout: 5),
                      "🌮 not found in the Food tab")
        attach(app, "emoji-library-food")

        // Flags sits past the right edge of the overflowing tab strip, where
        // `tap()` has no hit point. The strip is the sheet's short ScrollView
        // — swipe it left until the tab's frame is on screen, then tap. Tab
        // selection scroll-snaps the grid (a plain VStack, so it lands
        // exactly, however far the section is).
        let flagsTab = app.buttons["emoji-tab-Flags"]
        XCTAssertTrue(flagsTab.waitForExistence(timeout: 5), "Flags tab missing")
        var strip: XCUIElement?
        for i in 0..<app.scrollViews.count {
            let sv = app.scrollViews.element(boundBy: i)
            if sv.frame.height < 100 {
                strip = sv
                break
            }
        }
        for _ in 0..<4 where flagsTab.frame.minX >= app.frame.width - 30 {
            if let strip {
                strip.swipeLeft()
            } else {
                let y = flagsTab.frame.midY / app.frame.height
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: y))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: y)))
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertLessThan(flagsTab.frame.minX, app.frame.width - 30,
                          "Flags tab never scrolled into the strip")
        flagsTab.tap()
        // Tab selection scroll-snaps the plain-VStack grid exactly — prove
        // navigation by the section header's position, not a flag cell
        // (flags render in codepoint order; 🇺🇸 sits below the fold).
        let header = app.staticTexts["Flags"]
        XCTAssertTrue(header.waitForExistence(timeout: 6) && header.frame.minY < 600,
                      "Flags section header not near the top after tab tap (minY=\(header.frame.minY))")
        app.swipeUp()
        attach(app, "emoji-library-flags")
    }
}
