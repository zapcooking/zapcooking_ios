import SwiftUI

/// Hosts the feed tab's two bodies (unified feed §7, the PR 2 regression).
/// `MainView.feedContent` used to be a `@ViewBuilder` switch on the kind, so
/// picking another kind tore down the other body's `ScrollView` and OnlyFood
/// — whose notes live on in its view model — came back scrolled to the top.
/// Here both bodies stay mounted once they have been shown and only their
/// opacity toggles, the same pattern `mainShell` uses for the feed and
/// recipes tabs: SwiftUI preserves the scroll position of a view it does not
/// destroy, with nothing tracked and nothing added to the scroll hot path.
///
/// A body is not mounted until it is first shown, so a cold start on
/// OnlyFood never lays out the general feed's empty state underneath it,
/// and a Follows landing never spins OnlyFood's loading indicator off-screen.
/// `FeedStickToTopTests` measures what the hidden body costs.
struct KeptMountedFeedBodies<OnlyFood: View, General: View>: View {
    let showOnlyFood: Bool
    @ViewBuilder let onlyFood: () -> OnlyFood
    @ViewBuilder let general: () -> General

    @State private var onlyFoodMounted = false
    @State private var generalMounted = false

    var body: some View {
        ZStack {
            if onlyFoodMounted || showOnlyFood {
                onlyFood()
                    .modifier(KeptMountedBody(visible: showOnlyFood))
            }
            if generalMounted || !showOnlyFood {
                general()
                    .modifier(KeptMountedBody(visible: !showOnlyFood))
            }
        }
        .onChange(of: showOnlyFood, initial: true) { _, show in
            if show { onlyFoodMounted = true } else { generalMounted = true }
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
