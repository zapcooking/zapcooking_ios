import Foundation
import Testing
@testable import wisp

/// `NoteReviewViewModel` — the session state around the pure phase
/// mapping (port of Android `NoteReviewViewModelTest`, credits removed).
/// Requests and publishes are scripted; nothing here touches the network.
@MainActor
struct NoteReviewViewModelTests {

    // MARK: Fixtures

    private static func keypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private static func parent(content: String = "made this https://example.com/dish.jpg") -> NostrEvent {
        NostrEvent(
            id: String(repeating: "ab", count: 32),
            pubkey: String(repeating: "cd", count: 32),
            kind: 1, createdAt: 1_700_000_000, tags: [], content: content, sig: String(repeating: "0", count: 128)
        )
    }

    private static func signed(_ keypair: Keypair, content: String) async throws -> NostrEvent {
        try await Signer.sign(keypair: keypair, kind: 1, tags: [["e", parent().id, "", "root"]], content: content)
    }

    /// Scripted request: records what was sent, optionally performs the
    /// NIP-98 sign so the SIGNING → LOADING flip is observable, then
    /// returns the next scripted result.
    private final class ScriptedRequests {
        var results: [NoteReviewResult]
        var sent: [NoteReviewRequest] = []
        var signFirst = true
        init(_ results: [NoteReviewResult]) { self.results = results }
        func handler() -> (NoteReviewRequest, Nip98Signing) async -> NoteReviewResult {
            { [self] request, signer in
                sent.append(request)
                if signFirst { _ = try? await signer.signEvent(kind: 27235, content: "", tags: []) }
                return results.isEmpty ? .error(message: "unscripted") : results.removeFirst()
            }
        }
    }

    private final class ScriptedPublisher: NoteReviewReplyPublishing {
        var outcomes: [NoteReviewPublishOutcome] = []
        var publishedContents: [String] = []
        var signedRepublishes: [NostrEvent] = []
        var keypair: Keypair?
        func publish(content: String, parent: NostrEvent, keypair: Keypair) async -> NoteReviewPublishOutcome {
            publishedContents.append(content)
            self.keypair = keypair
            return outcomes.isEmpty ? .failed : outcomes.removeFirst()
        }
        func publishSigned(_ event: NostrEvent, parent: NostrEvent) async -> NoteReviewPublishOutcome {
            signedRepublishes.append(event)
            return outcomes.isEmpty ? .failed : outcomes.removeFirst()
        }
    }

