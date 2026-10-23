//
//  TonePickerUITests.swift
//  wispUITests
//
//  Drives the revived Android tone picker end to end on the simulator:
//  throwaway-key login → onboarding → drawer → Interface settings →
//  Notification Sounds section → open the tone menu and switch a tone.
//  Screenshots attach at each step so the run can be eyeballed from the
//  result bundle.
//

import XCTest

final class TonePickerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testLoginAndReachTonePicker() throws {
        let app = XCUIApplication()
        app.launch()

        // Splash → nsec login, unless a previous run already left an account.
        if app.buttons["Continue with Nostr"].waitForExistence(timeout: 12) {
            app.buttons["Continue with Nostr"].tap()
            let secure = app.secureTextFields["nsec or npub…"]
            let plain = app.textFields["nsec or npub…"]
            XCTAssertTrue(secure.waitForExistence(timeout: 8) || plain.waitForExistence(timeout: 2))

            let eye = app.buttons.matching(NSPredicate(format: "label CONTAINS 'eye'")).firstMatch
            if eye.exists { eye.tap() }
            let field: XCUIElement = app.textFields["nsec or npub…"].exists
                ? app.textFields["nsec or npub…"]
                : secure
            field.tap()
            field.typeText("0000000000000000000000000000000000000000000000000000000000000001")

            app.buttons["Log In"].tap()
            XCTAssertFalse(app.buttons["Continue with Nostr"].waitForExistence(timeout: 5),
                           "login should dismiss the splash")
        }

        // Onboarding ends in a single Let’s go; wait out the outbox build.
        let letsGo = app.buttons["Let’s go"]
        if letsGo.waitForExistence(timeout: 90) {
            snap(app, "01-onboarding")
            letsGo.tap()
        }

        // Main: the feed top bar’s Gadgets entry is a stable anchor.
        XCTAssertTrue(app.buttons["feed-gadgets-entry"].waitForExistence(timeout: 30),
                      "should reach the main screen")
        sleep(2)
        snap(app, "02-main")

        // The drawer opens from the feed top bar's avatar (there is no
        // edge-swipe open gesture).
        let avatar = app.buttons["feed-avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5), "avatar entry should exist")
        avatar.tap()
        let settingsRow = app.buttons["Settings"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5), "drawer should open")
        var hittable = false
        for _ in 0..<20 {
            if settingsRow.isHittable { hittable = true; break }
            usleep(250_000)
        }
        XCTAssertTrue(hittable, "Settings row should be hittable once the drawer is open")
        snap(app, "03-drawer")

        // Settings row expands the list, Interface opens the settings sheet.
        app.buttons["Settings"].tap()
        let interfaceRow = app.buttons["Interface"]
        XCTAssertTrue(interfaceRow.waitForExistence(timeout: 5), "Interface row should appear")
        interfaceRow.tap()

        // The Notification Sounds section may sit below the fold in the sheet.
        let sectionTitle = app.staticTexts["Notification Sounds"]
        for _ in 0..<6 where !sectionTitle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sectionTitle.waitForExistence(timeout: 5),
                      "Notification Sounds section should be reachable")
        snap(app, "04-interface-sounds")

        // The reply tone label reads one of the tone names — a previous run
        // may have switched it, and the choice persists.
        let toneLabels = ["Oven Ding", "Soda Pop", "Dinner Bell", "Door Bell",
                          "Frying Pan", "Cartoon Bite", "Yum Yum", "Glass Toast", "None (silent)"]
        let current = toneLabels.first { app.staticTexts[$0].firstMatch.exists }
        XCTAssertNotNil(current, "a reply tone label should show")
        // The label lives inside the Menu's own button — tap its center
        // rather than the text element, which isn't hittable itself.
        app.staticTexts[current!].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // The menu lists every tone; pick a different one than was showing.
        let pick = toneLabels.first { $0 != current && app.buttons[$0].firstMatch.exists }
        XCTAssertNotNil(pick, "tone menu should list the Android tones")
        snap(app, "05-tone-menu")

        // Switch the reply tone — also previews it (audio on the sim).
        let pickButton = app.buttons[pick!].firstMatch
        if pickButton.isHittable {
            pickButton.tap()
        } else {
            pickButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.staticTexts[pick!].firstMatch.waitForExistence(timeout: 5),
                      "picking a tone should update the label")
        sleep(1)
        snap(app, "06-tone-switched")
    }
}
