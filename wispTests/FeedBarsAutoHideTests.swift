import Foundation
import SwiftUI
import Testing
@testable import wisp

/// Feed chrome auto-hide gates (`FeedBarsAutoHide`), pinning the rules
/// ported from Android `FeedScreen`'s scroll-direction detector: direction
/// not velocity, the threshold, the ±2× clamp, the stop reset, the at-top
/// force-show, and that only user-style scroll transitions count.
struct FeedBarsAutoHideTests {
    private let t = FeedBarsAutoHide.threshold

    /// A finger on the list, parked away from the top with a baseline.
    private func dragging(at offset: CGFloat = 400) -> FeedBarsAutoHide {
        var hide = FeedBarsAutoHide()
        hide.scrollPhase(.interacting)
        #expect(hide.offsetChanged(offset) == nil, "the baseline event has no delta to judge")
        return hide
    }

    @Test func threshold_isAndroids50pxAt3x() {
        #expect(t == 17)
    }

    @Test func wigglesBelowThreshold_toggleNothing() {
        var hide = dragging()
        #expect(hide.offsetChanged(400 + t - 1) == nil)   // 16 down
        #expect(hide.offsetChanged(400 + 2) == nil)       // 14 back up
        #expect(hide.offsetChanged(400 + t) == nil)       // 15 down: travel 17, not past
        #expect(hide.travel == t)
    }

    @Test func scrollDown_pastThreshold_hides() {
        var hide = dragging()
        #expect(hide.offsetChanged(400 + t) == nil, "exactly the threshold is not past it")
        #expect(hide.offsetChanged(400 + t + 1) == false)
    }

    @Test func scrollUp_pastThreshold_shows() {
        var hide = dragging()
        #expect(hide.offsetChanged(400 + t + 1) == false)
        // Reverse: 18 down on the books, needs 18 + 18 up to cross.
        #expect(hide.offsetChanged(400 + t + 1 - (t + 1)) == nil)
        #expect(hide.offsetChanged(400 - (t + 1)) == true)
    }

    @Test func flingDown_hidesInOneEvent() {
        // Android counts an item-index jump as a whole threshold; with a
        // continuous offset the fling's real distance lands in one event.
        var hide = dragging()
        hide.scrollPhase(.decelerating)
        #expect(hide.offsetChanged(400 + 200) == false)
    }

    @Test func longDrag_cannotStockpile_clampsAtTwiceThreshold() {
        var hide = dragging()
        #expect(hide.offsetChanged(400 + 500) == false)
        #expect(hide.travel == 2 * t)
        // After any amount of scrolling down, 3× the threshold (plus the
        // strict crossing) of upward travel brings the bars back —
        // Android's 150px after a 100px clamp.
        #expect(hide.offsetChanged(900 - t) == nil)
        #expect(hide.offsetChanged(900 - 2 * t) == nil)
        #expect(hide.offsetChanged(900 - 3 * t) == nil, "-17 is not past -17")
        #expect(hide.offsetChanged(900 - 3 * t - 1) == true)
    }

    @Test func stop_resetsAccumulator_keepsBars() {
        var hide = dragging()
        #expect(hide.offsetChanged(410) == nil)
        #expect(hide.travel == 10)
        hide.scrollPhase(.idle)
        #expect(hide.travel == 0)
        #expect(!hide.userScrolling)
        // The next drag starts from zero: 10 more is 10, not 20.
        hide.scrollPhase(.interacting)
        #expect(hide.offsetChanged(420) == nil)
        #expect(hide.travel == 10)
    }

    @Test func atTheVeryTop_forcesShow_andResets() {
        var hide = dragging()
        #expect(hide.offsetChanged(900) == false)
        #expect(hide.offsetChanged(0) == true)
        #expect(hide.travel == 0)
        // The rubber-band dip of a pull-to-refresh is still the top.
        #expect(hide.offsetChanged(-24) == true)
        #expect(hide.offsetChanged(0) == true)
    }

    @Test func programmaticScroll_landsWhereItLands() {
        // Our own `scrollTo` reports `.animating`: the travel does not
        // count, and the bars only change if it lands at the top.
        var hide = dragging()
        hide.scrollPhase(.animating)
        #expect(hide.offsetChanged(400 + 300) == nil)
        #expect(hide.travel == 0)
        #expect(hide.offsetChanged(100) == nil)
        #expect(hide.offsetChanged(0) == true)
    }

    @Test func offsetsAtRest_doNotCount() {
        var hide = FeedBarsAutoHide()
        #expect(hide.offsetChanged(400) == nil)
        #expect(hide.offsetChanged(500) == nil, "a layout shift with no finger down is not a scroll")
        #expect(hide.travel == 0)
    }

    @Test func reset_dropsBaseline_noPhantomDelta() {
        var hide = dragging()
        #expect(hide.offsetChanged(400 + t + 1) == false)
        hide.reset()
        #expect(hide.travel == 0)
        // The incoming body is 600pt further down the page than the
        // outgoing one was: that difference must not read as a scroll.
        #expect(hide.offsetChanged(1000) == nil)
        #expect(hide.travel == 0)
        #expect(hide.offsetChanged(1000 + t + 1) == false)
    }

    @Test func phases_fingerAndFlingAreUserDriven_idleAndAnimatingAreNot() {
        for phase in [ScrollPhase.tracking, .interacting, .decelerating] {
            var hide = FeedBarsAutoHide()
            hide.scrollPhase(phase)
            #expect(hide.userScrolling, "\(phase)")
        }
        for phase in [ScrollPhase.idle, .animating] {
            var hide = FeedBarsAutoHide()
            hide.scrollPhase(.interacting)
            hide.scrollPhase(phase)
            #expect(!hide.userScrolling, "\(phase)")
        }
    }

    @Test func detector_forwardsToTheValue() {
        let detector = FeedBarsScrollDetector()
        detector.scrollPhase(.interacting)
        #expect(detector.offsetChanged(400) == nil)
        #expect(detector.offsetChanged(400 + t + 1) == false)
        #expect(detector.state.travel == t + 1)
        detector.reset()
        #expect(detector.state.travel == 0)
        #expect(detector.offsetChanged(900) == nil)
    }

    /// The restore circle tapped mid-fling: the rest of that fling, however
    /// far it coasts, must not hide the bars again.
    @Test func restored_midFling_leftoverTravelCannotHide() {
        var hide = dragging()
        hide.scrollPhase(.decelerating)
        hide.restored()
        #expect(hide.travel == 0)
        for step in 1...20 {
            #expect(hide.offsetChanged(400 + CGFloat(step) * 30) == nil, "coast step \(step)")
        }
        #expect(hide.travel <= 0, "down travel does not bank while held")
    }

    /// The hold lasts until a new finger: then scrolling down hides again.
    @Test func restored_newTouchClearsHold_thenScrollDownHides() {
        var hide = dragging()
        hide.restored()
        hide.scrollPhase(.idle)
        #expect(hide.holdUntilNewTouch, "the fling ending is not a new touch")
        hide.scrollPhase(.tracking)
        #expect(!hide.holdUntilNewTouch)
        _ = hide.offsetChanged(500)
        #expect(hide.offsetChanged(500 + t + 1) == false)
    }

    /// Held, scrolling up still shows and the top still force-shows.
    @Test func restored_hold_onlyBlocksHiding() {
        var hide = dragging()
        hide.restored()
        #expect(hide.offsetChanged(0) == true)
    }
}
