import SwiftUI
import UIKit

/// Feed chrome auto-hide, ported from Android
/// (`zapcooking/zap_cooking_android#286`, `FeedScreen`'s scroll-direction
/// detector): scrolling the feed down past a threshold collapses the top
/// header and the tab bar together; scrolling up past it, or reaching the
/// top, brings them back. The decision is a value, like `FeedFollowState`,
/// so the gates run without a scroll view.
///
/// It is direction, not velocity: per-update deltas accumulate and the bars
/// flip only once the accumulator crosses the threshold, so tiny wiggles
/// toggle nothing and a flick behaves like a slow drag of the same
/// distance. Android reads the first visible item (index + offset in item)
/// because that is what `LazyListState` exposes, and counts an index change
/// as a whole threshold only because the offset resets at an item boundary.
/// `contentOffset.y` is continuous, so plain deltas carry the same behavior
/// — a fling covers the threshold within a frame or two and hides at once —
/// with no distance to reconstruct.
nonisolated struct FeedBarsAutoHide: Equatable {
    /// Android ships 50 raw pixels ≈ 17pt at 3× density.
    static let threshold: CGFloat = 17

    /// Cumulative travel since the last reset, positive downward. Clamped at
    /// ±2× the threshold so a long drag cannot stockpile (Android's
    /// `coerceIn`): after any amount of scrolling down, 3× the threshold of
    /// upward travel brings the bars back.
    private(set) var travel: CGFloat = 0
    private(set) var userScrolling = false
    /// Set by `restored()` (the restore circle's tap): hiding is held off
    /// until a new finger touches the list, so whatever is left of the
    /// gesture the tap interrupted cannot collapse the bars it just
    /// brought back.
    private(set) var holdUntilNewTouch = false
    private var previousOffset: CGFloat?

    /// `onScrollPhaseChange`. Finger-driven phases and the fling they
    /// release into accumulate; `.idle` and `.animating` (our own `scrollTo`)
    /// reset the accumulator but leave the bars where they are — only
    /// user-style transitions matter, a programmatic jump simply lands
    /// wherever it lands (the top shows by `offsetChanged`).
    mutating func scrollPhase(userDriven: Bool, newTouch: Bool = false) {
        userScrolling = userDriven
        if !userDriven { travel = 0 }
        if newTouch { holdUntilNewTouch = false }
    }

    /// The bars were brought back by a tap, not a scroll: start the count
    /// over and hold hiding until the next touch (`holdUntilNewTouch`).
    mutating func restored() {
        travel = 0
        holdUntilNewTouch = true
    }

    /// `onScrollGeometryChange`, once per offset change. The caller passes
    /// the content-inset-adjusted offset, so 0 is the very top of the list
    /// (SwiftUI reports rest-at-top as the negative of the top inset).
    /// Returns the visibility the bars should take, or nil to leave them as
    /// they are. The caller flips the shared bit only when the verdict
    /// differs from it, so the per-frame path writes no observable state.
    mutating func offsetChanged(_ offsetY: CGFloat) -> Bool? {
        defer { previousOffset = offsetY }
        // The very top, including the rubber-band dip of a pull-to-refresh:
        // force-show and start over.
        if offsetY <= 0 {
            travel = 0
            return true
        }
        guard userScrolling, let previousOffset else { return nil }
        let clamp = 2 * Self.threshold
        travel = min(max(travel + offsetY - previousOffset, -clamp), clamp)
        if holdUntilNewTouch {
            travel = min(travel, 0)
            return nil
        }
        if travel > Self.threshold { return false }
        if travel < -Self.threshold { return true }
        return nil
    }

    /// Drop the baseline so the next offset event records where the list is
    /// without a phantom delta: on a feed-body swap (OnlyFood ↔ general),
    /// each body keeps its own scroll position and the incoming one must
    /// not diff against the offset it had when it was last visible; and on
    /// every re-entry to the feed, which starts with the bars up anyway.
    mutating func reset() {
        travel = 0
        previousOffset = nil
    }
}

nonisolated extension FeedBarsAutoHide {
    /// `.tracking` and `.interacting` are the finger, `.decelerating` the
    /// fling it released; `.animating` is our own scroll to the top.
    mutating func scrollPhase(_ phase: ScrollPhase) {
        let userDriven: Bool
        switch phase {
        case .tracking, .interacting, .decelerating: userDriven = true
        case .idle, .animating: userDriven = false
        @unknown default: userDriven = false
        }
        scrollPhase(userDriven: userDriven, newTouch: phase == .tracking || phase == .interacting)
    }
}

/// The per-frame home of a `FeedBarsAutoHide` for one feed body. A plain
/// class — not `@Observable`, not a `@State` value — so the geometry
/// callback can advance it on every scroll frame without invalidating
/// `MainView`'s body: the feed's scroll hot path stores nothing SwiftUI
/// tracks (see `FeedTopState`). The view model's `barsVisible` is the only
/// state a flip touches, and only when the verdict differs from it.
nonisolated final class FeedBarsScrollDetector {
    private(set) var state = FeedBarsAutoHide()
    /// The body's backing scroll view, for stopping a fling on restore.
    @MainActor let stopper = FeedScrollStopper()

    func scrollPhase(_ phase: ScrollPhase) { state.scrollPhase(phase) }
    func offsetChanged(_ offsetY: CGFloat) -> Bool? { state.offsetChanged(offsetY) }
    func reset() { state.reset() }
    func restored() { state.restored() }
}

extension Animation {
    /// Android's `tween(200)` (FastOutSlowIn) for the expand / shrink and
    /// the crossfade of both bars.
    static let feedBarsCollapse = Animation.easeInOut(duration: 0.2)
}

