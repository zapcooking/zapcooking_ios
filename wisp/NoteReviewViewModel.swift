import Foundation
import Observation

/// Cheffy Note Photo Review — sheet state (port of Android
/// `NoteReviewViewModel`, credits removed).
///
/// The pure phase mapping lives in `NoteReview.phaseForResult`; this class
/// owns the session state around it: the target note, the in-flight
/// request, the editable draft, and the rotation memory for dead-end /
/// error lines.
///
/// Signing ≠ loading: `choose` enters `.signing` and the delegating signer
/// flips to `.loading` the moment the kind-27235 sign completes — the user
/// sees whose turn it is. `regenerate` enters `.loading` directly: within
/// the NIP-98 header cache's TTL a regenerate performs no sign at all.
///
/// Membership only: a `notMember` result lands in `.membersOnly`, a
/// message-only phase. There is no upsell, no invoice, no balance.
@Observable
@MainActor
final class NoteReviewViewModel {

    private(set) var phase: NoteReview.Phase = .choose
    /// Selected draft mode; retained across regenerates (web parity).
    private(set) var mode: NoteReview.Mode?
    /// The editable draft. Owned here so edits survive re-rendering.
    private(set) var draft: String = ""
    /// Dead-end line, error sub-message, or post-timeout line.
    private(set) var message: String = ""
    /// Rotating Cheffy-voice headline for the error phase.
    private(set) var errorLine: String = ""
    /// Thinking/cooking line shown during LOADING; picked per run.
    private(set) var loadingLine: String = ""
    /// Publish failure line shown inside the draft phase.
    private(set) var postError: String = ""
    /// The just-published reply — drives the POSTED link.
    private(set) var postedEvent: NostrEvent?
    /// The SIGNED event a timed-out publish retained — retry re-broadcasts
    /// exactly this, same id, no re-sign.
    private(set) var timeoutSignedEvent: NostrEvent?
    /// "Via Cheffy" disclosure toggle. Applied to the content string ONLY
    /// at the `post` hand-off — never part of `draft`.
    private(set) var disclosureOn: Bool = false
    // Session target — set by `open`, constant until the next open.
    private(set) var parent: NostrEvent?
    /// All detected images, in note order (the picker strip).
    private(set) var imageUrls: [String] = []
    /// Picker selection. Persists across regenerates and Start over; only
    /// `open` (a fresh sheet) resets it. One imageUrl per request.
    private(set) var selectedImageIndex: Int = 0

    /// The image the next request sends — the selected one.
    var imageUrl: String {
        if imageUrls.indices.contains(selectedImageIndex) { return imageUrls[selectedImageIndex] }
        return imageUrls.first ?? ""
    }

    @ObservationIgnored private let draftRequest: (NoteReviewRequest, Nip98Signing) async -> NoteReviewResult
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var postTask: Task<Void, Never>?
    /// Rotation memory so consecutive dead-ends never repeat verbatim.
    @ObservationIgnored private var lastDeadEndLine: String?

    init(draftRequest: ((NoteReviewRequest, Nip98Signing) async -> NoteReviewResult)? = nil) {
        self.draftRequest = draftRequest ?? { await NoteReviewService().draft($0, signer: $1) }
    }

    // MARK: - Session

    /// Configure the sheet for a note and reset to CHOOSE. `parent` is the
    /// kind-1 being reviewed — its content/id feed the draft request and it
    /// anchors the reply. `imageUrls` are the note's detected images in
    /// order; requests use the picker selection (index 0 until the member
    /// picks another).
    func open(parent: NostrEvent, imageUrls: [String]) {
        cancelAllWork()
        reset(parent: parent, imageUrls: imageUrls, selectedImageIndex: 0)
    }

    /// The sheet was dismissed. Stops in-flight work so nothing outlives
    /// the session.
    func onSheetClosed() {
        cancelAllWork()
    }

    private func cancelAllWork() {
        requestTask?.cancel()
        postTask?.cancel()
        requestTask = nil
        postTask = nil
    }

