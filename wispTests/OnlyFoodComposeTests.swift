import Foundation
import Testing
@testable import wisp

/// Concern C-H — the OnlyFood composer seed and its interaction with the
/// composer's hashtag derivation and the §7.3 structural cap. Hermetic.
@MainActor
struct OnlyFoodComposeTests {

    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func autosaveKey(_ kp: Keypair) -> String { "compose_autosave_new_\(kp.pubkey)" }

    private func kind1(content: String, tTags: [String]) -> NostrEvent {
        NostrEvent(
            id: "e1", pubkey: String(repeating: "a", count: 64), kind: 1, createdAt: 1,
            tags: tTags.map { ["t", $0] }, content: content,
            sig: String(repeating: "0", count: 128)
        )
    }

    @Test func seed_isFoodstrOnItsOwnLine_andInTheFeedSet() {
        #expect(OnlyFoodCompose.defaultTag == "foodstr")
        #expect(OnlyFoodCompose.prefill == "#foodstr\n\n")
        #expect(FoodHashtags.allSet.contains(OnlyFoodCompose.defaultTag))
        #expect(FoodHashtags.all.first == OnlyFoodCompose.defaultTag)
    }

    @Test func seed_countsAsExactlyOneContentHashtag() {
        #expect(OnlyFoodFilter.countContentHashtags(OnlyFoodCompose.prefill) == 1)
        #expect(OnlyFoodFilter.countContentHashtags(OnlyFoodCompose.prefill + "dinner tonight") == 1)
    }

    /// The seed costs one of the five the cap allows: seed + 4 typed tags
    /// passes, seed + 5 typed tags is structural spam. Typing `#foodstr` a
    /// second time dedups on the `t` side but still counts on the content
    /// side (`max(content #tags, t-tags)`), so it is not free.
    @Test func seed_plusFourUserTags_passesCap_plusFiveFails() {
        let four = OnlyFoodCompose.prefill + "soup #soup #stew #dinner #homemade"
        let five = four + " #cooking"
        let dupe = OnlyFoodCompose.prefill + "#foodstr #soup #stew #dinner #homemade"
        func tags(_ content: String) -> [String] {
            let vm = ComposeViewModel(keypair: freshKeypair(), initialText: content)
            return vm.hashtags
        }
        #expect(tags(four).count == 5)
        #expect(!OnlyFoodFilter.isStructuralSpam(kind1(content: four, tTags: tags(four))))
        #expect(tags(five).count == 6)
        #expect(OnlyFoodFilter.isStructuralSpam(kind1(content: five, tTags: tags(five))))
        #expect(tags(dupe) == ["foodstr", "soup", "stew", "dinner", "homemade"])
        #expect(OnlyFoodFilter.countContentHashtags(dupe) == 6)
        #expect(OnlyFoodFilter.isStructuralSpam(kind1(content: dupe, tTags: tags(dupe))))
    }

    /// The composer opens with the tag already derived — chip visible and
    /// `t` tag ready — without waiting for a keystroke.
    @Test func composer_seededWithPrefill_derivesFoodstrImmediately() {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: autosaveKey(kp))
        let vm = ComposeViewModel(keypair: kp, initialText: OnlyFoodCompose.prefill)
        #expect(vm.content == OnlyFoodCompose.prefill)
        #expect(vm.hashtags == ["foodstr"])
    }

    /// Removable: deleting the seed text drops the chip and the tag.
    @Test func composer_removingSeed_dropsTheTag() {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: autosaveKey(kp))
        let vm = ComposeViewModel(keypair: kp, initialText: OnlyFoodCompose.prefill)
        vm.updateContent("just soup tonight")
        #expect(vm.hashtags.isEmpty)
    }

    @Test func presenter_newNoteRequest_carriesSeed() {
        let presenter = ComposePresenter()
        presenter.openNewNote(initialText: OnlyFoodCompose.prefill)
        guard case .newNote(let text)? = presenter.request else {
            Issue.record("expected .newNote, got \(String(describing: presenter.request))")
            return
        }
        #expect(text == OnlyFoodCompose.prefill)
        #expect(presenter.request?.id == "new-note")
    }
}