/// The persistent part of the chrome — what stays painted when the bars
/// are down. Only the header's control row and the tab row collapse; the
/// safe-area reserves and these never do.
enum FeedBarsLayout {
    /// Android's 10dp spacer between the status-bar inset and the header
    /// row, so the collapsed chrome never hugs the clock.
    static let topBreather: CGFloat = 10

    /// The 0.5pt separator at half the normal separator color that marks
    /// where the chrome starts — the bottom of the top strip, the top of
    /// the bottom strip — bars up or down.
    static var hairline: some View {
        Rectangle()
            .fill(Color.wispSurfaceVariant.opacity(0.5))
            .frame(height: 0.5)
    }
}

/// Android's `AnimatedVisibility(expandVertically + fadeIn / shrinkVertically
/// + fadeOut)` for the two bars: `content` keeps its full size and is clipped
/// by a frame whose height animates to zero, anchored at the edge the bar
/// shrinks toward — the header at its bottom edge (up into the status-bar
/// strip), the tab row at its top edge (down into the home-indicator area).
/// Because it is the frame that shrinks, the layout around it follows the
/// animation: the safe-area inset above the feed and the room handed back
/// below it track the bar height in lockstep instead of jumping.
///
/// `visible` must change inside the caller's `withAnimation`. The height is
/// measured, not a constant, so a bar can gain or lose a control (the
/// Cheffy gate) without drifting from a number; until the first measurement
/// the frame is unconstrained, so the first paint is the full bar, never a
/// flash of nothing.
/// The edge a `CollapsingBar` shrinks toward.
enum CollapsingBarAnchor {
    /// The visible sliver keeps the top of the content; the bar shrinks
    /// downward (the tab row, into the home-indicator area).
    case top
    /// The visible sliver keeps the bottom of the content; the bar shrinks
    /// upward (the header row, into the status-bar strip).
    case bottom
}

struct CollapsingBar<Content: View>: View {
    let visible: Bool
    let anchor: CollapsingBarAnchor
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat?

    var body: some View {
        content()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, height in
                // A collapsed frame proposes zero height to the content;
                // today's bars are rigid rows and keep their natural size,
                // but only a real measurement is ever recorded.
                if height > 0 { contentHeight = height }
            }
            .frame(height: frameHeight, alignment: anchor == .top ? .top : .bottom)
            .clipShape(AnchoredClip(anchor: anchor))
            .opacity(visible || contentHeight == nil ? 1 : 0)
            // Scoped to `visible` so flips that arrive outside a caller's
            // `withAnimation` (a route pushed while the bars are down shows
            // the tab bar again) animate the same way, while measurement
            // settling catches nothing.
            .animation(.feedBarsCollapse, value: visible)
            // A clip does not stop hits: collapsed, the full-size content
            // still sits (invisibly) over the rows next to the frame.
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    private var frameHeight: CGFloat? {
        guard let contentHeight else { return nil }
        return visible ? contentHeight : 0
    }
}

/// The clip for a `CollapsingBar`: the animated frame on the shrinking
/// side, open on the anchored side — so the collapse cuts the content off
/// where the frame ends while anything the bar draws past its anchored edge
/// on purpose (the zap burst spilling above the tab row) keeps spilling.
private struct AnchoredClip: Shape {
    let anchor: CollapsingBarAnchor
    /// Comfortably past the burst's 120pt canvas.
    private let overflow: CGFloat = 200

    func path(in rect: CGRect) -> Path {
        var open = rect
        switch anchor {
        case .top:
            open.origin.y -= overflow
            open.size.height += overflow
        case .bottom:
            open.size.height += overflow
        }
        return Path(open)
    }
}

/// The minimized tab bar: while the feed's bars are collapsed, a small
/// circle bottom-left (opposite the compose FAB, centers level) shows a
/// generic menu glyph and brings both bars back on tap — iOS 26's minimized
/// tab bar pattern, since the custom bar doesn't get it for free. It carries
/// one unread dot for Messages / Notifications, whose own dots go away with
/// the tab row. It restores the bars; it never switches tabs. Surface-variant
/// fill so it reads apart from both the feed and the accent-filled FAB.
struct FeedBarsRestoreChip: View {
    let hasUnread: Bool
    let unreadColor: Color
    let action: () -> Void

    static let size: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.wispOnSurface)
                .frame(width: Self.size, height: Self.size)
                .background(Color.wispSurfaceVariant, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle()
                            .fill(unreadColor)
                            .frame(width: 8, height: 8)
                            .offset(x: -4, y: 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasUnread ? "Show tab bar, unread activity" : "Show tab bar")
        .accessibilityIdentifier("feed-bars-restore")
    }
}

/// Stops a coasting feed list. SwiftUI has no API for halting deceleration
/// (disabling scrolling for a frame does not do it), so this holds the
/// body's backing `UIScrollView` — found by `FeedScrollStopperAnchor` — and
/// does what a tap on the list does: pin the offset where it is.
@MainActor
final class FeedScrollStopper {
    weak var scrollView: UIScrollView?

    func stop() {
        guard let scrollView, scrollView.isDecelerating else { return }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
    }
}

/// A zero-size view placed inside a feed body's scroll content; once in a
/// window it walks up to the enclosing `UIScrollView` and hands it to the
/// stopper.
struct FeedScrollStopperAnchor: UIViewRepresentable {
    let stopper: FeedScrollStopper

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.stopper = stopper
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.stopper = stopper
    }

    final class FinderView: UIView {
        weak var stopper: FeedScrollStopper?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            if let scrollView = view as? UIScrollView { stopper?.scrollView = scrollView }
        }
    }
}
