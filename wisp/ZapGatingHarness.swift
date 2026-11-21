#if DEBUG
import SwiftUI

/// Debug-only host for the recipient-address zap gate, reached with the
/// `-ZapGatingHarness` launch argument (same pattern as
/// `-ComposerDragHarness`): two real `PostCardView`s side by side in a
/// scroll — one author publishes a `lud16`, one doesn't — so the
/// zap-gating screenshot UI test can capture both action bars from the
/// actual card. No login: with no keypair loaded the card renders its full
/// action bar (`activeUserIsWatchOnly` is false), and nothing can be
/// signed, published, or paid.
///
/// The Fresh fixtures harness can't serve this: it creates a watch-only
/// account, and watch-only hides the whole action bar.
@MainActor
struct ZapGatingHarness: View {
    private let withAddress: NostrEvent?
    private let withoutAddress: NostrEvent?
    private let profiles: [String: ProfileData]

    init() {
        // The action bar only renders for an account that can sign — the
        // screenshot harnesses leave watch-only accounts behind, and those
        // hide the whole bar. Swap one in for a throwaway signing keypair
        // (DEBUG, launch-gated; never replaces a real signed-in account).
        // Nothing is signed, published, or paid — the harness never wires
        // publishing, and zaps need a configured wallet.
        let active = NostrKey.load()
        let needsThrowaway: Bool
        if let active {
            needsThrowaway = NostrKey.isWatchOnly(pubkey: active.pubkey)
        } else {
            needsThrowaway = true
        }
        if needsThrowaway {
            let priv = Schnorr.randomPrivkey()
            let pub = (try? Schnorr.xonlyPubkey(privkey32: priv)) ?? Data(count: 32)
            NostrKey.save(Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub)), acceptance: .now())
        }
        // Marisol (fixture cook 0) publishes a lud16; Theo (cook 1) doesn't.
        let marisol = FreshScreenshotFixtures.cooks[0]
        let theo = FreshScreenshotFixtures.cooks[1]
        self.withAddress = try? NostrEvent.sign(
            privkey32: marisol.priv, pubkey: marisol.pubkey, kind: 1,
            createdAt: NostrClock.now() - 300, tags: [],
            content: "Tomatillo salsa, charred under the broiler first. Bright, smoky, gone in an hour. Recipe in the replies."
        )
        self.withoutAddress = try? NostrEvent.sign(
            privkey32: theo.priv, pubkey: theo.pubkey, kind: 1,
            createdAt: NostrClock.now() - 600, tags: [],
            content: "Saturday loaf came out of the oven with the best ear I've had all year. Crumb shot tomorrow, it's still cooling."
        )
        self.profiles = FreshScreenshotFixtures.profiles
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let withAddress {
                    card(withAddress)
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                }
                if let withoutAddress {
                    card(withoutAddress)
                }
            }
            .frame(maxWidth: FreshFeedLayout.maxContentWidth)
        }
        .background(Color.wispBackground)
        .accessibilityIdentifier("zap-gating-harness")
        .environment(AppSettings.shared)
    }

    private func card(_ event: NostrEvent) -> some View {
        PostCardView(
            event: event,
            profile: profiles[event.pubkey],
            profiles: profiles,
            engagement: nil,
            onProfileTap: { _ in },
            onNoteTap: { _ in },
            onHashtagTap: { _ in }
        )
    }
}
#endif
