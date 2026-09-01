import Foundation
import Testing
@testable import wisp

/// `ComposeViewModel` seed text (`initialText`) vs. the restored local
/// autosave. Pre-existing bugs surfaced by Concern C-H, which makes the
/// seeded composer a routine path instead of the wallet-invoice / share-
/// extension edge it was: (1) a seed overwrote the restored unsent draft;
/// (2) hashtags were only derived on the next keystroke, so a restored or
/// seeded body published untouched lost its `t` tags. Hermetic.
@MainActor
struct ComposeSeedTests {

    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func autosaveKey(_ kp: Keypair) -> String { "compose_autosave_new_\(kp.pubkey)" }

    /// A restored draft with hashtags publishes them even if untouched
    /// (pre-existing: chips only recomputed on the next edit).
    @Test func composer_restoredAutosave_derivesHashtagsWithoutEdit() {
        let kp = freshKeypair()
        UserDefaults.standard.set(["content": "ramen night #ramen #soup"], forKey: autosaveKey(kp))
        defer { UserDefaults.standard.removeObject(forKey: autosaveKey(kp)) }
        let vm = ComposeViewModel(keypair: kp, mode: .new)
        #expect(vm.content == "ramen night #ramen #soup")
        #expect(vm.hashtags == ["ramen", "soup"])
    }

    /// Pre-existing bug (wallet invoice / share-extension text today): a
    /// seeded composer overwrote the restored unsent draft. Now the seed is
    /// appended below the draft and both survive.
    @Test func composer_seedDoesNotClobberRestoredDraft() {
        let kp = freshKeypair()
        UserDefaults.standard.set(["content": "half-typed thought"], forKey: autosaveKey(kp))
        defer { UserDefaults.standard.removeObject(forKey: autosaveKey(kp)) }
        let vm = ComposeViewModel(keypair: kp, initialText: "#foodstr\n\n")
        #expect(vm.content == "half-typed thought\n\n#foodstr")
        #expect(vm.hashtags == ["foodstr"])
    }

    @Test func composer_seedAlreadyInDraft_isNotDuplicated() {
        let kp = freshKeypair()
        UserDefaults.standard.set(["content": "#foodstr\n\nstill drafting"], forKey: autosaveKey(kp))
        defer { UserDefaults.standard.removeObject(forKey: autosaveKey(kp)) }
        let vm = ComposeViewModel(keypair: kp, initialText: "#foodstr\n\n")
        #expect(vm.content == "#foodstr\n\nstill drafting")
        #expect(vm.hashtags == ["foodstr"])
    }

    /// The wallet path keeps working: a bolt11 seed into an empty body is
    /// used verbatim.
    @Test func composer_seedIntoEmptyBody_isVerbatim() {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: autosaveKey(kp))
        let vm = ComposeViewModel(keypair: kp, initialText: "lnbc1fake")
        #expect(vm.content == "lnbc1fake")
        #expect(vm.hashtags.isEmpty)
    }
}
