import Foundation
import Testing
@testable import wisp

/// fix/article-action-bar-zap gates: `ZapSheet` is presented from the app
/// root (`MainView`'s `.sheet(item:)` over `ComposePresenter.request`) for
/// both `PostCardView` and `ArticleActionBar`; the no-wallet case shows the
/// setup prompt instead of an empty sheet; a watch-only account never
/// reaches the zap control from a recipe.
@MainActor
struct ZapRouteTests {

    private let author = String(repeating: "ab", count: 32)
    private let eventId = String(repeating: "cd", count: 32)

    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func request(eventId: String?) -> ZapSheetRequest {
        ZapSheetRequest(
            recipientPubkey: author,
            recipientLud16: "chef@example.com",
            recipientName: "Chef",
            eventId: eventId,
            extraTags: [["poll_option", "1"]],
            forcePrivate: true
        )
    }

    // MARK: - The route lands on the root host

    @Test func open_withWallet_handsTheRequestToTheRootHost() {
        let presenter = ComposePresenter()
        let outcome = ZapRoute.open(request(eventId: eventId), walletReady: true, presenter: presenter)
        #expect(outcome == .presentedFromRoot)
        guard case .zap(let zap)? = presenter.request else {
            Issue.record("expected a .zap request on the presenter, got \(String(describing: presenter.request))")
            return
        }
        // Everything the sheet needs rides on the request — the root host
        // adds only the wallet store it owns.
        #expect(zap.recipientPubkey == author)
        #expect(zap.recipientLud16 == "chef@example.com")
        #expect(zap.recipientName == "Chef")
        #expect(zap.eventId == eventId)
        #expect(zap.extraTags == [["poll_option", "1"]])
        #expect(zap.forcePrivate)
        #expect(presenter.request?.id == "zap-\(eventId)")
    }

    @Test func profileZap_withoutAnEvent_keysTheRequestOnThePubkey() {
        let presenter = ComposePresenter()
        ZapRoute.open(request(eventId: nil), walletReady: true, presenter: presenter)
        #expect(presenter.request?.id == "zap-\(author)")
    }

    // MARK: - No wallet: prompt, never an empty sheet

    @Test func open_withoutWallet_promptsSetup_andPresentsNothing() {
        let presenter = ComposePresenter()
        let outcome = ZapRoute.open(request(eventId: eventId), walletReady: false, presenter: presenter)
        #expect(outcome == .walletSetupNeeded)
        #expect(presenter.request == nil)
    }

    @Test func walletReady_needsAStoreWithAConfiguredMode() {
        #expect(!ZapRoute.walletReady(nil))
        // A fresh account has a store (it is injected app-wide) but no
        // configured wallet: `store != nil` must not count as ready.
        let store = WalletStore(keypair: freshKeypair())
        #expect(store.mode == nil)
        #expect(!ZapRoute.walletReady(store))
        #expect(ZapRoute.open(request(eventId: eventId), store: store, presenter: ComposePresenter())
                == .walletSetupNeeded)
    }

    @Test func open_withoutRootHost_presentsNothing_andDoesNotPrompt() {
        let outcome = ZapRoute.open(request(eventId: eventId), walletReady: true, presenter: nil)
        #expect(outcome == .noRootHost)
    }

    // MARK: - Watch-only cannot reach the zap control from a recipe

    @Test func recipeEngagementBar_watchOnly_isBookmarkOnly() {
        #expect(RecipeEngagementBar.of(watchOnly: true) == .bookmarkOnly)
        #expect(RecipeEngagementBar.of(watchOnly: false) == .full)
    }
}
