import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// Unified-feed PR 7 gates (§7): the stick-to-top state machine ported
/// from Android's `autoFollowTop`, the `prevMode` guard on the picker, the
/// optimistic self-insert, and — hosted in a real window and measured, not
/// assumed — that keeping both feed bodies mounted preserves OnlyFood's
/// scroll position across a kind switch while the hidden body does no row
/// work.
@MainActor
struct FeedStickToTopTests {

    // MARK: - §7 state machine

    @Test func headChange_whileFollowingAndSettled_repins() {
        var follow = FeedFollowState()
        #expect(follow.autoFollowTop)
        #expect(follow.shouldRepinOnHeadChange())
        // A scroll in progress — even our own programmatic one — defers the
        // re-pin; it never clears following.
        follow.scrollPhase(.animating)
        #expect(follow.autoFollowTop)
        #expect(!follow.shouldRepinOnHeadChange())
        follow.scrollPhase(.idle)
        #expect(follow.shouldRepinOnHeadChange())
    }

    @Test func headChange_afterUserDrag_doesNotRepin() {
        for drag in [ScrollPhase.tracking, .interacting] {
            var follow = FeedFollowState()
            follow.scrollPhase(drag)
            #expect(!follow.autoFollowTop, "\(drag)")
            follow.atTop(false)
            follow.scrollPhase(.decelerating)
            follow.scrollPhase(.idle)
            // Settled away from the top: still not following.
            #expect(!follow.autoFollowTop, "\(drag)")
            #expect(!follow.shouldRepinOnHeadChange(), "\(drag)")
        }
    }

    @Test func follow_resumesOnlyWhenSettledAtTheVeryTop_notNearIt() {
        var follow = FeedFollowState()
        follow.scrollPhase(.tracking)
        follow.atTop(false)
        follow.scrollPhase(.idle)
        #expect(!follow.autoFollowTop)

        // Within the pill's 8pt slop is "near", not "at": no resume.
        let near = FeedTopState(offsetY: 4)
        #expect(near.nearTop && !near.atTop)
        follow.atTop(near.atTop)
        #expect(!follow.autoFollowTop)

        // At the very top but still moving: not yet.
        follow.scrollPhase(.decelerating)
        follow.atTop(FeedTopState(offsetY: 0).atTop)
        #expect(!follow.autoFollowTop)

        // Settled at the very top: following again. Rubber-band overshoot
        // (negative offset) is also "at".
        follow.scrollPhase(.idle)
        #expect(follow.autoFollowTop)
        #expect(FeedTopState(offsetY: -12).atTop)
        #expect(!FeedTopState(offsetY: 9).nearTop)
    }

    @Test func retapAndPill_followAgain_andNeverFightAutoFollow() {
        var follow = FeedFollowState()
        follow.scrollPhase(.tracking)
        follow.atTop(false)
        follow.scrollPhase(.idle)
        #expect(!follow.autoFollowTop)
        // Re-tap / pill: explicit intent to land at the top → follow, then
        // the animated scroll settles at the top and keeps it on.
        follow.follow()
        #expect(follow.autoFollowTop)
        follow.scrollPhase(.animating)
        #expect(follow.autoFollowTop)
        follow.atTop(true)
        follow.scrollPhase(.idle)
        #expect(follow.autoFollowTop)
        #expect(follow.shouldRepinOnHeadChange())
    }

    // MARK: - §7 picker (Android's prevMode)

    @Test func pickerSelection_repins_firstCompositionAndTabReentryDoNot() {
        var tracker = FeedKindSwitchTracker()
        // First composition: the landing kind is recorded, nothing re-pins.
        #expect(FeedTabRouting.repinTarget(afterObserving: .onlyFood, tracker: &tracker) == nil)
        // Tab re-entry re-observes the same kind: nothing.
        #expect(FeedTabRouting.repinTarget(afterObserving: .onlyFood, tracker: &tracker) == nil)
        // An actual selection of a general kind re-pins the general body.
        #expect(FeedTabRouting.repinTarget(afterObserving: .follows, tracker: &tracker) == .general)
        #expect(FeedTabRouting.repinTarget(afterObserving: .follows, tracker: &tracker) == nil)
        #expect(FeedTabRouting.repinTarget(afterObserving: .extendedNetwork, tracker: &tracker) == .general)
        // Back to OnlyFood: its list is the one the user left, so the body
        // restores the position instead of re-pinning (the PR 2 regression).
        #expect(FeedTabRouting.repinTarget(afterObserving: .onlyFood, tracker: &tracker) == nil)

        // The tracker itself, on a general landing.
        var fromFollows = FeedKindSwitchTracker()
        let first = fromFollows.observe(.follows)
        let reentry = fromFollows.observe(.follows)
        let picked = fromFollows.observe(.onlyFood)
        #expect(!first)
        #expect(!reentry)
        #expect(picked)
    }

