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
}
