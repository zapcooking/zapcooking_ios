import Foundation

/// Cheffy Note Photo Review — phase machine + copy pools. Port of the web
/// `src/lib/noteReview.ts` state-machine core at frontend `eb99f009`
/// (2026-08-02, "support replies to any photo"): the line pools and sheet
/// copy are the web's verbatim, and `phaseForResult` mirrors the web
/// `phaseForResult` adapted to the typed `NoteReviewResult` (Android's
/// `cheffy/NoteReview.kt` is the same port, one web revision behind).
///
/// **Membership only.** There is no upsell and no payment phase: a verified
/// non-member lands in `membersOnly`, a message-only phase reusing the
/// Cheffy chat gate copy (build spec §4.3). Nothing here names a price, an
/// invoice, or a purchase.
///
/// Pure (strings + mapping) so the sheet's tested core runs without a view.
nonisolated enum NoteReview {

    /// Draft mode. Raw values are the wire values (`mode` in the request).
    enum Mode: String, Encodable, CaseIterable, Sendable {
        case comment
        case recipe
    }

    /// Sheet phases. `MEMBERSHIP_UNAVAILABLE` deliberately maps into `error`
    /// (retryable "try again shortly"), never `membersOnly` — the endpoint
    /// fails closed on a membership-service outage, and telling a paying
    /// member they aren't a member during our outage is frontend #661.
    enum Phase: Equatable, CaseIterable, Sendable {
        case choose
        case signing
        case loading
        case draft
        case posting
        case postTimeout
        case posted
        case deadEnd
        case membersOnly
        case error
    }

    /// The only phase a publish may start from — the double-post guard
    /// (web `canPost`). Enforced in the view model, not just button state.
    static func canPost(_ phase: Phase) -> Bool { phase == .draft }

    struct PhaseAndMessage: Equatable, Sendable {
        let phase: Phase
        let message: String
    }

    // MARK: - Copy pools (web `noteReview.ts` verbatim)

    /// Hedged dead-end copy pool. The server's NOT_FOOD path also fires for
    /// CDN fallback images served in place of dead links (nostr.build never
    /// 404s), so every line stays in the "couldn't get a good look"
    /// register — never a confident "that's not food", and the model's line
    /// is never echoed (structurally impossible: `NoteReviewResult.deadEnd`
    /// carries no message). Rotated via `Cheffy.pickLine` so consecutive
    /// dead-ends don't repeat verbatim.
    static let deadEndLines: [String] = [
        "Cheffy couldn't get a clear enough look at that photo. The link may be broken or the details didn't come through.",
        "That photo's playing hard to get — Cheffy can't quite make out enough detail.",
        "Cheffy squinted, but the photo may not have come through clearly.",
        "Hmm — Cheffy couldn't see this one clearly. The link may be stale or the image is hiding its details.",
    ]

    static let signFailedLine =
        "Cheffy couldn't get your signer's autograph. Check your signer and try again."

    static let genericErrorLine = "Cheffy could not finish that one. Please try again."

    /// On web these two arrive as the server's `error` string through
    /// `phaseForResult`'s default arm; the typed result carries no message,
    /// so the same copy is pinned here (server lines, verbatim).
    static let rateLimitedLine =
        "Cheffy needs a breather — you've hit the photo-review limit for now."
    static let membershipUnavailableLine =
        "Cheffy can't check your membership right now. Please try again shortly."

    /// Web `POST_TIMEOUT_LINE`.
    static let postTimeoutLine =
        "The relays are taking their time. Your reply is signed and may already be out there — give it another push, and Cheffy won't ask your signer twice."

    /// Web `PUBLISH_FAILED_LINE`.
    static let publishFailedLine =
        "The relays didn't take that one. Your draft is safe — give it another go."

    /// Server `NOTE_TEXT_MAX_CHARS` — the client caps to match BEFORE
    /// signing (the payload hash binds the signature to the exact bytes).
    static let noteTextMaxChars = 1000

    // MARK: - Sheet copy (web `CheffyNoteReview.svelte` verbatim)

    static let sheetTitle = "Ask Cheffy about this photo"
    /// Menu / action-row entry (web `PostActionsMenu` + trigger `aria-label`).
    static let entryTitle = "Ask Cheffy about this photo"
    static let chooseHint = "What should Cheffy draft? You'll edit it before anything is posted."
    static let commentCardTitle = "Say something nice"
    static let commentCardSubtitle = "A short, thoughtful comment about the photo"
    static let recipeCardTitle = "Identify any dish"
    static let recipeCardSubtitle = "For food photos, identify it and draft a recipe"
    static let signingLine = "Waiting for your signer to approve…"
    static let signingSubline = "Using a remote signer? This can take a few seconds."
    static let draftHint = "Cheffy's draft — make it yours, then post it as your own reply."
    static let disclosureToggleLabel = "Add a small \"via Cheffy\" note"
    static let footerPreviewLabel = "Added when you post:"
    static let postedLine = "Posted! Cheffy tips his toque to you."

    // MARK: - Disclosure footer

    /// Appended at publish time when the member's toggle is on — NEVER
    /// embedded in the editable draft (the sheet shows it as a separate
    /// non-editable preview). Exact string is part of the product spec.
    static let disclosureFooter = "⚡🍳 via Cheffy · zap.cooking"

    private static let trailingWhitespace = try! NSRegularExpression(pattern: #"\s+$"#)

    /// Build the publish content: the member's draft, untouched, plus the
    /// footer on its own line after one blank line when the toggle is on.
    /// Trailing whitespace on the draft is normalized so the footer never
    /// drifts more than one blank line away. Verbatim port of
    /// `withDisclosureFooter`.
    static func withDisclosureFooter(_ draft: String, on: Bool) -> String {
        if !on { return draft }
        let range = NSRange(draft.startIndex..., in: draft)
        let trimmed = trailingWhitespace.stringByReplacingMatches(in: draft, range: range, withTemplate: "")
        return trimmed + "\n\n" + disclosureFooter
    }

    /// Per-mode defaults, deliberate (web `DISCLOSURE_DEFAULTS`): a recipe
    /// is Cheffy's structured work product (attribution on), a comment is
    /// the member's own voice (off).
    static func defaultDisclosure(_ mode: Mode) -> Bool { mode == .recipe }

    /// The stored preference seeds the toggle only on the initial mode
    /// selection (from the choose phase). Regenerate / try-again re-runs
    /// must preserve the member's in-session toggle — the live toggle
    /// state is the fresher signal. Port of `shouldSeedDisclosureFromPref`.
    static func shouldSeedDisclosureFromPref(_ phase: Phase) -> Bool { phase == .choose }

    // MARK: - Phase mapping

    /// Map a request result to the sheet phase and its display message —
    /// the tested core of the state machine (web `phaseForResult`).
    /// `avoidDeadEndLine` is the previously shown dead-end line, so
    /// consecutive dead-ends rotate. `randomIndex` is the test seam for the
    /// rotation.
    static func phaseForResult(
        _ result: NoteReviewResult,
        avoidDeadEndLine: String? = nil,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> PhaseAndMessage {
        switch result {
        case .success:
            return PhaseAndMessage(phase: .draft, message: "")
        case .notMember:
            // Message-only gate; the sheet renders `Cheffy.membersOnlyMessage`.
            return PhaseAndMessage(phase: .membersOnly, message: "")
        case .deadEnd:
            return PhaseAndMessage(
                phase: .deadEnd,
                message: Cheffy.pickLine(deadEndLines, avoid: avoidDeadEndLine, randomIndex: randomIndex)
            )
        case .signFailed:
            return PhaseAndMessage(phase: .error, message: signFailedLine)
        case .membershipUnavailable:
            return PhaseAndMessage(phase: .error, message: membershipUnavailableLine)
        case .rateLimited:
            return PhaseAndMessage(phase: .error, message: rateLimitedLine)
        case .error(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return PhaseAndMessage(phase: .error, message: trimmed.isEmpty ? genericErrorLine : trimmed)
        }
    }
}

/// Outcome of a note-review draft request. Mirrors the server's typed
/// failures; `NoteReview.phaseForResult` maps these onto sheet phases.
nonisolated enum NoteReviewResult: Equatable, Sendable {
    /// A draft was produced.
    case success(output: String)
    /// 403 `NOT_MEMBER` — render the message-only members gate.
    case notMember
    /// 503 `MEMBERSHIP_UNAVAILABLE` — the endpoint fails CLOSED on a
    /// membership-service outage. Retryable error, NEVER the members gate.
    case membershipUnavailable
    /// 429 — per-pubkey budget (8/hour, 30/day; regenerates share it).
    case rateLimited(retryAfter: TimeInterval?)
    /// 422 `NOT_FOOD` / `IMAGE_UNREADABLE`, collapsed: the sheet shows a
    /// local hedged line — this case carries no message by design so the
    /// server's text can never leak through.
    case deadEnd
    /// The signer could not produce the NIP-98 header, or the server
    /// rejected it — "your signer, not the relays".
    case signFailed
    case error(message: String)
}
