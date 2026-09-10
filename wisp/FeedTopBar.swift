import SwiftUI

/// The feed tab's top bar, pulled out of `MainView.topBar` far enough for the
/// gates to assert on it (feed/onlyfood-polish, TestFlight 2.1 (2) follow-ups).
///
/// Membership is a pure function of the kind and the Cheffy gate so
/// `FeedTopBarPolishTests` can pin "no online-users pill, no relay-count menu,
/// on any kind" without a SwiftUI host; the layout container keeps the picker
/// centred on the bar independent of what sits at either edge.
enum FeedTopBarControl: Equatable, CaseIterable {
    /// Leading: the avatar that opens the drawer.
    case avatar
    /// Leading, general kinds only: the content-filter cycle. Hidden on the
    /// hashtag-backed OnlyFood feed (unchanged).
    case contentFilter
    /// Centre: the kind picker, overlaid so it stays centred.
    case feedPicker
    /// Trailing: the Cheffy entry (`CheffyGate.entryVisible()`), the same
    /// `showCheffy` full-screen cover My Kitchen opens. Visible on every kind.
    case cheffy
}

enum FeedTopBarLayout {
    /// Everything the bar renders for `kind`. The online-users pill and the
    /// relay-count menu are gone from the bar: relay selection lives in the
    /// drawer's Feed Relay row (and the picker's Relay entry); Online Now was
    /// removed from the app.
    static func controls(kind: FeedKind, cheffyVisible: Bool) -> [FeedTopBarControl] {
        var controls: [FeedTopBarControl] = [.avatar]
        if kind != .onlyFood { controls.append(.contentFilter) }
        controls.append(.feedPicker)
        if cheffyVisible { controls.append(.cheffy) }
        return controls
    }

    /// PR 6's rule: every bar control is at least 44×44. The Cheffy glyph is
    /// drawn at 30 pt inside that target so it matches the 32 pt avatar on
    /// the leading side.
    static let cheffyTargetSize: CGFloat = 44
    static let cheffyGlyphSize: CGFloat = 30
}

/// Leading and trailing content in an `HStack`, the centre content overlaid
/// on the whole bar — so the centre is centred on the bar, not on the space
/// left between the edges. `MainView.topBar` uses it; the gate hosts it with
/// lopsided edges and measures the centre's midpoint.
struct FeedTopBarFrame<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let center: () -> Center
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading()
            Spacer()
            trailing()
        }
        .overlay(center())
    }
}

/// The drawer's Feed Relay row carries the connectivity signal the top bar
/// gave up: the connected count as its trailing value, red at zero exactly
/// as the pill was.
enum DrawerRelayRow {
    static func value(count: Int) -> String { "\(count)" }
    static func tint(count: Int) -> Color { count > 0 ? Color.wispRepostColor : .red }
}
