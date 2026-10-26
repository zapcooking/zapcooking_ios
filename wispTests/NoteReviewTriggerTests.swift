import Foundation
import Testing
@testable import wisp

/// `NoteReviewTrigger` decision matrix (port of Android
/// `NoteReviewTriggerTest`, with the iOS threshold). The threshold itself
/// is derived from the control widths pinned in `BottomBarAndActionRowTests`.
@MainActor
struct NoteReviewTriggerTests {

    private let withImage = "dinner https://example.com/dish.jpg"
    private let noImage = "dinner was great"

    @Test func thresholdBoundary_355Absent_356Present() {
        #expect(NoteReviewTrigger.inlineMinRowWidth == 356)
        #expect(!NoteReviewTrigger.meetsInlineWidth(355))
        #expect(NoteReviewTrigger.meetsInlineWidth(356))
    }

    @Test func narrowestDevice_375pt_isMenuOnly_and390ptClears() {
        // Card gutters are 16pt per side.
        let se: CGFloat = 375 - 32
        let iPhone390: CGFloat = 390 - 32
        #expect(!NoteReviewTrigger.showInline(noteContent: withImage, rowWidth: se, isQuoted: false, flagEnabled: true))
        #expect(NoteReviewTrigger.showInline(noteContent: withImage, rowWidth: iPhone390, isQuoted: false, flagEnabled: true))
    }

    @Test func imagelessNote_neverShowsTheSlot_atAnyWidth() {
        for width: CGFloat in [300, 356, 500, 1024] {
            #expect(!NoteReviewTrigger.showInline(noteContent: noImage, rowWidth: width, isQuoted: false, flagEnabled: true))
        }
        #expect(!NoteReviewTrigger.isEligible(noteContent: noImage, flagEnabled: true))
    }

    @Test func flagOff_neverShowsTheSlot_atAnyWidth() {
        for width: CGFloat in [300, 356, 500, 1024] {
            #expect(!NoteReviewTrigger.showInline(noteContent: withImage, rowWidth: width, isQuoted: false, flagEnabled: false))
        }
        #expect(!NoteReviewTrigger.isEligible(noteContent: withImage, flagEnabled: false))
    }

    @Test func eligibility_isImageUrlsParity() {
        // heic renders in the app but is not an image to the server.
        #expect(!NoteReviewTrigger.isEligible(noteContent: "https://example.com/p.heic", flagEnabled: true))
        #expect(NoteReviewTrigger.isEligible(noteContent: "https://image.nostr.build/abc", flagEnabled: true))
    }

    @Test func quotedRender_neverShowsTheSlot_evenWide() {
        #expect(!NoteReviewTrigger.showInline(noteContent: withImage, rowWidth: 1024, isQuoted: true, flagEnabled: true))
    }

    @Test func showInline_isExactlyTheConjunctionOfItsThreeGates() {
        for content in [withImage, noImage] {
            for width: CGFloat in [355, 356] {
                for quoted in [false, true] {
                    for flag in [false, true] {
                        let expected = NoteReviewTrigger.isEligible(noteContent: content, flagEnabled: flag)
                            && !quoted && NoteReviewTrigger.meetsInlineWidth(width)
                        #expect(NoteReviewTrigger.showInline(noteContent: content, rowWidth: width, isQuoted: quoted, flagEnabled: flag) == expected)
                    }
                }
            }
        }
    }

    /// The detector is web parity (admits `http://`); the endpoint 400s a
    /// non-https `imageUrl`, so eligibility keeps only https images.
    @Test func httpImages_areDetected_butNeverEligible() {
        let mixed = "a http://example.com/a.jpg b https://example.com/b.jpg c http://example.com/c.png d https://example.com/d.png"
        #expect(ImageUrls.extractImageUrls(mixed).count == 4)
        #expect(NoteReviewTrigger.eligibleImageUrls(noteContent: mixed) == ["https://example.com/b.jpg", "https://example.com/d.png"])
        // The web URL regex is case-sensitive on the scheme: an upper-case
        // scheme is never extracted at all (parity), so nothing to filter.
        #expect(ImageUrls.extractImageUrls("HTTPS://example.com/c.png").isEmpty)
        #expect(!NoteReviewTrigger.isEligible(noteContent: "http://example.com/only.jpg", flagEnabled: true))
        #expect(!NoteReviewTrigger.showInline(noteContent: "http://example.com/only.jpg", rowWidth: 1024, isQuoted: false, flagEnabled: true))
    }

    /// Ships off. App Review's Guideline 2.1(b) inquiry of 2026-10-26 asked
    /// which paid features the app unlocks without In-App Purchase; Cook+ is
    /// sold off-app, so the answer has to be "none" and the build has to
    /// match. This is a REVERSIBLE compliance posture, not a product
    /// decision: the plan is to turn Note Review back on for the US storefront
    /// once a region-gated external purchase link ships (permitted on the
    /// US storefront post-Epic). Turning it back on without that region
    /// gate re-opens the 2.1(b) problem — this pin is here so it can't
    /// happen by accident.
    @Test func killSwitch_shipsOff_guideline2_1b() {
        #expect(!FeatureFlags.noteReviewEnabled)
        #expect(!NoteReviewTrigger.isEligible(noteContent: "dinner https://example.com/dish.jpg"))
    }
}
