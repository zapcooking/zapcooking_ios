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
}