    private func reset(parent: NostrEvent?, imageUrls: [String], selectedImageIndex: Int) {
        phase = .choose
        mode = nil
        draft = ""
        message = ""
        errorLine = ""
        loadingLine = ""
        postError = ""
        postedEvent = nil
        timeoutSignedEvent = nil
        disclosureOn = false
        self.parent = parent
        self.imageUrls = imageUrls
        self.selectedImageIndex = selectedImageIndex
    }

    /// Pick which photo Cheffy looks at. Selection only ARMS the next
    /// request (web parity): an existing draft stays until the member
    /// regenerates.
    func selectImage(_ index: Int) {
        guard imageUrls.indices.contains(index) else { return }
        selectedImageIndex = index
    }

    /// Toggle the "via Cheffy" disclosure and persist it immediately for
    /// the current mode (web `toggleDisclosure`).
    func toggleDisclosure(prefs: NoteReviewDisclosurePreferences? = nil) {
        guard let mode else { return }
        disclosureOn.toggle()
        prefs?.setDisclosureEnabled(mode, disclosureOn)
    }

    /// Initial mode selection from the CHOOSE phase. Seeds the disclosure
    /// toggle from the stored per-mode preference — ONLY here (web
    /// `shouldSeedDisclosureFromPref`): regenerates and error-retries go
    /// through `regenerate`, which preserves the in-session toggle.
    func choose(_ mode: NoteReview.Mode, keypair: Keypair, prefs: NoteReviewDisclosurePreferences? = nil) {
        if NoteReview.shouldSeedDisclosureFromPref(phase) {
            disclosureOn = prefs?.isDisclosureEnabled(mode) ?? NoteReview.defaultDisclosure(mode)
        }
        run(mode, keypair: keypair, showSigning: true)
    }

    /// Re-run with the SAME mode and image (draft phase "Regenerate" and
    /// error phase "Try again" — web wires both to `run(mode)`). No-op
    /// before any mode was chosen.
    func regenerate(keypair: Keypair) {
        guard let mode else { return }
        run(mode, keypair: keypair, showSigning: false)
    }

    func updateDraft(_ text: String) {
        draft = text
    }

    /// Back to CHOOSE for the same note, dropping the draft (web `reset`).
    /// The picker selection survives (only closing the sheet — the next
    /// `open` — resets it); the disclosure toggle re-seeds from the stored
    /// preference on the next `choose`.
    func startOver() {
        cancelAllWork()
        reset(parent: parent, imageUrls: imageUrls, selectedImageIndex: selectedImageIndex)
    }

    // MARK: - Publish path

    /// Publish the member-edited draft as a NIP-10 reply to the parent.
    /// Hard-gated on `NoteReview.canPost` — POSTING is entered
    /// synchronously, so a second call (double-tap, re-entry) is a no-op
    /// regardless of button state.
    func post(publisher: any NoteReviewReplyPublishing, keypair: Keypair) {
        guard NoteReview.canPost(phase), let parent else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        if keypair.privkey.isEmpty {
            postError = NoteReview.signFailedLine
            return
        }
        // The disclosure footer joins the content ONLY here, at the
        // hand-off to the publisher — never inside the editable draft. It
        // is thereby baked into the SIGNED event, so the timeout retry path
        // (publishSigned) never touches it again.
        let content = NoteReview.withDisclosureFooter(trimmed, on: disclosureOn)
        phase = .posting
        postError = ""
        postTask?.cancel()
        postTask = Task { [weak self] in
            let outcome = await publisher.publish(content: content, parent: parent, keypair: keypair)
            guard !Task.isCancelled else { return }
            self?.applyPublishOutcome(outcome)
        }
    }

    /// Timeout recovery: re-broadcast the retained SIGNED event — same id
    /// (relays dedupe), no second signer round trip. Only legal from
    /// POST_TIMEOUT.
    func retryPost(publisher: any NoteReviewReplyPublishing) {
        guard phase == .postTimeout, let signed = timeoutSignedEvent, let parent else { return }
        phase = .posting
        postTask?.cancel()
        postTask = Task { [weak self] in
            let outcome = await publisher.publishSigned(signed, parent: parent)
            guard !Task.isCancelled else { return }
            self?.applyPublishOutcome(outcome)
        }
    }