    // MARK: - §7 optimistic self-insert

    private let pubkey = String(repeating: "a", count: 64)

    private func food(id: String, pubkey: String? = nil, createdAt: Int) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: pubkey ?? String(repeating: "b", count: 64),
            kind: 1,
            createdAt: createdAt,
            tags: [["t", "foodstr"]],
            content: "yummy",
            sig: String(repeating: "0", count: 128)
        )
    }

    private func muteOnlyFilter() -> OnlyFoodFilter {
        OnlyFoodFilter(
            nowSeconds: { 2_000_000 },
            blockedPubkeys: OnlyFoodFilter.blockedPubkeys,
            isUserBlocked: { _ in false },
            containsMutedWord: { _ in false },
            isThreadMuted: { _ in false },
            isDeleted: { _ in false },
            isWotFiltered: { _ in false }
        )
    }

    @Test func optimisticSelfInsert_whileScrolledDown_doesNotRepin() async {
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                OnlyFoodQueryResult(
                    events: [self.food(id: "g2", createdAt: 200), self.food(id: "g1", createdAt: 100)],
                    connected: true, anySent: true, eoseFired: true
                )
            },
            seedCache: { [] },
            persist: { _ in }
        )
        await vm.startAndWait()
        #expect(vm.notes.first?.id == "g2")

        // The user scrolled down to read.
        var follow = FeedFollowState()
        follow.scrollPhase(.tracking)
        follow.atTop(false)
        follow.scrollPhase(.idle)

        // Their own post lands at the head — the same signal the body's
        // head-change observer sees — and must not re-pin.
        let mine = food(id: "mine", pubkey: pubkey, createdAt: 300)
        #expect(vm.insertOwnPublished(mine))
        #expect(vm.notes.first?.id == "mine")
        #expect(!follow.shouldRepinOnHeadChange())

        // Parked at the top and following, the same insert does re-pin.
        var parked = FeedFollowState()
        #expect(parked.shouldRepinOnHeadChange())
        parked.scrollPhase(.idle)
        #expect(parked.shouldRepinOnHeadChange())
    }

    @Test func pagePrefetchDistance_staysSix() {
        #expect(OnlyFoodFeedViewModel.loadMorePrefetch == 6)
    }

    // MARK: - The PR 2 regression, hosted and measured

    @Test func kindSwitch_awayFromOnlyFoodAndBack_restoresScrollPosition() {
        let model = HostModel()
        let host = Host(KeptHarness(model: model))
        defer { host.tearDown() }
        host.pump(0.5)
        guard let onlyFood = host.onlyFoodScrollView() else {
            Issue.record("OnlyFood list did not lay out: \(host.scrollViews().map(\.contentSize))")
            return
        }
        onlyFood.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        host.pump(0.3)
        #expect(onlyFood.contentOffset.y == 1200)

        model.showOnlyFood = false   // pick Follows
        host.pump(0.5)
        #expect(host.generalScrollView() != nil, "general body mounted")
        model.showOnlyFood = true    // pick OnlyFood again
        host.pump(0.5)

        let back = host.onlyFoodScrollView()
        #expect(back === onlyFood, "same ScrollView survives the switch")
        #expect(abs((back?.contentOffset.y ?? 0) - 1200) < 1, "offset \(String(describing: back?.contentOffset.y))")
    }

    /// The control: the `@ViewBuilder` switch `feedContent` used to be loses
    /// the position — this is what the fix is measured against.
    @Test func viewBuilderSwitch_losesScrollPosition_theRegression() {
        let model = HostModel()
        let host = Host(SwitchHarness(model: model))
        defer { host.tearDown() }
        host.pump(0.5)
        guard let onlyFood = host.onlyFoodScrollView() else {
            Issue.record("OnlyFood list did not lay out")
            return
        }
        onlyFood.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        host.pump(0.3)
        model.showOnlyFood = false
        host.pump(0.5)
        model.showOnlyFood = true
        host.pump(0.5)
        let back = host.onlyFoodScrollView()
        #expect(back !== onlyFood, "the switch rebuilt the ScrollView")
        #expect((back?.contentOffset.y ?? 0) < 1, "offset \(String(describing: back?.contentOffset.y))")
    }

    /// What the hidden body costs: no meaningful row work while the visible
    /// body scrolls (measured 0; the gate allows a viewport's worth), and a
    /// viewport's worth at most (not the whole list) when its own data
    /// changes off-screen.
    @Test func hiddenBody_doesNoRowWorkWhileTheVisibleBodyScrolls() {
        let model = HostModel()
        let host = Host(KeptHarness(model: model))
        defer { host.tearDown() }
        host.pump(0.5)
        model.showOnlyFood = false   // OnlyFood stays mounted, hidden
        host.pump(0.5)
        guard let general = host.generalScrollView(), host.onlyFoodScrollView() != nil else {
            Issue.record("bodies did not lay out: \(host.scrollViews().map(\.contentSize))")
            return
        }

        let hiddenBefore = model.onlyFoodCounter.evaluations
        let visibleBefore = model.generalCounter.evaluations
        for y in stride(from: 200, through: 2400, by: 200) {
            general.setContentOffset(CGPoint(x: 0, y: CGFloat(y)), animated: false)
            host.pump(0.05)
        }
        host.pump(0.3)
        let hiddenDuringScroll = model.onlyFoodCounter.evaluations - hiddenBefore
        let visibleDuringScroll = model.generalCounter.evaluations - visibleBefore
        // A hidden body that were laid out per scroll event would evaluate
        // a viewport's worth of rows on every step (the visible body shows
        // the scale: 25 over twelve steps). Allow up to one viewport of
        // incidental evaluations so a SwiftUI version that touches a row or
        // two does not fail the gate; the measurement is printed below.
        let viewportRows = Int((844.0 / 100.0).rounded(.up))
        #expect(hiddenDuringScroll <= viewportRows, "hidden body evaluated \(hiddenDuringScroll) rows while the visible one scrolled")
        #expect(visibleDuringScroll > 0, "visible body did scroll work: \(visibleDuringScroll)")

        // Data changes off-screen cost the viewport, not the list.
        let dataBefore = model.onlyFoodCounter.evaluations
        model.onlyFoodItems.insert(-1, at: 0)
        host.pump(0.3)
        let hiddenOnDataChange = model.onlyFoodCounter.evaluations - dataBefore
        #expect(hiddenOnDataChange < model.onlyFoodItems.count,
                "hidden body evaluated \(hiddenOnDataChange) of \(model.onlyFoodItems.count) rows on a prepend")
        print("FeedStickToTopTests measurement: hidden rows during visible scroll = \(hiddenDuringScroll), visible rows during scroll = \(visibleDuringScroll), hidden rows on off-screen prepend = \(hiddenOnDataChange) of \(model.onlyFoodItems.count)")
    }
}

