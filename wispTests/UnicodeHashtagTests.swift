import Foundation
import Testing
@testable import wisp

/// The reader-side hashtag class accepts Unicode letters (upstream `91ddbcc`).
/// `#Kreuzworträtsel` used to stop matching at the `ä`, splitting the tag mid-
/// word; compose-side suggestion scanning was already Unicode-aware, so the
/// reader was the one surface that disagreed with what the author typed.
struct UnicodeHashtagTests {

    private func hashtags(in content: String) -> [String] {
        var out: [String] = []
        for segment in ContentParser.parse(content: content, tags: []) {
            if case .hashtag(let tag) = segment { out.append(tag) }
        }
        return out
    }

    @Test func latinDiacriticsStayOneTag() {
        #expect(hashtags(in: "das #Kreuzworträtsel heute") == ["Kreuzworträtsel"])
    }

    @Test func cjkAndCyrillicTag() {
        #expect(hashtags(in: "#寿司 night") == ["寿司"])
        #expect(hashtags(in: "готовим #борщ") == ["борщ"])
    }

    @Test func asciiTagsUnchanged() {
        #expect(hashtags(in: "plain #foodstr tag") == ["foodstr"])
    }

    @Test func punctuationStillEndsTheTag() {
        #expect(hashtags(in: "gone #sushi, now") == ["sushi"])
        #expect(hashtags(in: "the #cooking.") == ["cooking"])
    }

    @Test func emojiIsNotALetterAndDoesNotStartATag() {
        // \p{L} excludes emoji — a bare #🎉 stays literal text.
        #expect(hashtags(in: "cheers #🎉") == [])
    }
}
