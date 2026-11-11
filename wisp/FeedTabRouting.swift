import Foundation
import SwiftUI

/// Feed-tab plumbing shared by `MainView` and `FeedTabRoutingTests`
/// (unified-feed PR 2). One feed surface renders two bodies; these are the
/// kind-dependent decisions pulled out of the view so the gates can assert
/// on them without a SwiftUI host.
enum FeedTabRouting {
    /// Which body the feed tab renders for a kind. `allCases` order is the
    /// stacking order in `KeptMountedFeedBodies`.
    enum Body: Hashable, CaseIterable {
        /// `OnlyFoodFeedViewModel`'s list (hashtag-backed, §7.4 latched).
        case onlyFood
        /// `FeedViewModel`'s list (follows / relay / relay set / extended).
        case general
        /// Discovered NIP-53 streams (`LiveStreamRepository`), Sidecar-style.
        case liveVideo
        /// The curated feed relay (`FreshFeedViewModel`).
        case fresh
    }

    static func body(for kind: FeedKind) -> Body {
        switch kind {
        case .onlyFood:
            return .onlyFood
        case .liveVideo:
            return .liveVideo
        case .fresh:
            return .fresh
        case .follows, .relay, .relaySet, .extendedNetwork:
            return .general
        }
    }

    /// Appear / kind-change hook for the feed tab. Starts the OnlyFood VM only
    /// while the kind is OnlyFood. `start()` is latched by `started`, so a
    /// kind switch away and back — or any re-appear — never issues a new REQ;
    /// pull-to-refresh remains the only re-query path (§7.4). No prewarming
    /// for other kinds.
    static func ensureOnlyFoodStarted(kind: FeedKind, onlyFood: OnlyFoodFeedViewModel) {
        guard kind == .onlyFood else { return }
        onlyFood.start()
    }

    /// Foreground hook (§3.3). Resumes the OnlyFood VM only while the kind is
    /// OnlyFood; `resume()` itself is a no-op before `start()` and while an
    /// initial load is in flight, and never clears.
    static func resumeOnlyFoodIfActive(kind: FeedKind, onlyFood: OnlyFoodFeedViewModel) {
        guard kind == .onlyFood else { return }
        onlyFood.resume()
    }

    /// Appear / kind-change hook for Fresh. The feed's socket is open only
    /// while Fresh is the selected kind: picking it activates the VM (page 1
    /// the first time, a new tail after that); picking anything else closes
    /// the socket and keeps the list.
    static func syncFresh(kind: FeedKind, fresh: FreshFeedViewModel) {
        if kind == .fresh {
            fresh.activate()
        } else {
            fresh.deactivate()
        }
    }

    /// Foreground hook, forwarded whatever the selected kind: background is
    /// always forwarded too, so the VM's app-active state must be as well.
    /// The VM does network work only while Fresh is active.
    static func freshDidBecomeActive(fresh: FreshFeedViewModel) {
        fresh.appDidBecomeActive()
    }

    /// Re-tap of the feed tab: pop the stack to its root and bump the
    /// scroll-to-top trigger. `kind` is accepted so the call site and the gate
    /// state the invariant explicitly — the pop is the same on every kind.
    static func popFeedToRoot(kind: FeedKind, path: inout NavigationPath, scrollToTopTrigger: inout Int) {
        _ = kind
        path = NavigationPath()
        scrollToTopTrigger &+= 1
    }

    /// Feed-kind change hook (§7, Android's `prevMode` principle). Which
    /// body, if any, re-pins to the top after observing `kind`:
    /// - `nil` when the tracker saw no change — first composition, or a tab
    ///   re-entry re-observing the same kind — so a restored scroll position
    ///   is kept;
    /// - `.general` on an actual selection of a general kind: its list is
    ///   rebuilt by `FeedViewModel.resetForKindSwitch`, so it lands at the
    ///   top of the new content with following re-armed;
    /// - `nil` on an actual selection of OnlyFood. Its list is the same list
    ///   the user left (§7.4: no new REQ), so the body restores the position
    ///   they left at — the PR 2 regression fix — and its follow state is
    ///   left as it was. Android re-pins here too; iOS keeps the position
    ///   because that is the bug this PR was opened for.
    static func repinTarget(afterObserving kind: FeedKind, tracker: inout FeedKindSwitchTracker) -> Body? {
        guard tracker.observe(kind) else { return nil }
        switch body(for: kind) {
        case .general: return .general
        // Fresh keeps its list across a switch (no new page), so it keeps
        // the position too, like OnlyFood.
        case .onlyFood, .liveVideo, .fresh: return nil
        }
    }

    /// Memories teaser (`MemoriesCard`) in the top slot of BOTH feed bodies,
    /// directly under the live rail. Deliberate: Memories surfaces the user's
    /// own kind-1 notes whatever their topic, so a non-food memory can appear
    /// on the OnlyFood feed — a knowing inconsistency, justified because
    /// OnlyFood is the default landing and hiding the teaser there would hide
    /// it for most users. The card renders nothing on a day with no memories.
    static func showsMemoriesTeaser(for kind: FeedKind) -> Bool {
        _ = kind
        return true
    }

    /// Compose FAB (§8): the tappable food-tag pills on OnlyFood; empty means
    /// the plain note composer. No seed text on any kind — nothing is added to
    /// a note unless the user taps a pill.
    static func composeSuggestions(for kind: FeedKind) -> [String] {
        switch kind {
        case .onlyFood:
            return OnlyFoodCompose.suggestedTags
        case .follows, .relay, .relaySet, .extendedNetwork, .liveVideo, .fresh:
            return []
        }
    }

    /// Route types the feed tab's `NavigationStack` registers (`MainView.feedTab`
    /// — the `.navigationDestination` calls plus `.recipeNavigation`). This is
    /// a documented contract, not introspection: SwiftUI's destination table
    /// can't be read back, so keep this list and `feedTab` in step.
    static let feedStackRoutes: [Any.Type] = [
        ProfileRoute.self,
        ThreadRoute.self,
        LiveStreamRoute.self,
        ArticleRoute.self,
        RecipeRoute.self,
        RecipeTagFeedRoute.self,
        HashtagFeedRoute.self,
        PeopleListFeedRoute.self,
        NoteListFeedRoute.self,
        TrendingFeedRoute.self,
    ]

    /// What the deleted OnlyFood stack registered (Profile, Thread, Article,
    /// Hashtag, `.recipeNavigation`). Must stay a subset of `feedStackRoutes`
    /// so no destination was lost in the merge.
    static let absorbedOnlyFoodStackRoutes: [Any.Type] = [
        ProfileRoute.self,
        ThreadRoute.self,
        ArticleRoute.self,
        HashtagFeedRoute.self,
        RecipeRoute.self,
        RecipeTagFeedRoute.self,
    ]

    static func feedStackRegisters(_ type: Any.Type) -> Bool {
        feedStackRoutes.contains { ObjectIdentifier($0) == ObjectIdentifier(type) }
    }
}
