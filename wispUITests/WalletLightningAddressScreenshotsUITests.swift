import XCTest

/// Screenshot evidence for the Lightning-address setup sheet's custom
/// domain: new addresses register under @sats.zap.cooking (a CNAME to
/// Breez's hosted LNURL server) instead of @breez.tips.
///
/// Launches into `-WalletAddressHarness` (DEBUG): the real sheet, no
/// login. Screenshots are kept in the result bundle (`.keepAlways`) for
/// export to `docs/screenshots/wallet/` — UI changes ship screenshots
/// alongside tests (see AGENTS.md).
final class WalletLightningAddressScreenshotsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSetupSheetShowsCustomDomain() {
        let app = XCUIApplication()
        app.launchArguments = ["-WalletAddressHarness"]
        app.launch()

        let field = app.textFields["username"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "setup sheet did not come up:\n\(app.debugDescription)")
        attach("wallet-lightning-address-setup-idle")

        field.tap()
        field.typeText("souschef")
        // No connected wallet in the harness, so the availability probe
        // returns false and the sheet settles to "taken" after its
        // debounce — good enough to show the suffix next to a typed name.
        let settled = app.staticTexts["That username is already taken"].waitForExistence(timeout: 5)
        XCTAssertTrue(settled, "availability verdict never settled:\n\(app.debugDescription)")
        attach("wallet-lightning-address-setup-typed")
    }
}
