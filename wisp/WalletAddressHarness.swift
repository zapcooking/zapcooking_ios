#if DEBUG
import SwiftUI

/// Debug-only host for the wallet's Lightning-address setup sheet, reached
/// with the `-WalletAddressHarness` launch argument — the same pattern as
/// `-ComposerDragHarness`. Hosts the real `LightningAddressSetupSheet` with
/// a throwaway keypair and no wallet connection, so screenshot tests can
/// capture the registration form (domain suffix, validation copy, register
/// button) without logging in or touching funds. Typing settles to
/// "already taken" because the availability probe needs a connected Spark
/// wallet, which this harness deliberately never builds.
struct WalletAddressHarness: View {
    @State private var presented = true
    @State private var store: WalletStore

    init() {
        let priv = Schnorr.randomPrivkey()
        let pub = (try? Schnorr.xonlyPubkey(privkey32: priv)) ?? Data(count: 32)
        _store = State(initialValue: WalletStore(keypair: Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))))
    }

    var body: some View {
        Color.wispBackground
            .ignoresSafeArea()
            .sheet(isPresented: $presented) {
                LightningAddressSetupSheet(store: store)
            }
    }
}
#endif
