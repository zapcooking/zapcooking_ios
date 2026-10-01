import XCTest

/// Visual harness for the NIP-22 mixed-thread display, driven against the
/// live relays.
///
/// Opens the real thread from the bug report — a kind-1 note whose comment
/// chain continues through four nested kind-1111 comments (Sidecar/Ditto
/// style) — by typing the comment's `nevent1…` into Search's direct id
/// lookup, then captures screenshots of the thread screen.
///
/// The strict regression assertions live in `LiveNip22ThreadTests`, which
/// drives the same thread through the real `ThreadViewModel` and fails if any
/// nested comment is missing. This harness exists because the thread screen's
/// accessibility layer is unusable for assertions while an inline image
/// loader spins (the app never reports idle, so every XCUITest snapshot times
/// out) — a raw `XCUIScreen` capture doesn't need idle, so the screenshots
/// document what actually rendered.
///
///   root kind 1  000007eb…  (the note)
///   └ c1 a55ad0ed "nice dude. i like this…"      (top-level comment)
///     └ c2 00000817 "Pretty sure Ditto doesn't…"  (comment → comment)
///       └ c3 01703a83 "you go to event details…"
///         └ c4 00000792 "This is Nostr, we can only dumb it down…"
///
/// Before the `#E` root-scope subscription existed, the `#e`-only stream
/// delivered c1 only — everything below the first reply never appeared.
final class Nip22ThreadOpenUITests: XCTestCase {

    private static let nevent = "nevent1qvzqqqqy2upzq0mhp4ja8fmy48zuk5p6uy37vtk8tx9dqdwcxm32sy8nsaa8gkeyqythwumn8ghj7un9d3shjtnp0faxzmt09ehx2ap0qyghwumn8ghj7mn0wd68ytnhd9hx2tcqyzj4458dg6uhgags8fsy2hug34u8g0qv6d83fpnhtpn8shjgp8smxr3l0p4"

    override func setUp() {
        // Gesture and query hiccups on the busy thread screen must not cut the
        // screenshot tour short — later captures are the point.
        continueAfterFailure = true
    }

    /// The details drawer shows the event kind above "Seen on", beside
    /// "Posted via …" — so a card reads which kind was used by which client.
    /// Launches the live thread from the bug report via `-ThreadHarnessSeed`.
    func testDetailsDrawerShowsKind() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ThreadHarnessSeed", "a55ad0ed46b97475103a60455f888d78743c0cd34f1486775866785e4809e1b3",
            "-ThreadHarnessAuthor", "3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24",
        ]
        app.launch()
        Thread.sleep(forTimeInterval: 8)

        let toggles = app.buttons.matching(identifier: "post-details-toggle")
        if !toggles.firstMatch.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
            Thread.sleep(forTimeInterval: 10)
        }
        XCTAssertTrue(toggles.firstMatch.waitForExistence(timeout: 60), "details toggle missing:\n\(app.debugDescription)")

        toggles.firstMatch.tap()
        let kindRow = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "KIND ")).firstMatch
        XCTAssertTrue(kindRow.waitForExistence(timeout: 15), "kind row missing in details drawer:\n\(app.debugDescription)")
        capture("kind-drawer")
    }

    func testNestedCommentChainRenders() {
        let app = XCUIApplication()
        app.launch()

        let searchTab = app.buttons["tab-search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 40), "tab bar missing:\n\(app.debugDescription)")
        searchTab.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search field missing:\n\(app.debugDescription)")
        field.tap()
        field.typeText(Self.nevent)
        // Do NOT press the search return key: the debounced id-lookup already
        // ran, and a submit triggers a full re-search that keeps the app
        // churning while the thread screen is up.

        // Direct id lookup hits the nevent's relay hints — allow a slow round trip.
        XCTAssertTrue(waitFor(app, containing: "nice dude", timeout: 45),
                      "search result (the tapped comment) never appeared")
        tapElement(app, containing: "nice dude")

        // Give the thread time to re-root at the kind-1 note and stream the
        // comment tree, then photograph it top to bottom. No accessibility
        // queries from here: they starve while the app is busy, and the
        // swipes between captures scroll without needing them.
        Thread.sleep(forTimeInterval: 30)
        capture("nip22-thread-0-top")
        for i in 1...3 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 6)
            capture("nip22-thread-\(i)")
        }
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The first element whose label contains `text`. PostCardView renders
    /// body copy through SwiftUI Texts (`staticTexts`) and UITextView wrappers
    /// (`textViews`) — query those two types specifically, because a
    /// `descendants(.any)` scan over this hierarchy blows Xcode's
    /// snapshot-evaluation timeout.
    private func matches(_ app: XCUIApplication, containing text: String) -> [XCUIElement] {
        let pred = NSPredicate(format: "label CONTAINS %@", text)
        return [app.staticTexts.matching(pred).firstMatch,
                app.textViews.matching(pred).firstMatch]
    }

    /// Poll for `text` on screen. Sparse polling: a failed accessibility
    /// snapshot under load can take 30s to come back.
    private func waitFor(_ app: XCUIApplication, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for element in matches(app, containing: text) where element.exists {
                return true
            }
            Thread.sleep(forTimeInterval: 4)
        }
        return matches(app, containing: text).contains { $0.exists }
    }

    /// Tap the on-screen element containing `text` (see `matches`).
    private func tapElement(_ app: XCUIApplication, containing text: String) {
        for element in matches(app, containing: text) where element.exists {
            if element.isHittable {
                element.tap()
                return
            }
        }
        app.swipeUp()
        matches(app, containing: text).first(where: { $0.exists })?.tap()
    }
}
