import Foundation
import Testing
@testable import wisp

/// Hermetic coverage of `RecipeComposeViewModel` (Concern 2.4): the
/// `canPublish`-mirroring `blockReason` gate, category de-dupe, row ops,
/// Cheffy/Sous Chef prefill, edit prefill, and the upload-as-picked
/// publish block. Image uploads and the live publish are injected /
/// opt-in — this file never opens a socket.
@MainActor
struct RecipeComposeViewModelTests {

    private func vm(_ env: RecipeComposeViewModel.Environment? = nil) -> RecipeComposeViewModel {
        RecipeComposeViewModel(env: env ?? RecipeComposeViewModel.Environment(
            uploadImage: { _, _, _ in "https://blossom.example/ok.jpg" },
            compressImage: { data, mime in (data, mime) }
        ))
    }

    private func makeKeypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func doneImage(_ url: String = "https://example.com/cover.jpg") -> RecipeComposeViewModel.ImageItem {
        RecipeComposeViewModel.ImageItem(id: 1, status: .done(url: url))
    }

    private let filledIng = [RecipeComposeViewModel.Row(id: 1, text: "2 eggs")]
    private let filledDir = [RecipeComposeViewModel.Row(id: 2, text: "Whisk")]

    // MARK: - blockReason

    @Test func blockReason_readOnly_alwaysBlocks() {
        #expect(vm().blockReason(canSign: false) == "Sign in to publish recipes.")
    }

    @Test func blockReason_walksTheRequiredFieldsInOrder() {
        let vm = vm()
        #expect(vm.blockReason(canSign: true) == "Add a title.")
        vm.title = "Tuscan Peposo"
        #expect(vm.blockReason(canSign: true) == "Add at least one category.")
        vm.addCategory("italian")
        #expect(vm.blockReason(canSign: true) == "Add at least one photo.")
    }

