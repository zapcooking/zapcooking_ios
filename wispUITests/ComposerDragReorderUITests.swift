import XCTest

/// Drag-to-reorder in the composer's attachment strip, driven by real touch
/// events rather than a simulator mouse cursor.
///
/// Launches the app into `ComposerDragHarness` (DEBUG, `-ComposerDragHarness`):
/// the real `ComposeView`, presented as a sheet, with seeded slots A, B, C…,
/// an `harness-order` readout of the view model's slot order and a
/// `harness-trace` of what the gesture did (lift, finger x, move, drop, cancel).
final class ComposerDragReorderUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let app, app.staticTexts["harness-trace"].exists {
            let t = XCTAttachment(string: "\(name)\norder=\(order.label)\ntrace=\(trace)")
            t.name = "trace"
            t.lifetime = .keepAlways
            add(t)
        }
    }

    private func launch(slots: Int = 3, gifs: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = ["-ComposerDragHarness", "-ComposerDragHarnessSlots", "\(slots)",
                               "-ComposerDragHarnessGIFs", gifs ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(order.waitForExistence(timeout: 15), "harness did not come up")
        XCTAssertTrue(cell(slots - 1).waitForExistence(timeout: 5), "cells not exposed:\n\(app.debugDescription)")
    }

    private var order: XCUIElement { app.staticTexts["harness-order"] }
    private var trace: String { app.staticTexts["harness-trace"].label }

    /// The thumbnail image of slot `i`. The cell's identifier propagates to
    /// all three of its children — the alt chip, the remove button and the
    /// image — and `firstMatch` over `.any` resolves to the alt chip, a
    /// 38x17 button. Pressing that long-presses a Button, which is not a
    /// reorder. Target the image explicitly.
    private func cell(_ i: Int) -> XCUIElement {
        app.images["attachment-cell-\(i)"].firstMatch
    }

    private func removeButton(_ i: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "attachment-cell-\(i)", "Remove attachment"
        )).firstMatch
    }

    /// Center-ish of a cell, below the alt chip (top-leading) and the
    /// remove button (top-trailing), so the press lands on the thumbnail.
    private func grip(_ i: Int, dx: CGFloat = 0.5) -> XCUICoordinate {
        cell(i).coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.65))
    }

    /// Press slot `i`, drift 8pt over ~0.4s like an unsteady hand, then
    /// hold still: the hold completes mid-drift.
    private func wobblyHold(_ i: Int) {
        grip(i).press(forDuration: 0.1,
                      thenDragTo: grip(i).withOffset(CGVector(dx: 8, dy: 3)),
                      withVelocity: XCUIGestureVelocity(rawValue: 20),
                      thenHoldForDuration: 0.6)
    }

    private func holdAndDrag(_ i: Int, dx: CGFloat = 0.5, to target: XCUICoordinate) {
        grip(i, dx: dx).press(forDuration: 0.8, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func waitForOrder(_ expected: String, timeout: TimeInterval = 3) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: order)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Hold the first thumbnail, drag it past the last one, let go.
    func testHoldAndDragMovesFirstSlotToTheEnd() {
        launch()
        grip(0).press(forDuration: 0.8,
                      thenDragTo: grip(2, dx: 0.85),
                      withVelocity: .slow,
                      thenHoldForDuration: 0.3)

        XCTAssertTrue(waitForOrder("order:B,C,A"),
                      "expected B,C,A after dragging A to the end, got \(order.label). trace: \(trace)")
    }

    /// Hold the first thumbnail, drag it onto its neighbor, let go: one
    /// slot, not the whole row. The drag used to take the translation raw,
    /// discarding each splice's rebase, so the first midline crossing
    /// re-crossed the next one on the following frame and any drag
    /// cascaded to the end — B,C,A here. The two end-to-end tests could
    /// never see it: the end is exactly where the cascade lands.
    func testHoldAndDragMovesOneSlot() {
        launch()
        grip(0).press(forDuration: 0.8,
                      thenDragTo: grip(1),
                      withVelocity: .slow,
                      thenHoldForDuration: 0.3)

        XCTAssertTrue(waitForOrder("order:B,A,C"),
                      "expected B,A,C after dragging A onto B, got \(order.label). trace: \(trace)")
    }

    /// Hold the last thumbnail, drag it to the front.
    func testHoldAndDragMovesLastSlotToTheFront() {
        launch()
        grip(2).press(forDuration: 0.8,
                      thenDragTo: grip(0, dx: 0.15),
                      withVelocity: .slow,
                      thenHoldForDuration: 0.3)

        XCTAssertTrue(waitForOrder("order:C,A,B"),
                      "expected C,A,B after dragging C to the front, got \(order.label). trace: \(trace)")
    }

    /// The cell must not look grabbed until it can actually be dragged.
    ///
    /// The lift used to fire on the long press's `.first` phase, which is
    /// touch-down: the thumbnail scaled up and buzzed the instant it was
    /// touched, while the drag only went live 0.4s later. So it looked
    /// grabbed, you moved — naturally, especially with a mouse — the press
    /// failed on the movement, and the cell dropped back. The reorder
    /// "did not work at all" because it invited the one gesture that
    /// cancels it. A press shorter than the hold must not lift.
    func testShortPressDoesNotLift() {
        launch()
        grip(1).press(forDuration: 0.2)
        XCTAssertFalse(trace.contains("lift"),
                       "a 0.2s press lifted the cell before the 0.4s hold completed. trace: \(trace)")

        // Control: the same cell does lift once the hold completes, so the
        // assertion above can't pass just because the touch missed.
        grip(1).press(forDuration: 0.8)
        XCTAssertTrue(trace.contains("lift i=1"), "a 0.8s hold never lifted the cell. trace: \(trace)")
        XCTAssertEqual(order.label, "order:A,B,C")
    }

    /// A drag with no hold is not a reorder. Guards against "fixing" the
    /// gesture by letting any touch-and-move shuffle slots.
    func testDragWithoutHoldDoesNotReorder() {
        launch()
        grip(0).press(forDuration: 0.05, thenDragTo: grip(2, dx: 0.85))

        XCTAssertFalse(waitForOrder("order:B,C,A", timeout: 1.5),
                       "a quick drag with no hold reordered the strip")
        XCTAssertEqual(order.label, "order:A,B,C")
        // Three slots fit, so the row has nowhere to go: it must not
        // rubber-band under the drag either.
        XCTAssertFalse(trace.contains("scroll"), "the row moved under a drag. trace: \(trace)")
    }

    /// Real hands wobble. A reorder drag that drifts 40pt down must keep
    /// reordering: the lifted cell owns the touch, so neither the
    /// composer's vertical scroll nor the sheet's swipe-to-dismiss may
    /// take it over mid-drag.
    func testDiagonalDragStillReorders() {
        launch()
        grip(0).press(forDuration: 0.8,
                      thenDragTo: grip(2, dx: 0.85).withOffset(CGVector(dx: 0, dy: 40)),
                      withVelocity: .slow,
                      thenHoldForDuration: 0.3)

        XCTAssertTrue(waitForOrder("order:B,C,A"),
                      "a drag with vertical drift did not reorder, got \(order.label). trace: \(trace)")
    }

    /// Six slots overflow the strip, so it genuinely scrolls. A hold-drag
    /// must still reorder, and a plain swipe afterwards must still scroll:
    /// the lift disables scrolling, and the drop has to give it back.
    func testOverflowingStripReordersAndStillScrolls() {
        launch(slots: 6)
        grip(0).press(forDuration: 0.8,
                      thenDragTo: grip(2, dx: 0.85),
                      withVelocity: .slow,
                      thenHoldForDuration: 0.3)
        XCTAssertTrue(waitForOrder("order:B,C,A,D,E,F"),
                      "expected B,C,A,D,E,F, got \(order.label). trace: \(trace)")

        let restX = cell(0).frame.minX
        grip(3).press(forDuration: 0.05, thenDragTo: grip(0), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(cell(0).frame.minX, restX - 40,
                          "a plain swipe no longer scrolls the strip after a reorder. trace: \(trace)")
        XCTAssertEqual(order.label, "order:B,C,A,D,E,F")
    }

    /// A plain swipe on the thumbnails scrolls an overflowing strip. The
    /// reorder gesture used to be attached exclusively, and an exclusive
    /// gesture holding a DragGesture locks the enclosing scroll view's pan
    /// out: with more slots than fit, only the gaps between thumbnails
    /// scrolled the row.
    func testSwipeScrollsAnOverflowingStrip() {
        launch(slots: 6)
        let restX = cell(0).frame.minX
        grip(3).press(forDuration: 0.05, thenDragTo: grip(0), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(cell(0).frame.minX, restX - 40,
                          "a swipe on the thumbnails did not scroll the strip. trace: \(trace)")
        XCTAssertTrue(trace.contains("scroll"), "no scroll was traced. trace: \(trace)")
        XCTAssertFalse(trace.contains("lift"), "a swipe lifted a cell. trace: \(trace)")
        XCTAssertEqual(order.label, "order:A,B,C,D,E,F")
    }

    /// A hold that wanders a few points — a finger, or a simulator cursor —
    /// still grabs, and the row stays put while it does. The hold used to
    /// race the scroll pan: the pan recognized on its own few points of
    /// hysteresis, well inside the hold's allowance, and the whole row
    /// moved instead of the thumbnail.
    func testWobblyHoldStillGrabs() {
        launch()
        wobblyHold(1)
        XCTAssertTrue(trace.contains("lift i=1"), "a hold that drifted 8pt did not grab. trace: \(trace)")
        XCTAssertFalse(trace.contains("scroll"), "the row moved during the hold. trace: \(trace)")
    }

    /// Same, where the strip overflows and a real scroll pan is in play.
    func testWobblyHoldGrabsInAnOverflowingStrip() {
        launch(slots: 6)
        wobblyHold(1)
        XCTAssertTrue(trace.contains("lift i=1"), "a hold that drifted 8pt did not grab. trace: \(trace)")
        XCTAssertFalse(trace.contains("scroll"), "the strip scrolled during the hold. trace: \(trace)")
        XCTAssertEqual(cell(0).frame.minX, 12, "the strip scrolled during the hold")
    }

    /// The whole thumbnail is the handle, the ALT chip included.
    func testHoldOnTheAltChipGrabs() {
        launch()
        cell(1).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.12)).press(forDuration: 0.8)
        XCTAssertTrue(trace.contains("lift i=1"), "a hold on the ALT chip did not grab. trace: \(trace)")
        XCTAssertFalse(app.navigationBars["Description"].waitForExistence(timeout: 1), "the hold opened the alt editor")
    }

    /// Holding the ✕ grabs rather than removes; tapping it still removes.
    func testHoldOnTheRemoveButtonGrabsWithoutRemoving() {
        launch()
        removeButton(1).press(forDuration: 0.8)
        XCTAssertTrue(trace.contains("lift i=1"), "a hold on the remove button did not grab. trace: \(trace)")
        XCTAssertEqual(order.label, "order:A,B,C", "a hold on the remove button removed the slot")
        removeButton(1).tap()
        XCTAssertTrue(waitForOrder("order:A,C"), "tapping the remove button no longer removes, got \(order.label)")
    }

    /// Tapping the ALT chip still opens the alt editor.
    func testTapOnTheAltChipOpensTheEditor() {
        launch()
        cell(1).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.12)).tap()
        XCTAssertTrue(app.navigationBars["Description"].waitForExistence(timeout: 3),
                      "tapping the ALT chip did not open the alt editor")
        XCTAssertFalse(trace.contains("lift"), "a tap lifted the cell. trace: \(trace)")
    }

    /// Holding anywhere that isn't a thumbnail grabs nothing.
    func testHoldOutsideTheCellsGrabsNothing() {
        launch()
        let drawer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "added to the end of your post")).firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "attachment drawer not found")
        drawer.press(forDuration: 0.8)
        cell(1).coordinate(withNormalizedOffset: CGVector(dx: 1.4, dy: 1.6)).press(forDuration: 0.8)
        XCTAssertFalse(trace.contains("lift"), "a hold outside the thumbnails lifted one. trace: \(trace)")
    }

    /// Drag after drag, different thumbnails each time, the way a person
    /// actually sorts five photos. Every earlier test dragged once per
    /// launch, so nothing checked that a cell still drags correctly after
    /// a reorder has moved it.
    func testSequentialDragsAcrossFiveSlots() {
        launch(slots: 5)
        holdAndDrag(3, to: grip(1))
        XCTAssertTrue(waitForOrder("order:A,D,B,C,E"), "D onto slot 1: got \(order.label). trace: \(trace)")
        holdAndDrag(0, to: grip(2))
        XCTAssertTrue(waitForOrder("order:D,B,A,C,E"), "A onto slot 2: got \(order.label). trace: \(trace)")
        holdAndDrag(3, to: grip(0, dx: 0.15))
        XCTAssertTrue(waitForOrder("order:C,D,B,A,E"), "C to the front: got \(order.label). trace: \(trace)")
        holdAndDrag(4, dx: 0.15, to: grip(2, dx: 0.3))
        XCTAssertTrue(waitForOrder("order:C,D,E,B,A"), "E onto slot 2: got \(order.label). trace: \(trace)")
        holdAndDrag(1, to: grip(3))
        XCTAssertTrue(waitForOrder("order:C,E,B,D,A"), "D onto slot 3: got \(order.label). trace: \(trace)")
    }

    /// A drag after the strip has been scrolled: slot positions move with
    /// the scroll, and the lift must see where the cells are now.
    func testDragAfterScrollingTheStrip() {
        launch(slots: 6)
        grip(3).press(forDuration: 0.05, thenDragTo: grip(0), withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(cell(0).frame.minX, -100, "the strip did not scroll to the end")
        holdAndDrag(5, to: grip(3))
        XCTAssertTrue(waitForOrder("order:A,B,C,F,D,E"), "F onto slot 3 after scrolling: got \(order.label). trace: \(trace)")
        holdAndDrag(2, to: grip(4))
        XCTAssertTrue(waitForOrder("order:A,B,F,D,C,E"), "C onto slot 4 after scrolling: got \(order.label). trace: \(trace)")
    }

    /// GIF thumbnails drag like photos. The strip draws a GIF with a UIKit
    /// `UIImageView` (`AnimatedImageRenderer`), not a SwiftUI `Image`, and
    /// a thumbnail drawn that way never saw the hold: in a composer full of
    /// GIFs, only the one video poster could be dragged.
    func testGIFThumbnailsDrag() {
        launch(slots: 5, gifs: true)
        holdAndDrag(1, to: grip(3))
        XCTAssertTrue(waitForOrder("order:A,C,D,B,E"), "B onto slot 3: got \(order.label). trace: \(trace)")
        holdAndDrag(3, to: grip(0, dx: 0.15))
        XCTAssertTrue(waitForOrder("order:B,A,C,D,E"), "B to the front: got \(order.label). trace: \(trace)")
    }

    /// Removing a slot must not leave a phantom position behind. Cell
    /// positions are keyed by index and the removed cell's x lingered, so a
    /// drag past the new end "moved" onto a slot that no longer existed:
    /// the splice was refused, the lifted cell dropped out from under the
    /// finger, and the rest of the drag steered a ghost.
    func testRemovedSlotLeavesNoPhantomPosition() {
        launch(slots: 4)
        removeButton(3).tap()
        XCTAssertTrue(waitForOrder("order:A,B,C"), "the remove button did not remove D, got \(order.label)")

        grip(2).press(forDuration: 0.8,
                      thenDragTo: grip(2).withOffset(CGVector(dx: 150, dy: 0)),
                      withVelocity: .slow,
                      thenHoldForDuration: 0.3)

        XCTAssertTrue(trace.contains("lift i=2"), "the hold never lifted C. trace: \(trace)")
        XCTAssertFalse(trace.contains("move 2>3"),
                       "the drag spliced onto the removed slot's position. trace: \(trace)")
        XCTAssertEqual(order.label, "order:A,B,C")
    }
}
