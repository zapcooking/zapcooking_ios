import Foundation
import CoreGraphics
import Testing
@testable import wisp

/// The composer's attachment model (docs/attachment-model.md): an
/// attachment is a slot on the draft, not text in the editor. These pin
/// the two pure functions that bridge the two at publish time, the alt
/// rules (empty emits nothing, cap by grapheme clusters), the reorder
/// splice, and the boundary-only migration strip. Hermetic.
@MainActor
struct AttachmentModelTests {

    private func media(_ url: String?, alt: String = "", mime: String = "image/jpeg") -> ComposeAttachment {
        ComposeAttachment(
            id: UUID(), url: url, mime: mime,
            dim: CGSize(width: 100, height: 50),
            durationSec: nil, sha256Hex: "cafe01",
            localBytes: nil, altText: alt.isEmpty ? nil : alt
        )
    }

    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    /// Fresh composer with an empty autosave bucket, the
    /// `ComposeToolbarTests` pattern.
    private func composer(mode: ComposeMode = .new) -> ComposeViewModel {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: "compose_autosave_new_\(kp.pubkey)")
        return ComposeViewModel(keypair: kp, mode: mode)
    }

    // MARK: - composeNoteContent

    @Test func composeNoteContent_proseThenUrls_blankLineBetween() {
        let out = AttachmentModel.composeNoteContent(
            text: "Soup night",
            media: [media("https://x/a.jpg"), media("https://x/b.jpg")]
        )
        #expect(out == "Soup night\n\nhttps://x/a.jpg\nhttps://x/b.jpg")
    }

    @Test func composeNoteContent_urlsOnly_noLeadingBlankLine() {
        let out = AttachmentModel.composeNoteContent(
            text: "  ",
            media: [media("https://x/a.jpg"), media("https://x/b.jpg")]
        )
        #expect(out == "https://x/a.jpg\nhttps://x/b.jpg")
    }

    @Test func composeNoteContent_proseOnly_trimmed() {
        #expect(AttachmentModel.composeNoteContent(text: " hi \n", media: []) == "hi")
        #expect(AttachmentModel.composeNoteContent(text: "", media: []) == "")
    }

    /// Uploading slots (url nil) contribute nothing — publish is gated on
    /// uploads finishing, but the function doesn't assume the gate held.
    @Test func composeNoteContent_pendingUploadsFiltered() {
        let out = AttachmentModel.composeNoteContent(
            text: "hi",
            media: [media(nil), media("https://x/a.jpg"), media("")]
        )
        #expect(out == "hi\n\nhttps://x/a.jpg")
    }

    /// The array's order is the only ordering that exists.
    @Test func composeNoteContent_orderIsArrayOrder() {
        let out = AttachmentModel.composeNoteContent(
            text: "hi",
            media: [media("https://x/b.jpg"), media("https://x/a.jpg")]
        )
        #expect(out == "hi\n\nhttps://x/b.jpg\nhttps://x/a.jpg")
    }

    // MARK: - imeta at publish: one tag per DESCRIBED attachment

    @Test func imetaTags_undescribedMediaContributesNothing() {
        #expect(AttachmentModel.imetaTags(for: [media("https://x/a.jpg")]) == [])
        #expect(AttachmentModel.imetaTags(for: [media("https://x/a.jpg", alt: "  ")]) == [])
        #expect(AttachmentModel.imetaTags(for: [media(nil, alt: "described but uploading")]) == [])
    }

    @Test func imetaTags_describedInDraftOrder_withUrlAndAlt() {
        let tags = AttachmentModel.imetaTags(for: [
            media("https://x/a.jpg", alt: "charred leeks"),
            media("https://x/b.jpg"),
            media("https://x/c.mp4", alt: "the pour", mime: "video/mp4"),
        ])
        #expect(tags.count == 2)
        // url leads, alt rides LAST (the Amethyst/Quartz ordering #137
        // standardized on), metadata in between.
        #expect(tags[0].first == "imeta")
        #expect(tags[0][1] == "url https://x/a.jpg")
        #expect(tags[0].last == "alt charred leeks")
        #expect(tags[1].first == "imeta")
        #expect(tags[1][1] == "url https://x/c.mp4")
        #expect(tags[1].last == "alt the pour")
        // Metadata we already know rides along on described entries.
        #expect(tags[0].contains("m image/jpeg"))
        #expect(tags[0].contains("dim 100x50"))
        #expect(tags[0].contains("x cafe01"))
    }

    /// The description follows its image through a reorder for free:
    /// same array, spliced, tags come back spliced.
    @Test func imetaTags_reorderCarriesDescriptions() {
        var strip = [media("https://x/a.jpg", alt: "leeks"), media("https://x/b.jpg", alt: "broth")]
        let moved = strip.remove(at: 0)
        strip.insert(moved, at: 1)
        let tags = AttachmentModel.imetaTags(for: strip)
        #expect(tags.map { $0[1] } == ["url https://x/b.jpg", "url https://x/a.jpg"])
        #expect(tags[0].last == "alt broth")
        #expect(tags[1].last == "alt leeks")
    }

    // MARK: - Draft imeta: full metadata for every upload

    @Test func draftImetaTags_everyUploadDescribedOrNot() {
        let tags = AttachmentModel.draftImetaTags(for: [
            media("https://x/a.jpg"),
            media("https://x/b.jpg", alt: "broth"),
        ])
        #expect(tags.count == 2)
        #expect(tags[0].starts(with: ["imeta", "url https://x/a.jpg", "m image/jpeg"]))
        #expect(!tags[0].contains { $0.hasPrefix("alt ") })
        #expect(tags[1].contains("alt broth"))
    }

    /// Round-trip: what `draftImetaTags` writes, `parseImetaAttachments`
    /// reads back — description included.
    @Test func draftImetaRoundTrip_restoresAlt() {
        let source = [media("https://x/a.jpg", alt: "charred leeks")]
        let restored = ComposeViewModel.parseImetaAttachments(
            tags: AttachmentModel.draftImetaTags(for: source)
        )
        #expect(restored.count == 1)
        #expect(restored[0].url == "https://x/a.jpg")
        #expect(restored[0].altText == "charred leeks")
        #expect(restored[0].mime == "image/jpeg")
        #expect(restored[0].dim == CGSize(width: 100, height: 50))
        #expect(restored[0].sha256Hex == "cafe01")
    }

    // MARK: - Alt clamping

    /// Cap by grapheme clusters, never splitting a surrogate pair: a
    /// description of 2001 emoji still ships 2000 whole ones.
    @Test func normalizedAlt_clampsByGraphemes_notCodeUnits() {
        let emoji = String(repeating: "🍲", count: AttachmentModel.maxAltGraphemes + 1)
        let clamped = AttachmentModel.normalizedAlt(emoji)
        #expect(clamped.count == AttachmentModel.maxAltGraphemes)
        #expect(clamped.allSatisfy { $0 == "🍲" })
    }

    @Test func normalizedAlt_flattensLineBreaks() {
        #expect(AttachmentModel.normalizedAlt("two\nlines\r\nhere\rend") == "two lines here end")
        #expect(AttachmentModel.normalizedAlt("") == "")
    }

    // MARK: - Migration: strip boundary occurrences only

    @Test func stripBoundaryLines_removesUrlAloneOnItsLine() {
        let out = AttachmentModel.stripBoundaryAttachmentLines(
            content: "look\nhttps://x/a.jpg\n\nhttps://x/b.jpg\ndone",
            urls: ["https://x/a.jpg", "https://x/b.jpg"]
        )
        #expect(out == "look\n\ndone")
    }

    @Test func stripBoundaryLines_leavesAuthoredProse() {
        let content = "mirror at https://x/a.png if the first dies\nhttps://x/a.png\nu1 u1"
        let out = AttachmentModel.stripBoundaryAttachmentLines(content: content, urls: ["https://x/a.png"])
        #expect(out == "mirror at https://x/a.png if the first dies\nu1 u1")
    }

    @Test func stripBoundaryLines_noUrls_noChange() {
        #expect(AttachmentModel.stripBoundaryAttachmentLines(content: "hi", urls: []) == "hi")
        #expect(AttachmentModel.stripBoundaryAttachmentLines(content: "hi\nhttps://x/a.jpg", urls: []) == "hi\nhttps://x/a.jpg")
    }

    // MARK: - The splice

    @Test func moveMedia_spliceSemantics() {
        let vm = composer()
        vm.attachments = [media("a"), media("b"), media("c")]
        vm.moveMedia(from: 0, to: 2)
        #expect(vm.attachments.map(\.url) == ["b", "c", "a"])
        vm.moveMedia(from: 2, to: 0)
        #expect(vm.attachments.map(\.url) == ["a", "b", "c"])
        // Out-of-range and no-op calls leave the array alone.
        vm.moveMedia(from: 0, to: 5)
        vm.moveMedia(from: 1, to: 1)
        vm.moveMedia(from: -1, to: 0)
        #expect(vm.attachments.map(\.url) == ["a", "b", "c"])
    }

    @Test func moveMedia_byId_movesTheSlotNotTheDescription() {
        let vm = composer()
        let first = media("a", alt: "leeks")
        let second = media("b", alt: "broth")
        vm.attachments = [first, second]
        vm.moveMedia(id: second.id, before: first.id)
        #expect(vm.attachments.map(\.url) == ["b", "a"])
        #expect(vm.attachments[0].altText == "broth")
        #expect(vm.attachments[1].altText == "leeks")
    }

    @Test func setAlt_writesTheSlot() {
        let vm = composer()
        let a = media("a")
        vm.attachments = [a]
        vm.setAltText("mise en place", for: a.id)
        #expect(vm.attachments[0].trimmedAltText == "mise en place")
        vm.setAltText("gone", for: UUID())  // unknown id: no-op, no crash
        #expect(vm.attachments[0].trimmedAltText == "mise en place")
    }

    // MARK: - Publish path

    /// Preview shows the note that will go out — both call the same
    /// `composeNoteContent`.
    @Test func previewContent_isComposeNoteContent() {
        let vm = composer()
        vm.updateContent("Soup night")
        vm.attachments = [media("https://x/a.jpg"), media("https://x/b.jpg")]
        #expect(vm.previewContent == "Soup night\n\nhttps://x/a.jpg\nhttps://x/b.jpg")
    }

    @Test func publishTags_carryAltForTextNotes_onlyWhenDescribed() {
        let vm = composer()
        vm.updateContent("Soup night")
        vm.attachments = [media("https://x/a.jpg", alt: "charred leeks"), media("https://x/b.jpg")]
        let tags = vm.buildBaseTags(kind: 1, materializedContent: vm.content)
        let imeta = tags.filter { $0.first == "imeta" }
        #expect(imeta.count == 1)
        #expect(imeta[0][1] == "url https://x/a.jpg")
        #expect(imeta[0].last == "alt charred leeks")
    }

    // MARK: - Autosave round-trip: alt persists, boundary lines stripped

    @Test func autosaveRoundTrip_persistsAltAndOrder() {
        let kp = freshKeypair()
        let key = "compose_autosave_new_\(kp.pubkey)"
        UserDefaults.standard.removeObject(forKey: key)
        let vm = ComposeViewModel(keypair: kp, mode: .new)
        vm.updateContent("Soup night")
        let a = media("https://x/a.jpg", alt: "leeks")
        let b = media("https://x/b.jpg")
        vm.attachments = [a, b]
        vm.moveMedia(id: b.id, before: a.id)
        vm.writeLocalAutosave()

        let reopened = ComposeViewModel(keypair: kp, mode: .new)
        #expect(reopened.content == "Soup night")
        #expect(reopened.attachments.map(\.url) == ["https://x/b.jpg", "https://x/a.jpg"])
        #expect(reopened.attachments[1].altText == "leeks")
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// An autosave written before attachments became slots can carry a
    /// URL in the text as well as in the array; restoring must strip the
    /// boundary occurrence or publishing appends it a second time.
    @Test func autosaveRestore_stripsBoundaryUrlDuplicates() {
        let kp = freshKeypair()
        let key = "compose_autosave_new_\(kp.pubkey)"
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set([
            "content": "Soup night\n\nhttps://x/a.jpg",
            "explicit": false,
            "attachments": [[
                "url": "https://x/a.jpg",
                "mime": "image/jpeg",
                "dimW": 0.0,
                "dimH": 0.0,
            ]],
        ] as [String: Any], forKey: key)

        let reopened = ComposeViewModel(keypair: kp, mode: .new)
        #expect(reopened.content == "Soup night")
        #expect(reopened.attachments.map(\.url) == ["https://x/a.jpg"])
        #expect(reopened.previewContent == "Soup night\n\nhttps://x/a.jpg")
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - The drawer

    @Test func drawerSummary_countsRight() {
        #expect(AttachmentSummaryDrawer.summaryLine(count: 1) == "1 attachment, added to the end of your post")
        #expect(AttachmentSummaryDrawer.summaryLine(count: 3) == "3 attachments, added to the end of your post")
    }

    // MARK: - Paste-attach offers

    @Test func candidates_offerEveryUrlOnAUrlOnlyLine_duplicatesIncluded() {
        let candidates = AttachmentModel.attachableUrlCandidates(
            "https://x/a.jpg\nhttps://x/b.jpg https://x/a.jpg"
        )
        #expect(candidates == ["https://x/a.jpg", "https://x/b.jpg", "https://x/a.jpg"])
    }

    @Test func candidates_proseLinesOfferNothing() {
        #expect(AttachmentModel.attachableUrlCandidates(
            "mirror at https://x/a.png if the first dies"
        ) == [])
        #expect(AttachmentModel.attachableUrlCandidates(
            "https://x/a.jpg is great"
        ) == [])
        #expect(AttachmentModel.attachableUrlCandidates("") == [])
    }

    @Test func candidates_nonHttpOrBareHostsOfferNothing() {
        #expect(AttachmentModel.attachableUrlCandidates("ftp://x/a.jpg") == [])
        #expect(AttachmentModel.attachableUrlCandidates("x.com/a.jpg") == [])
        // The offer rule is scheme-liberal beyond https only in case: http okay.
        #expect(AttachmentModel.attachableUrlCandidates("http://x/a.jpg") == ["http://x/a.jpg"])
    }

    /// A token that merely CONTAINS the url as a substring is a different
    /// token: consuming the short one must not touch the long one.
    @Test func removeOccurrence_isTokenExact_notSubstring() {
        let text = "https://x/a.jpg.bak https://x/a.jpg"
        let out = AttachmentModel.removeBareUrlOccurrence(text, url: "https://x/a.jpg")
        #expect(out == "https://x/a.jpg.bak")
    }

    @Test func removeOccurrence_emptiedLineVanishes_othersStay() {
        #expect(AttachmentModel.removeBareUrlOccurrence(
            "look\nhttps://x/a.jpg\ndone", url: "https://x/a.jpg"
        ) == "look\ndone")
        #expect(AttachmentModel.removeBareUrlOccurrence(
            "look\nhttps://x/a.jpg", url: "https://x/a.jpg"
        ) == "look")
        #expect(AttachmentModel.removeBareUrlOccurrence(
            "https://x/a.jpg\ndone", url: "https://x/a.jpg"
        ) == "done")
    }

    @Test func removeOccurrence_proseAndMissingAreUntouched() {
        let prose = "mirror at https://x/a.png if the first dies"
        #expect(AttachmentModel.removeBareUrlOccurrence(prose, url: "https://x/a.png") == prose)
        #expect(AttachmentModel.removeBareUrlOccurrence("hi", url: "https://x/a.jpg") == "hi")
    }

    @Test func removeOccurrence_secondOccurrenceConsumedOnRepeat() {
        let line = "https://x/a.jpg https://x/a.jpg"
        let once = AttachmentModel.removeBareUrlOccurrence(line, url: "https://x/a.jpg")
        #expect(once == "https://x/a.jpg")
        let twice = AttachmentModel.removeBareUrlOccurrence(once, url: "https://x/a.jpg")
        #expect(twice == "")
    }

    /// imeta is deduped per URL: a duplicate slot keeps its URL in the
    /// content but emits one tag, first described occurrence winning.
    @Test func imetaTags_dedupedByURL_firstDescribedWins() {
        let media = [
            media("https://x/a.jpg"),
            media("https://x/a.jpg", alt: "second described"),
            media("https://x/b.jpg", alt: "other"),
        ]
        let tags = AttachmentModel.imetaTags(for: media)
        #expect(tags.count == 2)
        #expect(tags[0][1] == "url https://x/a.jpg")
        #expect(tags[0].last == "alt second described")
        #expect(tags[1][1] == "url https://x/b.jpg")
    }

    // MARK: - attachUrl (VM): consume occurrence, add slot, guard double-tap

    @Test func attachUrl_consumesOccurrence_addsSlot() {
        let vm = composer()
        vm.updateContent("Soup night\nhttps://x/a.jpg")
        #expect(vm.attachOffers == ["https://x/a.jpg"])
        vm.attachUrl("https://x/a.jpg")
        #expect(vm.content == "Soup night")
        #expect(vm.attachments.map(\.url) == ["https://x/a.jpg"])
        #expect(vm.attachOffers == [])
        #expect(vm.previewContent == "Soup night\n\nhttps://x/a.jpg")
    }

    @Test func attachUrl_doubleTapAddsOnlyOneSlot() {
        let vm = composer()
        vm.updateContent("https://x/a.jpg")
        vm.attachUrl("https://x/a.jpg")
        vm.attachUrl("https://x/a.jpg")  // stale offer
        #expect(vm.attachments.count == 1)
    }

    @Test func attachUrl_sameUrlTwice_twoSlots() {
        let vm = composer()
        vm.updateContent("https://x/a.jpg https://x/a.jpg")
        #expect(vm.attachOffers == ["https://x/a.jpg", "https://x/a.jpg"])
        vm.attachUrl("https://x/a.jpg")
        #expect(vm.attachOffers == ["https://x/a.jpg"])
        vm.attachUrl("https://x/a.jpg")
        #expect(vm.attachOffers == [])
        #expect(vm.attachments.count == 2)
    }

    @Test func dismissOffer_hidesItUntilItsLineGoesAway() {
        let vm = composer()
        vm.updateContent("https://x/a.jpg")
        vm.dismissAttachOffer("https://x/a.jpg")
        #expect(vm.attachOffers == [])
        // Still refused while the line lives.
        vm.updateContent("https://x/a.jpg ")
        #expect(vm.attachOffers == [])
        // The refusal expires when its line does — pasting afresh asks again.
        vm.updateContent("gone")
        vm.updateContent("gone\nhttps://x/a.jpg")
        #expect(vm.attachOffers == ["https://x/a.jpg"])
    }

    // MARK: - Pasted-slot metadata merge

    /// The background fetch merges into the slot by id: partial results
    /// (empty mime, zero dim, no bytes) keep what the slot already had, so
    /// a hiccup can't erase a description or a working thumbnail.
    @Test func applyRemoteMeta_merges_partialResultsKeepExistingFields() {
        let vm = composer()
        let slot = media("https://x/a.jpg", alt: "leeks")
        vm.attachments = [slot]

        vm.applyRemoteMeta(mime: "image/png", dim: CGSize(width: 30, height: 40), data: Data([0x01]), slotId: slot.id)
        #expect(vm.attachments[0].mime == "image/png")
        #expect(vm.attachments[0].dim == CGSize(width: 30, height: 40))
        #expect(vm.attachments[0].localBytes == Data([0x01]))
        #expect(vm.attachments[0].altText == "leeks")
        #expect(vm.attachments[0].url == "https://x/a.jpg")

        // A later partial fetch erases nothing.
        vm.applyRemoteMeta(mime: "", dim: .zero, data: nil, slotId: slot.id)
        #expect(vm.attachments[0].mime == "image/png")
        #expect(vm.attachments[0].dim == CGSize(width: 30, height: 40))
        #expect(vm.attachments[0].localBytes == Data([0x01]))

        // Unknown slot id: no crash, no phantom slot.
        vm.applyRemoteMeta(mime: "image/gif", dim: CGSize(width: 1, height: 1), data: nil, slotId: UUID())
        #expect(vm.attachments.count == 1)
    }
}