    /// Land a publish outcome. Internal so the POSTING → POSTED /
    /// POST_TIMEOUT / back-to-DRAFT mapping is unit-testable without relays.
    func applyPublishOutcome(_ outcome: NoteReviewPublishOutcome) {
        switch outcome {
        case .published(let event):
            phase = .posted
            postedEvent = event
            timeoutSignedEvent = nil
            postError = ""
            message = ""
        case .timeout(let signed):
            phase = .postTimeout
            timeoutSignedEvent = signed
            message = NoteReview.postTimeoutLine
        // Draft intact on both: publish-failed is a relay problem,
        // sign-rejected is the member's choice — neither destroys their
        // edited words.
        case .failed:
            phase = .draft
            postError = NoteReview.publishFailedLine
        case .signRejected:
            phase = .draft
            postError = NoteReview.signFailedLine
        }
    }

    // MARK: - Draft request

    private func run(_ mode: NoteReview.Mode, keypair: Keypair, showSigning: Bool) {
        // Defensive only — the trigger is hidden for watch-only accounts, so
        // an empty privkey here is a wiring bug, surfaced in Cheffy voice.
        if keypair.privkey.isEmpty {
            phase = .error
            self.mode = mode
            message = NoteReview.signFailedLine
            errorLine = Cheffy.pickLine(Cheffy.errorLines, avoid: errorLine)
            return
        }
        phase = showSigning ? .signing : .loading
        self.mode = mode
        postError = ""
        // Recipe drafts get the "cooking" pool, comments the "thinking" pool
        // (web parity); avoid the previous line.
        loadingLine = Cheffy.pickLine(
            mode == .recipe ? Cheffy.cookingLines : Cheffy.thinkingLines,
            avoid: loadingLine
        )
        let request = NoteReviewService.request(
            imageUrl: imageUrl, mode: mode, noteText: parent?.content, noteId: parent?.id
        )
        // Flip SIGNING → LOADING the instant the NIP-98 sign completes: the
        // signer itself reports completion.
        // `self` is a main-actor class (implicitly Sendable); the signer
        // lives only as long as the request task, so the strong capture
        // ends with it.
        let owner = self
        let signer = OnSignedNip98Signer(delegate: LocalNip98Signer(keypair: keypair)) {
            Task { @MainActor in owner.markSigned() }
        }
        requestTask?.cancel()
        requestTask = Task { [weak self, draftRequest] in
            let result = await draftRequest(request, signer)
            guard !Task.isCancelled else { return }
            self?.applyResult(result)
        }
    }

    private func markSigned() {
        if phase == .signing { phase = .loading }
    }

    /// Land a request result in the state machine. Internal so the full
    /// result → phase mapping is unit-testable without HTTP.
    func applyResult(_ result: NoteReviewResult) {
        let next = NoteReview.phaseForResult(result, avoidDeadEndLine: lastDeadEndLine)
        if next.phase == .deadEnd { lastDeadEndLine = next.message }
        if next.phase == .error {
            errorLine = Cheffy.pickLine(Cheffy.errorLines, avoid: errorLine)
        }
        switch result {
        case .success(let output):
            phase = next.phase
            message = ""
            draft = output
        default:
            phase = next.phase
            message = next.message
        }
    }
}

/// `Nip98Signing` wrapper that reports each completed sign — how the sheet
/// observes "the signer approved" (SIGNING → LOADING) without the API layer
/// growing a callback.
nonisolated struct OnSignedNip98Signer: Nip98Signing {
    let delegate: any Nip98Signing
    let onSigned: @Sendable () -> Void

    var pubkeyHex: String { delegate.pubkeyHex }

    func signEvent(kind: Int, content: String, tags: [[String]]) async throws -> NostrEvent {
        let event = try await delegate.signEvent(kind: kind, content: content, tags: tags)
        onSigned()
        return event
    }
}
