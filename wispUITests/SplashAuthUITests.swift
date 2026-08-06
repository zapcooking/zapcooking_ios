//
//  SplashAuthUITests.swift
//  wispUITests
//
//  Concern 0.2 — Google Sign-In removed: splash shows Apple + Nostr only,
//  and nsec-paste login still works end to end.
//

import XCTest

final class SplashAuthUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Prefer a clean splash. Parallel clones / prior tests may already have
    /// a saved keychain account — skip rather than fail in that case.
    @MainActor
    private func launchOnSplash() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let apple = app.buttons["Continue with Apple"]
        let nostr = app.buttons["Continue with Nostr"]
        if !apple.waitForExistence(timeout: 12) || !nostr.exists {
            throw XCTSkip("Splash not shown — simulator already has a saved account")
        }
        XCTAssertFalse(app.buttons["Continue with Google"].exists)
        XCTAssertFalse(app.staticTexts["Continue with Google"].exists)
        return app
    }

    @MainActor
    func testNsecPasteLoginFromSplash() throws {
        let app = try launchOnSplash()

        app.buttons["Continue with Nostr"].tap()

        // Splash sheet uses SecureField("nsec or npub…") by default.
        let secure = app.secureTextFields["nsec or npub…"]
        let plain = app.textFields["nsec or npub…"]
        XCTAssertTrue(
            secure.waitForExistence(timeout: 8) || plain.waitForExistence(timeout: 2),
            "nsec field should appear in Continue with Nostr sheet"
        )

        // Reveal so XCTest can type into a normal text field reliably.
        let eye = app.buttons.matching(NSPredicate(format: "label CONTAINS 'eye'")).firstMatch
        if eye.exists { eye.tap() }

        let field: XCUIElement = {
            if app.textFields["nsec or npub…"].exists { return app.textFields["nsec or npub…"] }
            return secure
        }()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Deterministic throwaway key (not a real user). Hex form is accepted by parseNsec.
        field.typeText("0000000000000000000000000000000000000000000000000000000000000001")

        let logIn = app.buttons["Log In"]
        XCTAssertTrue(logIn.waitForExistence(timeout: 5))
        XCTAssertTrue(logIn.isEnabled)
        logIn.tap()

        // After a successful nsec login the splash buttons go away (onboarding or main).
        let stillOnSplash = app.buttons["Continue with Nostr"].waitForExistence(timeout: 3)
        XCTAssertFalse(stillOnSplash, "nsec login should dismiss splash")
    }

    @MainActor
    func testContinueWithAppleLeavesSplash() throws {
        let app = try launchOnSplash()
        app.buttons["Continue with Apple"].tap()

        // Wiring check: AppleAuthView should take over (loading / SIWA / iCloud error).
        // Full create→restore with PIN still needs a real Apple ID + iCloud Keychain
        // on a signed-in device — exercise that manually before merge if SIWA
        // cannot complete in the simulator.
        let progressed =
            app.staticTexts["Signing in with Apple…"].waitForExistence(timeout: 10)
            || app.staticTexts["Checking your iCloud backup…"].waitForExistence(timeout: 2)
            || app.staticTexts["Starting…"].waitForExistence(timeout: 2)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'iCloud' OR label CONTAINS[c] 'Apple' OR label CONTAINS[c] 'PIN' OR label CONTAINS[c] 'recovery'")).firstMatch.waitForExistence(timeout: 8)
            || !app.buttons["Continue with Nostr"].exists

        XCTAssertTrue(progressed, "Continue with Apple should present AppleAuthView / system SIWA")
    }
}
