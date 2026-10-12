import Foundation
import Testing
@testable import wisp

/// The sign-up wizard's Lightning wallet is opt-in (default off): no wallet
/// and no public Lightning address unless the user turns the toggle on.
///
/// The tests drive `preparedProfileEvent()`, the kind-0 `finishProfileStep`
/// publishes, so nothing reaches a relay. `finishProfileStep` itself is
/// non-throwing and the profile step advances when it returns.
@MainActor
@Suite(.serialized)
struct SignUpWalletOptInTests {

    private func profileJSON(_ event: NostrEvent?) throws -> [String: Any] {
        let event = try #require(event)
        #expect(event.kind == 0)
        let data = try #require(event.content.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Toggle left off: kind-0 carries no `lud16` (field or tag) and no
    /// wallet mode is stored, so `WalletStore.startIfConfigured` no-ops and
    /// the Wallet screen offers its "Connect a wallet" setup.
    @Test func toggleOff_profileHasNoLightningAddress_andNoWalletMode() async throws {
        let vm = SignUpViewModel(acceptance: .now())
        let pubkey = vm.keypair.pubkey
        defer { WalletMode.clear(for: pubkey) }
        #expect(vm.wantsWallet == false)

        vm.name = "Test Cook"
        let event = await vm.preparedProfileEvent()
        let json = try profileJSON(event)

        #expect(json["name"] as? String == "Test Cook")
        #expect(json["lud16"] == nil)
        #expect(event?.tags.contains { $0.first == "lud16" } == false)
        #expect(vm.lightningAddress == nil)
        #expect(WalletMode.load(for: pubkey) == nil)
    }

    /// Toggle on but the wallet never comes up (no Breez key, derivation
    /// failed, or the connect timed out — `registerSparkLightningAddressIfReady`
    /// returns nil on all of them): kind-0 still signs, bare, and no wallet
    /// mode is stored. The silent-failure path must survive the opt-in.
    @Test func toggleOn_registrationFails_profileStillShipsBare() async throws {
        let vm = SignUpViewModel(acceptance: .now())
        let pubkey = vm.keypair.pubkey
        defer { WalletMode.clear(for: pubkey) }

        vm.name = "Test Cook"
        vm.wantsWallet = true   // no view, so no `startWalletSetup`: no wallet to register with
        let event = await vm.preparedProfileEvent()
        let json = try profileJSON(event)

        #expect(json["name"] as? String == "Test Cook")
        #expect(json["lud16"] == nil)
        #expect(vm.lightningAddress == nil)
        #expect(WalletMode.load(for: pubkey) == nil)
    }

    // MARK: - The seed the toggle writes
    //
    // Toggling on derives the wallet and saves its seed at once
    // (`deriveSignupWallet`, the half of `startWalletSetup` before the
    // Breez connect, which these tests never start).

    /// On → off: the seed is gone, so Delete Account offers no "Export
    /// wallet recovery phrase" for an account that opted out.
    @Test func toggleOnThenOff_leavesNoSeed() throws {
        let vm = SignUpViewModel(acceptance: .now())
        let pubkey = vm.keypair.pubkey
        defer { WalletKeychain.deleteSparkMnemonic(for: pubkey) }

        _ = try #require(vm.deriveSignupWallet())
        #expect(WalletKeychain.loadSparkMnemonic(for: pubkey) != nil)

        vm.discardSignupWallet()
        #expect(WalletKeychain.loadSparkMnemonic(for: pubkey) == nil)
    }

    /// The trap: `finishSignup` (what the wizard's `finish()` runs) tears the
    /// signup wallet down for every user. An opted-in account must come out
    /// of it with its seed, or MainView's WalletStore has no wallet.
    @Test func optedIn_finishingTheWizard_keepsTheSeed() async throws {
        let vm = SignUpViewModel(acceptance: .now())
        let pubkey = vm.keypair.pubkey
        defer {
            WalletKeychain.deleteSparkMnemonic(for: pubkey)
            UserDefaults.standard.removeObject(forKey: "onboarding_done_\(pubkey)")
        }

        vm.wantsWallet = true
        _ = try #require(vm.deriveSignupWallet())
        let seed = try #require(WalletKeychain.loadSparkMnemonic(for: pubkey))

        await vm.finishSignup()

        #expect(WalletKeychain.loadSparkMnemonic(for: pubkey) == seed)
        #expect(NostrKey.isOnboardingComplete(pubkey: pubkey))
    }

    /// On → off → on: the seed re-derives from the nsec, so the account ends
    /// with the same deterministic seed as the first time.
    @Test func toggleOnOffOn_endsWithTheSameSeed() throws {
        let vm = SignUpViewModel(acceptance: .now())
        let pubkey = vm.keypair.pubkey
        defer { WalletKeychain.deleteSparkMnemonic(for: pubkey) }

        _ = try #require(vm.deriveSignupWallet())
        let first = try #require(WalletKeychain.loadSparkMnemonic(for: pubkey))
        vm.discardSignupWallet()
        #expect(WalletKeychain.loadSparkMnemonic(for: pubkey) == nil)

        let wallet = try #require(vm.deriveSignupWallet())
        #expect(WalletKeychain.loadSparkMnemonic(for: pubkey) == first)
        #expect(wallet.isDefaultWallet(privkey: try #require(Hex.decode(vm.keypair.privkey))))
    }
}
