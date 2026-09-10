import SwiftUI

/// The one route from a zap affordance to `ZapSheet`.
///
/// `ZapSheet` raises the keyboard on appear (deferred `amountFocused` in its
/// `onAppear`). When the sheet is hosted by a view that lives inside a lazy
/// container — a feed row, the article / recipe action bar inside its
/// `LazyVStack` — the keyboard's safe-area change re-windows the container,
/// the presenting view is torn down, the sheet dies with it, and the
/// surviving `@State` re-presents: the open/close loop diagnosed on
/// 2026-06-07 (see `PostCardView.triggerZapOrWalletSetup` and
/// `ComposePresenter.openZap`). The cure is to present from the never-recycled
/// app root: `MainView` hosts the single `.sheet(item:)` over
/// `ComposePresenter.request`, and every recyclable caller hands its request
/// there through this seam instead of owning a `.sheet` of its own.
///
/// Three local hosts remain by design and are exempt: `MainView` (it *is*
/// the root host), `LiveStreamView` (a pushed full-screen view whose
/// `.sheet` sits on its root `VStack`, never in a lazy container) and
/// `ProfileHeaderView` (the first row of the profile scroll, which holds the
/// tapped control so the keyboard's viewport shrink cannot evict it, and
/// which must keep presenting when the profile is inside `SocialGraphView`'s
/// sheet, where a second root-hosted sheet would not appear). Any other
/// `ZapSheet` host belongs here.
///
/// The seam also owns the no-wallet guard. Presenting `ZapSheet` without a
/// configured wallet shows an empty sheet that dismisses at once — visually
/// the same as the loop — so callers must not present at all in that case;
/// they show the wallet-setup prompt (`walletSetupPrompt(isPresented:)`).
@MainActor
enum ZapRoute {
    enum Outcome: Equatable {
        /// Handed to `ComposePresenter`; `MainView`'s root `.sheet(item:)`
        /// presents it.
        case presentedFromRoot
        /// No configured wallet. Nothing is presented; the caller shows the
        /// wallet-setup prompt (or its own no-wallet fallback).
        case walletSetupNeeded
        /// No `ComposePresenter` in the environment, i.e. a view hosted
        /// outside `MainView`'s root. Nothing is presented — there is no
        /// local fallback by design.
        case noRootHost
    }

    /// A zap can be sent only when a wallet store exists *and* has a
    /// configured mode. `WalletStore` is injected app-wide, so `store != nil`
    /// alone says nothing about whether a wallet is set up.
    static func walletReady(_ store: WalletStore?) -> Bool {
        store?.mode != nil
    }

    /// Resolve a tap on a zap affordance.
    @discardableResult
    static func open(
        _ request: ZapSheetRequest,
        store: WalletStore?,
        presenter: ComposePresenter?
    ) -> Outcome {
        open(request, walletReady: walletReady(store), presenter: presenter)
    }

    /// Test seam: `WalletStore.mode` is `private(set)` and loaded from
    /// storage, so the hermetic tests drive readiness directly.
    @discardableResult
    static func open(
        _ request: ZapSheetRequest,
        walletReady: Bool,
        presenter: ComposePresenter?
    ) -> Outcome {
        guard walletReady else { return .walletSetupNeeded }
        guard let presenter else { return .noRootHost }
        presenter.openZap(request)
        return .presentedFromRoot
    }
}

// MARK: - Wallet-setup prompt

/// The confirmation dialog shown instead of `ZapSheet` when no wallet is
/// configured. "Set Up Wallet" posts `.openWalletTab`, which `MainView`
/// turns into `selectedTab = .wallet` — the same assignment the side menu's
/// Wallet row makes (Wallet is drawer-only since unified feed PR 6, not a
/// bottom-bar tab) — so the user lands on the setup UI directly.
private struct WalletSetupPromptModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        content.confirmationDialog(
            settings.fiatModeEnabled
                ? "Set up a wallet in the side menu to send money"
                : "Set up a wallet in the side menu to send zaps",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Set Up Wallet") {
                NotificationCenter.default.post(name: .openWalletTab, object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(settings.fiatModeEnabled
                 ? "Connect a Lightning wallet (Spark or NWC) under Wallet in the side menu to send money."
                 : "Connect a Lightning wallet (Spark or NWC) under Wallet in the side menu to send zaps.")
        }
    }
}

extension View {
    /// Attach the shared no-wallet prompt for a zap affordance. Pair with
    /// `ZapRoute.open` returning `.walletSetupNeeded`.
    func walletSetupPrompt(isPresented: Binding<Bool>) -> some View {
        modifier(WalletSetupPromptModifier(isPresented: isPresented))
    }
}
