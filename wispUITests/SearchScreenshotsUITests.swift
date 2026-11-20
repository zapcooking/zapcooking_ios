import XCTest

/// Screenshot evidence for the search parity rework: recipes rows,
/// people rows merged from the username index, and notes — each with the
/// hashtag/keyword chip row above the results.
///
/// Each mode gets its own app launch (`-WatchOnlyLogin` + `-SearchHarness
/// <query> -SearchHarnessMode <mode>`, DEBUG): search relays rate-limit
/// identical filters on one connection, so sharing a session across four
/// rapid searches blanked the later modes. One query per fresh process
/// keeps every screenshot an honest render of live relay answers.
/// Kept in the result bundle (`.keepAlways`) for export to
/// `docs/screenshots/search/` — UI changes ship screenshots alongside
/// tests (see AGENTS.md).
final class SearchScreenshotsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchSearch(_ query: String, mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-WatchOnlyLogin", "319ad3e790634dbe86f14db9c2995b26ee3c6228be55f89c4c7fea9acc01d50a",
            "-SearchHarness", query,
            "-SearchHarnessMode", mode,
        ]
        app.launch()
        // The search field only shows Cancel while focused; on launch the
        // unfocused bar shows the settings icon, so wait on the field itself.
        let field = app.textFields["Search"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "search screen did not come up")
        return app
    }

    private func attachScreen(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The harness seeds the query after ~3s; the 500ms debounce plus the
    /// relay round-trip follow. `waitForAllRelays` bounds the search at 5s;
    /// the extra settle makes sure the screenshot shows the final state.
    private func capture(_ mode: String, _ name: String) {
        let app = launchSearch("soup", mode: mode)
        _ = app.staticTexts["Hashtags"].waitForExistence(timeout: 12)
        sleep(7)
        attachScreen(app, name)
    }

    func testRecipesScreenshot() {
        capture("recipes", "search-recipes-results")
    }

    func testPeopleScreenshot() {
        capture("people", "search-people-results")
    }

    func testNotesScreenshot() {
        capture("notes", "search-notes-results")
    }

    /// The unreachable empty state: with every search relay unreachable
    /// (here: one custom relay pointing at a closed local port, the real
    /// relay-picker flow), an empty result list must read as a failure
    /// with a retry — never as "No results found".
    func testUnreachableRelaysShowFailureState() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-WatchOnlyLogin", "319ad3e790634dbe86f14db9c2995b26ee3c6228be55f89c4c7fea9acc01d50a",
            // Empty query: the harness only lands us on the search tab.
            "-SearchHarness", "",
        ]
        app.launch()
        let field = app.textFields["Search"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "search screen did not come up")

        // Advanced panel → relay menu → add an unreachable relay. Adding
        // selects it as the individual search relay.
        app.buttons["search-advanced-toggle"].tap()
        let relayMenu = app.buttons["Default"]
        XCTAssertTrue(relayMenu.waitForExistence(timeout: 5), "relay selector not found")
        relayMenu.tap()
        let addRelayItem = app.buttons["Add custom relay\u{2026}"]
        XCTAssertTrue(addRelayItem.waitForExistence(timeout: 5), "Add custom relay menu item not found")
        addRelayItem.tap()

        let relayField = app.textFields.firstMatch
        XCTAssertTrue(relayField.waitForExistence(timeout: 5), "add-relay sheet did not come up")
        relayField.tap()
        relayField.typeText("wss://127.0.0.1:1")
        app.buttons["Add"].tap()

        // Query the unreachable relay and wait out the 6s search window.
        field.tap()
        field.typeText("soup\n")
        let failure = app.staticTexts["Couldn't reach search relays"]
        XCTAssertTrue(failure.waitForExistence(timeout: 20),
                      "unreachable state did not appear:\n\(app.debugDescription)")
        attachScreen(app, "search-unreachable")
    }
}
