import XCTest

/// Screenshot evidence for the composer's paste-attach gate: only direct
/// image/video URLs surface the "Attach this media" offer — an ordinary
/// page link stays as text with no offer row.
///
/// Launches into `-ComposerDragHarness` (DEBUG): the real `ComposeView`,
/// no login, a throwaway keypair, seeded slots A, B, C. Types through the
/// keyboard so the paste-offer pipeline runs exactly as it does for a
/// user. Screenshots are kept in the result bundle (`.keepAlways`) for
/// export to `docs/screenshots/composer/` — UI changes ship screenshots
/// alongside tests (see AGENTS.md).
final class ComposerUrlOfferScreenshotsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchComposer() -> (app: XCUIApplication, editor: XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-ComposerDragHarness"]
        app.launch()
        let order = app.staticTexts["harness-order"]
        XCTAssertTrue(order.waitForExistence(timeout: 15), "harness did not come up")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "composer editor not found:\n\(app.debugDescription)")
        editor.tap()
        return (app, editor)
    }

    private func attachScreen(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPlainPageUrlStaysTextWithoutAttachOffer() {
        let (app, editor) = launchComposer()
        editor.typeText("https://zap.cooking/recipes/soup")
        let typed = (editor.value as? String) ?? ""
        XCTAssertTrue(typed.contains("zap.cooking/recipes/soup"),
                      "keyboard mangled the typed URL: \(typed)")
        // The offer row derives synchronously from the text; wait out the
        // beat a (wrong) implementation would need to surface a chip.
        _ = app.buttons["Attach this media"].waitForExistence(timeout: 2)
        XCTAssertFalse(app.buttons["Attach this media"].exists,
                       "an ordinary page link must not offer media attach")
        attachScreen(app, "composer-url-gating-plain-url")
    }

    func testMediaUrlOffersAttachAndAttaches() {
        let (app, editor) = launchComposer()
        editor.typeText("https://nostr.build/pancakes.jpg")
        let offer = app.buttons["Attach this media"].firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 5),
                      "an image URL should surface the attach offer")
        attachScreen(app, "composer-url-gating-media-offer")

        offer.tap()
        // A freshly pasted slot has no bytes yet — it renders the retry
        // placeholder (Buttons), not an Image like the seeded slots — so
        // match the identifier across element types.
        let slot = app.descendants(matching: .any)
            .matching(identifier: "attachment-cell-3").firstMatch
        XCTAssertTrue(slot.waitForExistence(timeout: 5),
                      "accepting the offer should add a slot after the seeded A, B, C")
        attachScreen(app, "composer-url-gating-media-attached")
    }
}
