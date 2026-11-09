import SwiftUI

/// Hosts the feed tab's bodies (OnlyFood, general, Live Video) (unified feed §7, the PR 2 regression).
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
struct KeptMountedFeedBodies<OnlyFood: View, General: View, Live: View>: View {
    let active: FeedTabRouting.Body
    @ViewBuilder let onlyFood: () -> OnlyFood
    @ViewBuilder let general: () -> General
    @ViewBuilder let live: () -> Live

    @State private var onlyFoodMounted = false
    @State private var generalMounted = false
    @State private var liveMounted = false

    var body: some View {
        ZStack {
            if onlyFoodMounted || active == .onlyFood {
                onlyFood()
                    .modifier(KeptMountedBody(visible: active == .onlyFood))
            }
            if generalMounted || active == .general {
                general()
                    .modifier(KeptMountedBody(visible: active == .general))
            }
            if liveMounted || active == .liveVideo {
                live()
                    .modifier(KeptMountedBody(visible: active == .liveVideo))
            }
        }
        .onChange(of: active, initial: true) { _, now in
            switch now {
            case .onlyFood: onlyFoodMounted = true
            case .general: generalMounted = true
            case .liveVideo: liveMounted = true
            }
        }
    }
}

extension KeptMountedFeedBodies where Live == EmptyView {
    /// The two-body form: OnlyFood or the general feed.
    init(
        showOnlyFood: Bool,
        @ViewBuilder onlyFood: @escaping () -> OnlyFood,
        @ViewBuilder general: @escaping () -> General
    ) {
        self.init(active: showOnlyFood ? .onlyFood : .general, onlyFood: onlyFood, general: general, live: { EmptyView() })
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