    private final class MemoryPrefs: NoteReviewDisclosurePreferences {
        var stored: [NoteReview.Mode: Bool] = [:]
        func isDisclosureEnabled(_ mode: NoteReview.Mode) -> Bool { stored[mode] ?? NoteReview.defaultDisclosure(mode) }
        func setDisclosureEnabled(_ mode: NoteReview.Mode, _ enabled: Bool) { stored[mode] = enabled }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func awaitPhase(_ vm: NoteReviewViewModel, _ phases: Set<NoteReview.Phase>) async {
        for _ in 0..<200 {
            if phases.contains(vm.phase) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: applyResult

    @Test func applyResult_success_landsDraftWithTheOutput() {
        let vm = NoteReviewViewModel()
        vm.open(parent: Self.parent(), imageUrls: ["https://example.com/dish.jpg"])
        vm.applyResult(.success(output: "A lovely crust."))
        #expect(vm.phase == .draft)
        #expect(vm.draft == "A lovely crust.")
        #expect(vm.message == "")
    }

    @Test func applyResult_notMember_landsTheMessageOnlyGate() {
        let vm = NoteReviewViewModel()
        vm.applyResult(.notMember)
        #expect(vm.phase == .membersOnly)
        #expect(vm.message == "")
    }

    @Test func applyResult_membershipUnavailable_landsErrorNeverTheGate() {
        let vm = NoteReviewViewModel()
        vm.applyResult(.membershipUnavailable)
        #expect(vm.phase == .error)
        #expect(vm.message == NoteReview.membershipUnavailableLine)
        #expect(Cheffy.errorLines.contains(vm.errorLine))
    }

    @Test func applyResult_rateLimited_landsError() {
        let vm = NoteReviewViewModel()
        vm.applyResult(.rateLimited(retryAfter: 60))
        #expect(vm.phase == .error)
        #expect(vm.message == NoteReview.rateLimitedLine)
    }

    @Test func applyResult_deadEnd_landsDeadEndWithPoolLine_andConsecutiveDeadEndsRotate() {
        let vm = NoteReviewViewModel()
        var seen: [String] = []
        for _ in 0..<12 {
            vm.applyResult(.deadEnd)
            #expect(vm.phase == .deadEnd)
            #expect(NoteReview.deadEndLines.contains(vm.message))
            if let last = seen.last { #expect(vm.message != last) }
            seen.append(vm.message)
        }
    }

    @Test func applyResult_signFailed_landsErrorWithTheSignFailedLine() {
        let vm = NoteReviewViewModel()
        vm.applyResult(.signFailed)
        #expect(vm.phase == .error)
        #expect(vm.message == NoteReview.signFailedLine)
    }

    @Test func applyResult_error_rotatesTheHeadline() {
        let vm = NoteReviewViewModel()
        vm.applyResult(.error(message: "one"))
        let first = vm.errorLine
        vm.applyResult(.error(message: "two"))
        #expect(vm.errorLine != first)
        #expect(vm.message == "two")
    }

    // MARK: Draft flow

    @Test func choose_walksSigningThenLoadingThenDraft_andSendsTheSelectedImage() async throws {
        let keypair = try Self.keypair()
        let script = ScriptedRequests([.success(output: "draft")])
        let vm = NoteReviewViewModel(draftRequest: script.handler())
        vm.open(parent: Self.parent(content: "  ctx  "), imageUrls: ["https://a/1.jpg", "https://a/2.jpg"])
        vm.selectImage(1)
        vm.choose(.recipe, keypair: keypair)
        #expect(vm.phase == .signing || vm.phase == .loading || vm.phase == .draft)
        #expect(vm.mode == .recipe)
        #expect(Cheffy.cookingLines.contains(vm.loadingLine))
        await awaitPhase(vm, [.draft])
        #expect(vm.phase == .draft)
        #expect(vm.draft == "draft")
        #expect(script.sent.count == 1)
        #expect(script.sent[0].imageUrl == "https://a/2.jpg")
        #expect(script.sent[0].mode == .recipe)
        #expect(script.sent[0].noteText == "ctx")
        #expect(script.sent[0].noteId == Self.parent().id)
    }

    @Test func choose_comment_usesTheThinkingPool() throws {
        let keypair = try Self.keypair()
        let vm = NoteReviewViewModel(draftRequest: ScriptedRequests([]).handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.choose(.comment, keypair: keypair)
        #expect(Cheffy.thinkingLines.contains(vm.loadingLine))
        vm.onSheetClosed()
    }

    @Test func regenerate_reusesTheSameModeAndImage_andSkipsTheSigningPhase() async throws {
        let keypair = try Self.keypair()
        let script = ScriptedRequests([.success(output: "one"), .success(output: "two")])
        let vm = NoteReviewViewModel(draftRequest: script.handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.choose(.comment, keypair: keypair)
        await awaitPhase(vm, [.draft])
        vm.regenerate(keypair: keypair)
        #expect(vm.phase == .loading || vm.phase == .draft)
        await awaitPhase(vm, [.draft])
        #expect(vm.draft == "two")
        #expect(script.sent.count == 2)
        #expect(script.sent[1].mode == .comment)
        #expect(script.sent[1].imageUrl == "https://a/1.jpg")
    }

    @Test func regenerate_beforeAnyMode_isANoOp() throws {
        let keypair = try Self.keypair()
        let script = ScriptedRequests([.success(output: "x")])
        let vm = NoteReviewViewModel(draftRequest: script.handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.regenerate(keypair: keypair)
        #expect(vm.phase == .choose)
        #expect(script.sent.isEmpty)
    }

    @Test func emptyPrivkey_isADefensiveSignFailedError_withoutTouchingTheRequest() {
        let script = ScriptedRequests([.success(output: "x")])
        let vm = NoteReviewViewModel(draftRequest: script.handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.choose(.comment, keypair: Keypair(privkey: "", pubkey: String(repeating: "ab", count: 32)))
        #expect(vm.phase == .error)
        #expect(vm.message == NoteReview.signFailedLine)
        #expect(script.sent.isEmpty)
    }

    @Test func updateDraft_edits_andStartOverReturnsToChooseKeepingTheTargetAndSelection() {
        let vm = NoteReviewViewModel()
        let parent = Self.parent()
        vm.open(parent: parent, imageUrls: ["https://a/1.jpg", "https://a/2.jpg"])
        vm.selectImage(1)
        vm.applyResult(.success(output: "draft"))
        vm.updateDraft("my words")
        #expect(vm.draft == "my words")
        vm.startOver()
        #expect(vm.phase == .choose)
        #expect(vm.draft == "")
        #expect(vm.mode == nil)
        #expect(vm.parent?.id == parent.id)
        #expect(vm.selectedImageIndex == 1)
    }

    @Test func onSheetClosed_dropsAnInFlightResult() async throws {
        let keypair = try Self.keypair()
        let script = ScriptedRequests([.success(output: "late")])
        let vm = NoteReviewViewModel(draftRequest: script.handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.choose(.comment, keypair: keypair)
        vm.onSheetClosed()
        await settle()
        #expect(vm.draft == "")
    }

    // MARK: Publish path

    private func landDraft(_ vm: NoteReviewViewModel, text: String = "my edited reply") {
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.applyResult(.success(output: "cheffy's words"))
        vm.updateDraft(text)
    }

    @Test func post_fromDraft_publishesTheTrimmedDraft_andLandsPosted() async throws {
        let keypair = try Self.keypair()
        let publisher = ScriptedPublisher()
        let reply = try await Self.signed(keypair, content: "my edited reply")
        publisher.outcomes = [.published(reply)]
        let vm = NoteReviewViewModel()
        landDraft(vm, text: "  my edited reply \n")
        vm.post(publisher: publisher, keypair: keypair)
        #expect(vm.phase == .posting)
        await awaitPhase(vm, [.posted])
        #expect(vm.phase == .posted)
        #expect(vm.postedEvent?.id == reply.id)
        #expect(publisher.publishedContents == ["my edited reply"])
        #expect(publisher.keypair == keypair)
    }

    @Test func post_isANoOpFromEveryNonDraftPhase() async throws {
        let keypair = try Self.keypair()
        for result in [NoteReviewResult.notMember, .deadEnd, .membershipUnavailable, .error(message: "x")] {
            let publisher = ScriptedPublisher()
            let vm = NoteReviewViewModel()
            vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
            vm.applyResult(result)
            vm.updateDraft("words")
            let before = vm.phase
            vm.post(publisher: publisher, keypair: keypair)
            #expect(vm.phase == before)
            #expect(publisher.publishedContents.isEmpty)
        }
        // Choose, posting, posted and post-timeout too.
        let vm = NoteReviewViewModel()
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.updateDraft("words")
        let publisher = ScriptedPublisher()
        vm.post(publisher: publisher, keypair: keypair)
        #expect(vm.phase == .choose)
        #expect(publisher.publishedContents.isEmpty)
    }

    @Test func post_doubleTap_publishesOnce() async throws {
        let keypair = try Self.keypair()
        let publisher = ScriptedPublisher()
        let reply = try await Self.signed(keypair, content: "x")
        publisher.outcomes = [.published(reply), .published(reply)]
        let vm = NoteReviewViewModel()
        landDraft(vm)
        vm.post(publisher: publisher, keypair: keypair)
        vm.post(publisher: publisher, keypair: keypair)
        await awaitPhase(vm, [.posted])
        #expect(publisher.publishedContents.count == 1)
    }

    @Test func postTimeout_retainsTheSignedEvent_andRetryRepublishesTheSameIdWithoutResigning() async throws {
        let keypair = try Self.keypair()
        let publisher = ScriptedPublisher()
        let signed = try await Self.signed(keypair, content: "my edited reply")
        publisher.outcomes = [.timeout(signed: signed), .published(signed)]
        let vm = NoteReviewViewModel()
        landDraft(vm)
        vm.post(publisher: publisher, keypair: keypair)
        await awaitPhase(vm, [.postTimeout])
        #expect(vm.phase == .postTimeout)
        #expect(vm.timeoutSignedEvent?.id == signed.id)
        #expect(vm.message == NoteReview.postTimeoutLine)
        vm.retryPost(publisher: publisher)
        #expect(vm.phase == .posting)
        await awaitPhase(vm, [.posted])
        #expect(publisher.signedRepublishes.map(\.id) == [signed.id])
        #expect(publisher.publishedContents.count == 1, "no second sign-and-send")
        #expect(vm.postedEvent?.id == signed.id)
        #expect(vm.timeoutSignedEvent == nil)
    }

    @Test func retryPost_isANoOpOutsidePostTimeout() {
        let publisher = ScriptedPublisher()
        let vm = NoteReviewViewModel()
        landDraft(vm)
        vm.retryPost(publisher: publisher)
        #expect(vm.phase == .draft)
        #expect(publisher.signedRepublishes.isEmpty)
    }

    @Test func publishFailed_returnsToDraftWithTheDraftIntact_andTheFailedLine() async throws {
        let keypair = try Self.keypair()
        let publisher = ScriptedPublisher()
        publisher.outcomes = [.failed]
        let vm = NoteReviewViewModel()
        landDraft(vm)
        vm.post(publisher: publisher, keypair: keypair)
        await awaitPhase(vm, [.draft])
        #expect(vm.phase == .draft)
        #expect(vm.draft == "my edited reply")
        #expect(vm.postError == NoteReview.publishFailedLine)
    }

    @Test func signerRejectionDuringPosting_returnsToDraftWithTheSignFailedLine() async throws {
        let keypair = try Self.keypair()
        let publisher = ScriptedPublisher()
        publisher.outcomes = [.signRejected]
        let vm = NoteReviewViewModel()
        landDraft(vm)
        vm.post(publisher: publisher, keypair: keypair)
        await awaitPhase(vm, [.draft])
        #expect(vm.phase == .draft)
        #expect(vm.draft == "my edited reply")
        #expect(vm.postError == NoteReview.signFailedLine)
    }

    @Test func post_withBlankDraftOrEmptyPrivkey_isANoOp() throws {
        let keypair = try Self.keypair()
        let publisher = ScriptedPublisher()
        let vm = NoteReviewViewModel()
        landDraft(vm, text: "   ")
        vm.post(publisher: publisher, keypair: keypair)
        #expect(vm.phase == .draft)
        vm.updateDraft("words")
        vm.post(publisher: publisher, keypair: Keypair(privkey: "", pubkey: keypair.pubkey))
        #expect(vm.phase == .draft)
        #expect(vm.postError == NoteReview.signFailedLine)
        #expect(publisher.publishedContents.isEmpty)
    }

    // MARK: Disclosure

    @Test func choose_seedsTheToggleFromTheStoredPerModePref_elseThePerModeDefault() throws {
        let keypair = try Self.keypair()
        let prefs = MemoryPrefs()
        prefs.stored[.comment] = true
        let vm = NoteReviewViewModel(draftRequest: ScriptedRequests([]).handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.choose(.comment, keypair: keypair, prefs: prefs)
        #expect(vm.disclosureOn)
        vm.onSheetClosed()

        let vm2 = NoteReviewViewModel(draftRequest: ScriptedRequests([]).handler())
        vm2.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm2.choose(.recipe, keypair: keypair, prefs: MemoryPrefs())
        #expect(vm2.disclosureOn, "recipe defaults on")
        vm2.onSheetClosed()

        let vm3 = NoteReviewViewModel(draftRequest: ScriptedRequests([]).handler())
        vm3.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm3.choose(.comment, keypair: keypair, prefs: nil)
        #expect(!vm3.disclosureOn, "comment defaults off")
        vm3.onSheetClosed()
    }

    @Test func toggle_persistsImmediately_andRegeneratePreservesTheInSessionToggle() async throws {
        let keypair = try Self.keypair()
        let prefs = MemoryPrefs()
        let script = ScriptedRequests([.success(output: "one"), .success(output: "two")])
        let vm = NoteReviewViewModel(draftRequest: script.handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.choose(.comment, keypair: keypair, prefs: prefs)
        await awaitPhase(vm, [.draft])
        vm.toggleDisclosure(prefs: prefs)
        #expect(vm.disclosureOn)
        #expect(prefs.stored[.comment] == true)
        prefs.stored[.comment] = false // the stored pref changes underneath — the live toggle wins
        vm.regenerate(keypair: keypair)
        await awaitPhase(vm, [.draft])
        #expect(vm.draft == "two")
        #expect(vm.disclosureOn)
    }

    @Test func toggle_beforeAnyMode_isANoOp() {
        let vm = NoteReviewViewModel()
        vm.toggleDisclosure(prefs: MemoryPrefs())
        #expect(!vm.disclosureOn)
    }

    @Test func post_appendsTheFooterOnlyAtTheHandoff_neverIntoTheEditableDraft() async throws {
        let keypair = try Self.keypair()
        let publisher = ScriptedPublisher()
        let reply = try await Self.signed(keypair, content: "x")
        publisher.outcomes = [.published(reply)]
        let vm = NoteReviewViewModel(draftRequest: ScriptedRequests([.success(output: "Lovely crust!")]).handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.choose(.recipe, keypair: keypair, prefs: MemoryPrefs())
        await awaitPhase(vm, [.draft])
        #expect(vm.disclosureOn)
        #expect(vm.draft == "Lovely crust!")
        vm.post(publisher: publisher, keypair: keypair)
        await awaitPhase(vm, [.posted])
        #expect(publisher.publishedContents == ["Lovely crust!\n\n⚡🍳 via Cheffy · zap.cooking"])
        #expect(vm.draft == "Lovely crust!")
    }

    @Test func post_withToggleOff_sendsTheDraftAlone() async throws {
        let keypair = try Self.keypair()
        let publisher = ScriptedPublisher()
        let reply = try await Self.signed(keypair, content: "x")
        publisher.outcomes = [.published(reply)]
        let vm = NoteReviewViewModel(draftRequest: ScriptedRequests([.success(output: "Lovely crust!")]).handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg"])
        vm.choose(.comment, keypair: keypair, prefs: MemoryPrefs())
        await awaitPhase(vm, [.draft])
        #expect(!vm.disclosureOn)
        vm.post(publisher: publisher, keypair: keypair)
        await awaitPhase(vm, [.posted])
        #expect(publisher.publishedContents == ["Lovely crust!"])
    }

    // MARK: Picker

    @Test func picker_defaultsToTheFirstImage_selectionArmsTheNextRequest_andIgnoresOutOfRange() async throws {
        let keypair = try Self.keypair()
        let script = ScriptedRequests([.success(output: "one"), .success(output: "two")])
        let vm = NoteReviewViewModel(draftRequest: script.handler())
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg", "https://a/2.jpg"])
        #expect(vm.imageUrl == "https://a/1.jpg")
        vm.choose(.comment, keypair: keypair)
        await awaitPhase(vm, [.draft])
        vm.selectImage(1)
        #expect(vm.draft == "one", "selection only arms the next request")
        vm.selectImage(7)
        vm.selectImage(-1)
        #expect(vm.selectedImageIndex == 1)
        vm.regenerate(keypair: keypair)
        await awaitPhase(vm, [.draft])
        #expect(script.sent.map(\.imageUrl) == ["https://a/1.jpg", "https://a/2.jpg"])
        // A fresh open resets the selection.
        vm.open(parent: Self.parent(), imageUrls: ["https://a/1.jpg", "https://a/2.jpg"])
        #expect(vm.selectedImageIndex == 0)
    }

    @Test func imageUrl_isEmptyWithNoImages() {
        let vm = NoteReviewViewModel()
        vm.open(parent: Self.parent(content: "no photo"), imageUrls: [])
        #expect(vm.imageUrl == "")
    }
}
