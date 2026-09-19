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

    @Test func killSwitchDefaultsOn() {
        #expect(FeatureFlags.noteReviewEnabled)
    }
}