// MARK: - Hosting harness

@MainActor
private final class RowCounter {
    var evaluations = 0
}

@Observable
@MainActor
private final class HostModel {
    var showOnlyFood = true
    var onlyFoodItems = Array(0..<60)
    var generalItems = Array(0..<40)
    let onlyFoodCounter = RowCounter()
    let generalCounter = RowCounter()
}

private struct CountedRow: View {
    let index: Int
    let counter: RowCounter

    var body: some View {
        counter.evaluations += 1
        return Color.blue.frame(height: 100)
    }
}

private struct FeedList: View {
    let items: [Int]
    let counter: RowCounter

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items, id: \.self) { index in
                    CountedRow(index: index, counter: counter)
                }
            }
        }
    }
}

/// `MainView.feedContent` after PR 7: two bodies in `KeptMountedFeedBodies`
/// inside one `NavigationStack`.
private struct KeptHarness: View {
    let model: HostModel

    var body: some View {
        NavigationStack {
            KeptMountedFeedBodies(showOnlyFood: model.showOnlyFood) {
                FeedList(items: model.onlyFoodItems, counter: model.onlyFoodCounter)
            } general: {
                FeedList(items: model.generalItems, counter: model.generalCounter)
            }
        }
    }
}

/// `MainView.feedContent` before PR 7: a `@ViewBuilder` switch.
private struct SwitchHarness: View {
    let model: HostModel

    var body: some View {
        NavigationStack {
            if model.showOnlyFood {
                FeedList(items: model.onlyFoodItems, counter: model.onlyFoodCounter)
            } else {
                FeedList(items: model.generalItems, counter: model.generalCounter)
            }
        }
    }
}

/// A real window on the simulator, pumped by hand. OnlyFood's list is the
/// taller one (60 rows), the general list the shorter (40).
@MainActor
private final class Host {
    let window: UIWindow

    init<Root: View>(_ root: Root) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
    }

    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        window.layoutIfNeeded()
    }

    func scrollViews() -> [UIScrollView] {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    func onlyFoodScrollView() -> UIScrollView? {
        scrollViews().first { $0.contentSize.height >= 5_500 }
    }

    func generalScrollView() -> UIScrollView? {
        scrollViews().first { $0.contentSize.height >= 3_500 && $0.contentSize.height < 5_500 }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
