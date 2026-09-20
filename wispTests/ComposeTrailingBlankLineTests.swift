import Foundation
import Testing
@testable import wisp

/// The other half of blank-line handling: this client shouldn't *emit* the
/// padding in the first place. `ContentParser` pass 6 (concern 3 / #102) only
/// tidies what our own readers see — a note published with trailing newlines
/// still renders with real empty lines in every other client.
///
/// Upstream keeps these beside the parser tests in
/// `ContentParserBlankLineTests.swift`; they live in their own file here so
/// the two concerns can merge in either order.
struct ComposeTrailingBlankLineTests {

    @Test func trailingNewlinesAreTrimmedBeforePublish() {
        #expect(ComposeViewModel.trimTrailingBlankLines("gm\n\n\n") == "gm")
        #expect(ComposeViewModel.trimTrailingBlankLines("gm\n  \n\t") == "gm")
    }

    @Test func interiorSpacingIsTheAuthorsToKeep() {
        // Only the tail is tidied — the middle of a post is never rewritten.
        #expect(
            ComposeViewModel.trimTrailingBlankLines("one\n\n\n\ntwo\n\n")
                == "one\n\n\n\ntwo"
        )
    }

    @Test func postWithoutPaddingIsUnchanged() {
        #expect(ComposeViewModel.trimTrailingBlankLines("gm") == "gm")
        #expect(ComposeViewModel.trimTrailingBlankLines("one\ntwo") == "one\ntwo")
    }

    @Test func allWhitespaceCollapsesToEmpty() {
        #expect(ComposeViewModel.trimTrailingBlankLines("\n\n  \n").isEmpty)
    }
}
