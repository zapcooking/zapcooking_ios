import Foundation
import Testing
@testable import wisp

/// A quoted event is the "attachment" of a quote note: it shows in the preview
/// with no text, but the note cannot be published until it has a comment.
@MainActor
struct ComposeQuotePublishGateTests {
    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func recipe(by pubkey: String) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "e", count: 64), pubkey: pubkey, kind: RecipeParser.recipeKind,
            createdAt: 1_700_000_000, tags: [["d", "stew"], ["t", "zapcooking"]],
            content: "## Ingredients\n\n- x\n\n## Directions\n\n1. y", sig: String(repeating: "f", count: 128)
        )
    }

    private func clearAutosave(_ kp: Keypair, _ quoted: NostrEvent) {
        UserDefaults.standard.removeObject(forKey: "compose_autosave_quote_\(kp.pubkey)_\(quoted.id)")
    }

    @Test func quoteWithNoComment_cannotPublish() {
        let kp = freshKeypair()
        let quoted = recipe(by: kp.pubkey)
        clearAutosave(kp, quoted)
        let vm = ComposeViewModel(keypair: kp, mode: .quote(quoted))
        #expect(!vm.canPublish)
        #expect(vm.publishBlocker == "Add a comment.")
    }

    @Test func quoteWithWhitespaceOnly_cannotPublish() {
        let kp = freshKeypair()
        let quoted = recipe(by: kp.pubkey)
        clearAutosave(kp, quoted)
        let vm = ComposeViewModel(keypair: kp, mode: .quote(quoted))
        vm.content = "  \n "
        #expect(!vm.canPublish)
    }

    @Test func quoteWithComment_canPublish() {
        let kp = freshKeypair()
        let quoted = recipe(by: kp.pubkey)
        clearAutosave(kp, quoted)
        let vm = ComposeViewModel(keypair: kp, mode: .quote(quoted))
        vm.content = "Making this tonight."
        #expect(vm.canPublish)
    }

    @Test func quotePreviewContent_embedsTheRecipeEvenWithNoComment() {
        let kp = freshKeypair()
        let quoted = recipe(by: kp.pubkey)
        clearAutosave(kp, quoted)
        let vm = ComposeViewModel(keypair: kp, mode: .quote(quoted))
        #expect(vm.previewContent.hasPrefix("nostr:naddr1"))
    }

    @Test func plainNewNote_gateUnchanged() {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: "compose_autosave_new_\(kp.pubkey)")
        let vm = ComposeViewModel(keypair: kp, mode: .new)
        #expect(vm.publishBlocker == "Write something or add a photo.")
    }
}
