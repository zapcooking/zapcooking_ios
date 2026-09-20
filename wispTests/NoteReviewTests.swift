import Foundation
import Testing
@testable import wisp

/// `NoteReview` — the pure core of the sheet's state machine, mirroring the
/// web `noteReview.test.ts` cases and pinning the copy pools verbatim at
/// frontend `eb99f009`.
struct NoteReviewTests {

    @Test func deadEndLinesAreTheWebPoolVerbatim() {
        #expect(NoteReview.deadEndLines == [
            "Cheffy couldn't get a clear enough look at that photo. The link may be broken or the details didn't come through.",
            "That photo's playing hard to get — Cheffy can't quite make out enough detail.",
            "Cheffy squinted, but the photo may not have come through clearly.",
            "Hmm — Cheffy couldn't see this one clearly. The link may be stale or the image is hiding its details.",
        ])
    }

    /// The dead-end register: never a confident "not food", and no line
    /// mentions a dish — the server's NOT_FOOD path also fires for CDN
    /// fallback images in place of dead links.
    @Test func deadEndLinesStayInTheCouldntGetAGoodLookRegister() {
        for line in NoteReview.deadEndLines {
            let lower = line.lowercased()
            #expect(!lower.contains("not food"))
            #expect(!lower.contains("isn't food"))
            #expect(!lower.contains("dish"))
            #expect(lower.contains("photo") || lower.contains("see") || lower.contains("look"))
        }
    }

    @Test func sheetCopyIsTheWebCopyVerbatim() {
        #expect(NoteReview.sheetTitle == "Ask Cheffy about this photo")
        #expect(NoteReview.entryTitle == "Ask Cheffy about this photo")
        #expect(NoteReview.chooseHint == "What should Cheffy draft? You'll edit it before anything is posted.")
        #expect(NoteReview.commentCardTitle == "Say something nice")
        #expect(NoteReview.commentCardSubtitle == "A short, thoughtful comment about the photo")
        #expect(NoteReview.recipeCardTitle == "Identify any dish")
        #expect(NoteReview.recipeCardSubtitle == "For food photos, identify it and draft a recipe")
        #expect(NoteReview.draftHint == "Cheffy's draft — make it yours, then post it as your own reply.")
        #expect(NoteReview.disclosureToggleLabel == "Add a small \"via Cheffy\" note")
        #expect(NoteReview.postedLine == "Posted! Cheffy tips his toque to you.")
        #expect(NoteReview.signingLine == "Waiting for your signer to approve…")
    }

    @Test func success_mapsToDraft() {
        let next = NoteReview.phaseForResult(.success(output: "A draft"))
        #expect(next == NoteReview.PhaseAndMessage(phase: .draft, message: ""))
    }

    @Test func notMember_mapsToTheMessageOnlyGate() {
        #expect(NoteReview.phaseForResult(.notMember) == NoteReview.PhaseAndMessage(phase: .membersOnly, message: ""))
    }

    @Test func deadEnd_mapsToDeadEnd_withALineFromThePool() {
        let next = NoteReview.phaseForResult(.deadEnd)
        #expect(next.phase == .deadEnd)
        #expect(NoteReview.deadEndLines.contains(next.message))
    }

    @Test func deadEnd_rotatesAwayFromThePreviousLine() {
        for previous in NoteReview.deadEndLines {
            for roll in 0..<NoteReview.deadEndLines.count {
                let next = NoteReview.phaseForResult(.deadEnd, avoidDeadEndLine: previous, randomIndex: { _ in roll })
                #expect(next.message != previous)
                #expect(NoteReview.deadEndLines.contains(next.message))
            }
        }
    }

    @Test func signFailed_mapsToError_withTheSignFailedLine() {
        #expect(NoteReview.phaseForResult(.signFailed) == NoteReview.PhaseAndMessage(phase: .error, message: NoteReview.signFailedLine))
    }

    @Test func membershipUnavailable_isRetryableError_neverTheMembersGate() {
        // The endpoint fails closed on a membership-service outage — a
        // members-only screen here would tell a paying member they aren't
        // one during our outage (frontend #661).
        let next = NoteReview.phaseForResult(.membershipUnavailable)
        #expect(next.phase == .error)
        #expect(next.phase != .membersOnly)
        #expect(next.message == NoteReview.membershipUnavailableLine)
    }

    @Test func rateLimited_mapsToError_withTheBreatherLine() {
        #expect(NoteReview.phaseForResult(.rateLimited(retryAfter: 1800)) == NoteReview.PhaseAndMessage(phase: .error, message: NoteReview.rateLimitedLine))
    }

    @Test func error_mapsToError_passingTheMessageThrough() {
        #expect(NoteReview.phaseForResult(.error(message: "Network error")) == NoteReview.PhaseAndMessage(phase: .error, message: "Network error"))
    }

    @Test func blankErrorMessage_fallsBackToTheGenericLine() {
        #expect(NoteReview.phaseForResult(.error(message: "  ")) == NoteReview.PhaseAndMessage(phase: .error, message: NoteReview.genericErrorLine))
    }

    @Test func canPost_isTrueOnlyForDraft() {
        for phase in NoteReview.Phase.allCases {
            #expect(NoteReview.canPost(phase) == (phase == .draft))
        }
    }

    /// Membership only: the phase set has no upsell and no payment state.
    @Test func phaseMachineHasNoUpsellAndNoPaying() {
        let names = NoteReview.Phase.allCases.map { String(describing: $0).lowercased() }
        #expect(names == ["choose", "signing", "loading", "draft", "posting", "posttimeout", "posted", "deadend", "membersonly", "error"])
        #expect(!names.contains { $0.contains("upsell") || $0.contains("pay") })
    }

    @Test func publishLinesAreTheWebCopyVerbatim() {
        #expect(NoteReview.postTimeoutLine == "The relays are taking their time. Your reply is signed and may already be out there — give it another push, and Cheffy won't ask your signer twice.")
        #expect(NoteReview.publishFailedLine == "The relays didn't take that one. Your draft is safe — give it another go.")
    }

    // MARK: Disclosure footer

    @Test func disclosureFooterStringIsTheProductSpecVerbatim() {
        #expect(NoteReview.disclosureFooter == "⚡🍳 via Cheffy · zap.cooking")
    }

    @Test func withDisclosureFooter_off_returnsTheDraftUntouched() {
        #expect(NoteReview.withDisclosureFooter("my words", on: false) == "my words")
        #expect(NoteReview.withDisclosureFooter("my words  \n", on: false) == "my words  \n")
    }

    @Test func withDisclosureFooter_on_appendsAfterExactlyOneBlankLine() {
        #expect(NoteReview.withDisclosureFooter("Lovely crust!", on: true) == "Lovely crust!\n\n⚡🍳 via Cheffy · zap.cooking")
    }

    @Test func withDisclosureFooter_normalizesTrailingWhitespaceSoTheFooterNeverDrifts() {
        #expect(NoteReview.withDisclosureFooter("draft words \n\n\t ", on: true) == "draft words\n\n⚡🍳 via Cheffy · zap.cooking")
    }

    @Test func disclosureDefaultsArePerMode_commentOff_recipeOn() {
        #expect(!NoteReview.defaultDisclosure(.comment))
        #expect(NoteReview.defaultDisclosure(.recipe))
    }

    @Test func disclosureSeedsFromThePrefOnlyInChoose() {
        for phase in NoteReview.Phase.allCases {
            #expect(NoteReview.shouldSeedDisclosureFromPref(phase) == (phase == .choose))
        }
    }

    @Test func modeWireValuesMatchTheWebContract() {
        #expect(NoteReview.Mode.comment.rawValue == "comment")
        #expect(NoteReview.Mode.recipe.rawValue == "recipe")
    }

    // MARK: Preferences

    @Test func preferences_defaultPerMode_thenPersistPerPubkey() {
        let suite = "NoteReviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = NoteReviewPreferences(pubkey: "aa", defaults: defaults)
        let b = NoteReviewPreferences(pubkey: "bb", defaults: defaults)
        #expect(!a.isDisclosureEnabled(.comment))
        #expect(a.isDisclosureEnabled(.recipe))
        a.setDisclosureEnabled(.comment, true)
        a.setDisclosureEnabled(.recipe, false)
        #expect(a.isDisclosureEnabled(.comment))
        #expect(!a.isDisclosureEnabled(.recipe))
        // Another account keeps the defaults — no leak across a switch.
        #expect(!b.isDisclosureEnabled(.comment))
        #expect(b.isDisclosureEnabled(.recipe))
    }
}
