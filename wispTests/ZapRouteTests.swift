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

    // MARK: - Structural: exactly one route from the recyclable hosts

    /// Repository root, from this file's compile-time path (the gate box
    /// compiles the suite from its own checkout, so the sources are there).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Both lazy-row hosts hand their zap to `ZapRoute` and own no `ZapSheet`.
    @Test func postCardAndArticleBar_useTheRootRoute_notALocalSheet() throws {
        let construct = "ZapSheet" + "("
        for file in ["PostCardView.swift", "wisp/ArticleView.swift"] {
            let text = try source(file)
            #expect(text.contains("ZapRoute.open("), "\(file) must route its zap through ZapRoute")
            #expect(!text.contains(construct), "\(file) must not construct ZapSheet itself")
            #expect(!text.contains("showZapSheet"), "\(file) must not keep a local zap-sheet binding")
            #expect(text.contains("walletSetupPrompt(isPresented:"), "\(file) must show the setup prompt without a wallet")
        }
    }

    /// The app-wide set of `ZapSheet` constructors is exactly the root host
    /// plus the two screen-level hosts the audit found safe (a pushed
    /// full-screen view and the first row of the profile scroll, which the
    /// keyboard cannot push out of the window). Any new local host must be
    /// argued here, not added silently.
    @Test func zapSheet_isConstructedOnlyByTheRootHost_andAuditedScreenLevelHosts() throws {
        let construct = "ZapSheet" + "("
        let skip: Set<String> = [".git", ".build", "DerivedData", "wispTests", "wisp.xcodeproj", "Pods"]
        var hosts: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: repoRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if skip.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator?.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(construct) else { continue }
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            hosts.insert(relative)
        }
        #expect(hosts == ["MainView.swift", "ProfileView.swift", "wisp/Live/LiveStreamView.swift"],
                "ZapSheet hosts: \(hosts.sorted())")
        // And the root host is the ComposePresenter-driven one.
        let main = try source("MainView.swift")
        #expect(main.contains(".sheet(item: $presenter.request)"))
        #expect(main.contains("case .zap(let zap):"))
    }
}
