import Foundation
import SwiftUI

/// Android `FeedScreen` / `OnlyFoodFeedScreen` stick-to-top (unified feed
/// §7), ported as a value so the gates run without a scroll view. Every feed
/// body owns one:
///
/// - `autoFollowTop` starts true. While true and no scroll is in progress, a
///   change at the head of the list re-pins to the newest note.
/// - Any user drag clears it (Android's `collectIsDraggedAsState`).
/// - It resumes only when scrolling settles AND the list is at the very top —
///   contentOffset ≤ 0, not "within a few points" — so a user who is reading
///   is never yanked back up.
///
/// A programmatic scroll (a re-tap, the new-posts pill) reports as
/// `.animating`: it counts as "in progress" and never clears following, so
/// our own scroll to the top settles with following still on — Android's
/// "we never set false here" comment.
nonisolated struct FeedFollowState: Equatable {
    private(set) var autoFollowTop = true
    private(set) var isScrolling = false
    private(set) var isAtTop = true

    /// The head of the list changed. True iff the body should re-pin to the
    /// top: following, and no scroll in progress.
    func shouldRepinOnHeadChange() -> Bool {
        autoFollowTop && !isScrolling
    }

    /// `onScrollPhaseChange`. Drag phases clear following; settling at the
    /// very top resumes it.
    mutating func scrollPhase(isScrolling: Bool, isDragging: Bool) {
        self.isScrolling = isScrolling
        if isDragging { autoFollowTop = false }
        resumeIfSettledAtTop()
    }

    /// `onScrollGeometryChange`'s at-the-very-top bit.
    mutating func atTop(_ atTop: Bool) {
        isAtTop = atTop
        resumeIfSettledAtTop()
    }

    /// Explicit intent to land at the top (feed re-tap, new-posts pill, a
    /// picker selection): follow again, whatever came before.
    mutating func follow() {
        autoFollowTop = true
    }

    private mutating func resumeIfSettledAtTop() {
        if !isScrolling && isAtTop { autoFollowTop = true }
    }
}

extension FeedFollowState {
    /// Maps SwiftUI's phases onto the two bits the state needs. `.tracking`
    /// and `.interacting` are the user's finger; `.decelerating` and
    /// `.animating` are still in progress but not a drag.
    mutating func scrollPhase(_ phase: ScrollPhase) {
        scrollPhase(
            isScrolling: phase != .idle,
            isDragging: phase == .tracking || phase == .interacting
        )
    }
}

/// The one scroll-geometry read a feed body makes, reduced to two bits so
/// `onScrollGeometryChange` fires its action only when either flips —
/// nothing is stored per frame. `nearTop` (8pt slop for rubber-band
/// overshoot) drives the new-posts hold; `atTop` (≤ 0, no slop) is the §7
/// resume condition.
nonisolated struct FeedTopState: Equatable {
    var nearTop: Bool
    var atTop: Bool

    init(offsetY: CGFloat) {
        nearTop = offsetY <= 8
        atTop = offsetY <= 0
    }

    init(nearTop: Bool, atTop: Bool) {
        self.nearTop = nearTop
        self.atTop = atTop
    }
}

/// Android's `prevMode` / `prevFeedType` guard: a kind change counts only
/// against a kind already observed, so the first composition records
/// without re-pinning and a tab re-entry (which re-observes the same kind)
/// keeps the restored scroll position. Only an actual selection changes the
/// observed kind. Main-actor like `FeedKind` itself (its `Equatable` is
/// isolated); only `MainView` and the gates touch it.
struct FeedKindSwitchTracker: Equatable {
    private(set) var previous: FeedKind?

    /// Returns true iff `kind` differs from the kind observed last time.
    mutating func observe(_ kind: FeedKind) -> Bool {
        defer { previous = kind }
        guard let previous else { return false }
        return previous != kind
    }
}