// MARK: - Drag reorder step (the #268 midline math)

extension AttachmentModelTests {

    /// Slots laid out at one-row pitch: 0, 92, 184 (84pt cell + 8 gap),
    /// half = 42. A swap fires exactly when the dragged cell's center
    /// crosses the midpoint between centers — 46pt of travel.
    @Test func reorderStep_swapsAtTheMidline_andRebasesTheOffset() {
        let snapshot = [0: CGFloat(0), 1: CGFloat(92), 2: CGFloat(184)]
        // Under the midpoint: no move.
        #expect(AttachmentModel.reorderStep(snapshot: snapshot, from: 0, offsetX: 45, half: 42).index == 0)
        // Past the midpoint: splice to the neighbor, offset rebased so the
        // lifted cell stays under the finger.
        let step = AttachmentModel.reorderStep(snapshot: snapshot, from: 0, offsetX: 47, half: 42)
        #expect(step.index == 1)
        #expect(step.offsetX == CGFloat(47 - 92))
        // Leftward from the last slot.
        let left = AttachmentModel.reorderStep(snapshot: snapshot, from: 2, offsetX: -47, half: 42)
        #expect(left.index == 1)
        #expect(left.offsetX == CGFloat(-47 + 92))
    }

    @Test func reorderStep_multiCellTravel_loopsToTheFinalSlot() {
        let snapshot = [0: CGFloat(0), 1: CGFloat(92), 2: CGFloat(184)]
        // A 200pt fling right from slot 0 crosses both midlines.
        var state = (index: 0, offsetX: CGFloat(200))
        for _ in 0..<4 {
            let step = AttachmentModel.reorderStep(
                snapshot: snapshot, from: state.index, offsetX: state.offsetX, half: 42
            )
            if step.index == state.index { break }
            state = step
        }
        #expect(state.index == 2)
    }

    @Test func reorderStep_atRest_neverMoves() {
        let snapshot = [0: CGFloat(0), 1: CGFloat(92), 2: CGFloat(184)]
        for from in 0...2 {
            #expect(AttachmentModel.reorderStep(snapshot: snapshot, from: from, offsetX: 0, half: 42).index == from)
        }
    }
}