    @Test func blockReason_valueOverload_clearsTitleGateWhenTitlePresent() {
        let img = [doneImage()]
        #expect(
            RecipeComposeViewModel.blockReason(
                canSign: true,
                title: "Tuscan Peposo",
                categories: [],
                images: img,
                ingredients: filledIng,
                directions: filledDir
            ) == "Add at least one category."
        )
        #expect(
            RecipeComposeViewModel.blockReason(
                canSign: true,
                title: "Tuscan Peposo",
                categories: ["italian"],
                images: img,
                ingredients: filledIng,
                directions: filledDir
            ) == nil
        )
        #expect(
            RecipeComposeViewModel.blockReason(
                canSign: true,
                title: " ",
                categories: ["italian"],
                images: img,
                ingredients: filledIng,
                directions: filledDir
            ) == "Add a title."
        )
    }

    @Test func blockReason_pendingUpload_blocksWithVisibleReason() {
        let uploading = [RecipeComposeViewModel.ImageItem(id: 1, status: .uploading)]
        #expect(
            RecipeComposeViewModel.blockReason(
                canSign: true,
                title: "Stew",
                categories: ["italian"],
                images: uploading,
                ingredients: filledIng,
                directions: filledDir
            ) == "Wait for photos to finish uploading (remove any that failed)."
        )
    }

    @Test func blockReason_failedUpload_blocksWithVisibleReason() {
        let failed = [RecipeComposeViewModel.ImageItem(id: 1, status: .failed(message: "nope"))]
        #expect(
            RecipeComposeViewModel.blockReason(
                canSign: true,
                title: "Stew",
                categories: ["italian"],
                images: failed,
                ingredients: filledIng,
                directions: filledDir
            ) == "Wait for photos to finish uploading (remove any that failed)."
        )
    }

    @Test func blockReason_editUnavailable_winsOverEmptyForm() {
        #expect(
            RecipeComposeViewModel.blockReason(
                canSign: true,
                title: "Stew",
                categories: ["italian"],
                images: [doneImage()],
                ingredients: filledIng,
                directions: filledDir,
                editUnavailable: true
            ) == "Couldn't load this recipe to edit. Go back and open it again."
        )
    }

    // MARK: - Categories

    @Test func addCategory_deDupesCaseInsensitively_andTrims() {
        let vm = vm()
        vm.addCategory("Italian")
        vm.addCategory(" italian ")
        vm.addCategory("ITALIAN")
        #expect(vm.categories == ["Italian"])
        vm.addCategory("Dessert")
        #expect(vm.categories == ["Italian", "Dessert"])
        vm.removeCategory("Italian")
        #expect(vm.categories == ["Dessert"])
    }

    @Test func addCategory_ignoresBlank() {
        let vm = vm()
        vm.addCategory(" ")
        vm.addCategory("")
        #expect(vm.categories.isEmpty)
    }

    // MARK: - Rows

    @Test func rowOps_keepAtLeastOneRow_andAssignStableIds() {
        let vm = vm()
        #expect(vm.ingredients.count == 1)
        let firstId = vm.ingredients[0].id
        vm.updateIngredient(id: firstId, text: "2 eggs")
        #expect(vm.ingredients[0].text == "2 eggs")
        vm.removeIngredient(id: firstId)
        #expect(vm.ingredients.count == 1)
        #expect(vm.ingredients[0].text == "")
        vm.addIngredient()
        #expect(vm.ingredients.count == 2)
        #expect(Set(vm.ingredients.map(\.id)).count == 2)
    }

    // MARK: - Prefill

    private let cheffyRecipe = """
    # Garlic Butter Shrimp

    A quick weeknight shrimp dish.

    ## Details
    \u{23F2}\u{FE0F} Prep time: 10 min
    \u{1F373} Cook time: 8 min
    \u{1F37D}\u{FE0F} Servings: 2

    ## Ingredients
    - 1 lb shrimp
    - 3 cloves garlic

    ## Directions
    1. Melt the butter.
    2. Add shrimp and garlic; cook 8 min.
    """

    @Test func prefill_cleanParse_seedsBody_leavesImagesCategoriesSummaryEmpty() {
        let vm = vm()
        vm.prefillFromMarkdown(cheffyRecipe)

        #expect(vm.title == "Garlic Butter Shrimp")
        #expect(vm.ingredients.map(\.text) == ["1 lb shrimp", "3 cloves garlic"])
        #expect(vm.directions.map(\.text) == ["Melt the butter.", "Add shrimp and garlic; cook 8 min."])
        #expect(vm.prepTime == "10 min")
        #expect(vm.cookTime == "8 min")
        #expect(vm.servings == "2")
        #expect(vm.images.isEmpty)
        #expect(vm.categories.isEmpty)
        #expect(vm.summary == "")
        #expect(vm.prefillNotice == nil)
        #expect(vm.blockReason(canSign: true) == "Add at least one category.")
    }

    @Test func prefill_lossyParse_salvagesRawText_andStaysGated() {
        let vm = vm()
        vm.prefillFromMarkdown("Just sauté some veggies with olive oil and garlic, no real recipe here.")

        #expect(vm.title == "Untitled")
        #expect(vm.additionalResources.contains("sauté some veggies"))
        #expect(vm.ingredients.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(vm.directions.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(vm.prefillNotice != nil)
        #expect(vm.blockReason(canSign: true) != nil)
    }

    @Test func prefill_isIdempotent() {
        let vm = vm()
        vm.prefillFromMarkdown(cheffyRecipe)
        vm.prefillFromMarkdown("# Other\n\n## Ingredients\n- x\n\n## Directions\n1. y")
        #expect(vm.title == "Garlic Butter Shrimp")
        #expect(vm.ingredients.count == 2)
    }

    @Test func prefillFromEvent_seedsImagesCategoriesSummary_andEntersEdit() {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan fixture failed to decode")
            return
        }
        let vm = vm()
        #expect(vm.prefillFromEvent(event))
        #expect(vm.isEditing)
        #expect(vm.title == "Tuscan Peposo (Black Pepper Beef Stew)")
        #expect(!vm.summary.isEmpty)
        #expect(!vm.images.isEmpty)
        #expect(vm.images.allSatisfy {
            if case .done = $0.status { return true }
            return false
        })
        #expect(vm.categories.contains("italian"))
        #expect(vm.blockReason(canSign: true) == nil)
    }

    @Test func markEditUnavailable_blocksPublish() {
        let vm = vm()
        vm.markEditUnavailable()
        #expect(vm.isEditing)
        #expect(vm.editUnavailable)
        #expect(vm.blockReason(canSign: true) == "Couldn't load this recipe to edit. Go back and open it again.")
    }

    // MARK: - Images as picked

    @Test func addImageBytes_blocksWhilePending_thenClearsWhenDone() async throws {
        let gate = AsyncStream.makeStream(of: Bool.self)
        let env = RecipeComposeViewModel.Environment(
            uploadImage: { _, _, _ in
                for await _ in gate.stream { break }
                return "https://blossom.example/done.jpg"
            },
            compressImage: { data, mime in (data, mime) }
        )
        let vm = RecipeComposeViewModel(env: env)
        vm.title = "Stew"
        vm.addCategory("italian")
        vm.updateIngredient(id: vm.ingredients[0].id, text: "salt")
        vm.updateDirection(id: vm.directions[0].id, text: "mix")

        let kp = try makeKeypair()
        vm.addImageBytes([(Data("img".utf8), "image/jpeg")], keypair: kp)
        #expect(vm.images.count == 1)
        if case .uploading = vm.images[0].status {} else {
            Issue.record("expected uploading")
        }
        #expect(vm.blockReason(canSign: true) == "Wait for photos to finish uploading (remove any that failed).")

        gate.continuation.yield(true)
        gate.continuation.finish()
        try await waitUntil { vm.images.first?.status == .done(url: "https://blossom.example/done.jpg") }
        #expect(vm.blockReason(canSign: true) == nil)
    }

    @Test func addImageBytes_failedUpload_blocksUntilRemoved() async throws {
        struct Boom: LocalizedError {
            var errorDescription: String? { "blossom down" }
        }
        let env = RecipeComposeViewModel.Environment(
            uploadImage: { _, _, _ in throw Boom() },
            compressImage: { data, mime in (data, mime) }
        )
        let vm = RecipeComposeViewModel(env: env)
        vm.title = "Stew"
        vm.addCategory("italian")
        vm.updateIngredient(id: vm.ingredients[0].id, text: "salt")
        vm.updateDirection(id: vm.directions[0].id, text: "mix")
        let kp = try makeKeypair()
        vm.addImageBytes([(Data("img".utf8), "image/jpeg")], keypair: kp)
        try await waitUntil {
            if case .failed = vm.images.first?.status { return true }
            return false
        }
        #expect(vm.blockReason(canSign: true) == "Wait for photos to finish uploading (remove any that failed).")
        vm.removeImage(id: vm.images[0].id)
        #expect(vm.blockReason(canSign: true) == "Add at least one photo.")
    }

    // MARK: - Publish

    @Test func publish_blockedWhenRequiredFieldEmpty() async throws {
        let probe = PublishProbe()
        let vm = vm()
        let kp = try makeKeypair()
        await vm.publish(publisher: probe.publisher(), keypair: kp, includeClientTag: false)
        if case .error(let message) = vm.publishState {
            #expect(message == "Add a title.")
        } else {
            Issue.record("expected error, got \(vm.publishState)")
        }
        #expect(probe.published.isEmpty)
    }

    @Test func publish_sendsHostedURLsThroughComposePath() async throws {
        let probe = PublishProbe()
        let vm = vm()
        let kp = try makeKeypair()
        vm.title = "Hermetic Compose Stew"
        vm.addCategory("test")
        vm.summary = "A test."
        vm.updateIngredient(id: vm.ingredients[0].id, text: "1 cup flour")
        vm.updateDirection(id: vm.directions[0].id, text: "Mix.")
        vm.addHostedImage(url: "https://blossom.example/cover.jpg")

        await vm.publish(publisher: probe.publisher(), keypair: kp, includeClientTag: false)
        if case .published(let author, let dTag) = vm.publishState {
            #expect(author == kp.pubkey)
            #expect(dTag == RecipeSerializer.slug("Hermetic Compose Stew"))
        } else {
            Issue.record("expected published, got \(vm.publishState)")
        }
        #expect(probe.published.count == 1)
        let event = try #require(probe.published.first)
        #expect(RecipeParser.isRecipe(event))
        let images = event.tags.filter { $0.first == "image" }.map { $0[1] }
        #expect(images == ["https://blossom.example/cover.jpg"])
        #expect(!probe.rehosted)
    }

    @Test func publish_editUsesOriginalAddress() async throws {
        guard let original = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan fixture failed to decode")
            return
        }
        // The fixture is someone else's event; sign a stand-in with our key
        // so publishEdit's author check passes, keeping the original d-tag.
        let kp = try makeKeypair()
        let authored = try await Signer.sign(
            keypair: kp,
            kind: original.kind,
            tags: original.tags,
            content: original.content,
            createdAt: original.createdAt
        )
        let probe = PublishProbe()
        let vm = vm()
        #expect(vm.prefillFromEvent(authored))
        vm.title = "Retitled Peposo"
        await vm.publish(publisher: probe.publisher(), keypair: kp, includeClientTag: false)
        if case .published(_, let dTag) = vm.publishState {
            #expect(dTag == "tuscan-peposo-(black-pepper-beef-stew)")
        } else {
            Issue.record("expected published, got \(vm.publishState)")
        }
        let event = try #require(probe.published.first)
        #expect(RecipeParser.dTag(event) == "tuscan-peposo-(black-pepper-beef-stew)")
        #expect(event.tags.contains(where: { $0 == ["title", "Retitled Peposo"] }))
    }

    @Test func isDirty_emptyCreate_isClean() {
        #expect(!vm().isDirty)
    }

    @Test func isDirty_typedTitle_isDirty() {
        let vm = vm()
        vm.title = "Stew"
        #expect(vm.isDirty)
    }

    // MARK: - Helpers

    private func waitUntil(_ timeout: Duration = .seconds(2), _ pred: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if pred() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for condition")
    }

    private final class PublishProbe: @unchecked Sendable {
        var published: [NostrEvent] = []
        var rehosted = false

        @MainActor
        func publisher() -> RecipePublisher {
            RecipePublisher(env: RecipePublisher.Environment(
                downloadImage: { _ in
                    self.rehosted = true
                    return nil
                },
                uploadBlossom: { _, _, _ in
                    self.rehosted = true
                    return nil
                },
                writeRelays: { _ in ["wss://write.example"] },
                cacheEvent: { _ in },
                applyLocalDeletion: { _, _ in },
                publish: { event, _ in
                    self.published.append(event)
                    return ["wss://write.example"]
                },
                now: { 1_800_000_000 },
                articlesRelays: ["wss://relay.primal.net"],
                pantryRelay: nil
            ))
        }
    }
}
