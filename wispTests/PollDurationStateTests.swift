import Foundation
import Testing
@testable import wisp

/// The poll duration choice lives on `ComposeViewModel`, not in
/// `PollOptionsEditor`'s `@State`: that editor is mounted only while the poll
/// is on, so toggling the poll off and on used to reset a chosen ∞ / 7d /
/// custom date to the one-day default without telling the user.
@MainActor
struct PollDurationStateTests {

    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    @Test func freshComposerStartsOnTheOneDayPresetWithNoStampYet() {
        let vm = ComposeViewModel(keypair: freshKeypair(), mode: .new)
        #expect(vm.pollDurationPreset == .oneDay)
        #expect(!vm.pollDurationIsCustom)
        // The editor stamps the timestamp on first appearance; until then
        // `pollEndsAt` is nil, which is what tells it the composer is fresh.
        #expect(vm.pollEndsAt == nil)
    }

    @Test func durationChoiceSurvivesTogglingThePollOff() {
        let vm = ComposeViewModel(keypair: freshKeypair(), mode: .new)
        vm.togglePoll()
        #expect(vm.pollEnabled)
        // ∞: no preset, no end date.
        vm.pollDurationPreset = nil
        vm.setPollEndsAt(nil)
        vm.togglePoll()
        vm.togglePoll()
        #expect(vm.pollEnabled)
        #expect(vm.pollDurationPreset == nil)
        #expect(vm.pollEndsAt == nil)

        // A preset with its stamp survives the same round trip.
        vm.pollDurationPreset = .sevenDays
        vm.setPollEndsAt(1_800_000_000)
        vm.togglePoll()
        vm.togglePoll()
        #expect(vm.pollDurationPreset == .sevenDays)
        #expect(vm.pollEndsAt == 1_800_000_000)
    }
}
