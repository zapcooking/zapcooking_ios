import SwiftUI

/// Hosts the feed tab's bodies, one per `FeedTabRouting.Body` (unified feed
/// §7, the PR 2 regression). `MainView.feedContent` used to be a
/// `@ViewBuilder` switch on the kind, so picking another kind tore down the
/// other body's `ScrollView` and OnlyFood — whose notes live on in its view
/// model — came back scrolled to the top. Here every body stays mounted once
/// it has been shown and only its opacity toggles, the same pattern
/// `mainShell` uses for the feed and recipes tabs: SwiftUI preserves the
/// scroll position of a view it does not destroy, with nothing tracked and
/// nothing added to the scroll hot path.
///
/// A body is not mounted until it is first shown, so a cold start on
/// OnlyFood never lays out the general feed's empty state underneath it,
/// and a Follows landing never spins OnlyFood's loading indicator off-screen.
/// `FeedStickToTopTests` measures what the hidden body costs.
///
/// Keyed: `content` builds the body for a key, and the container keeps the
/// set of keys that have been shown. Each body's identity is its key (the
/// `ForEach` id), so a body is never rebuilt by another one mounting, and
/// the stacking order is `FeedTabRouting.Body.allCases` order. Adding a body
/// is a new `Body` case plus a branch in the caller's `content`.
struct KeptMountedFeedBodies<Content: View>: View {
    let active: FeedTabRouting.Body
    @ViewBuilder let content: (FeedTabRouting.Body) -> Content

    @State private var mounted: Set<FeedTabRouting.Body> = []

    var body: some View {
        ZStack {
            ForEach(FeedTabRouting.Body.allCases, id: \.self) { key in
                if mounted.contains(key) || active == key {
                    content(key)
                        .modifier(KeptMountedBody(visible: active == key))
                }
            }
        }
        .onChange(of: active, initial: true) { _, now in
            mounted.insert(now)
        }
    }
}

extension KeptMountedFeedBodies {
    /// The two-body form: OnlyFood or the general feed.
    init<OnlyFood: View, General: View>(
        showOnlyFood: Bool,
        @ViewBuilder onlyFood: @escaping () -> OnlyFood,
        @ViewBuilder general: @escaping () -> General
    ) where Content == KeptMountedPair<OnlyFood, General> {
        self.init(active: showOnlyFood ? .onlyFood : .general) { key in
            KeptMountedPair(key: key, onlyFood: onlyFood, general: general)
        }
    }
}

/// The two-body form's `content`: OnlyFood for `.onlyFood`, the general feed
/// for any other key (the two-body form never selects another key).
struct KeptMountedPair<OnlyFood: View, General: View>: View {
    let key: FeedTabRouting.Body
    let onlyFood: () -> OnlyFood
    let general: () -> General

    var body: some View {
        if key == .onlyFood {
            onlyFood()
        } else {
            general()
        }
    }
}

/// Hidden-but-mounted: invisible, untouchable, and out of the accessibility
/// tree, like the inactive tabs in `mainShell`.
private struct KeptMountedBody: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}
