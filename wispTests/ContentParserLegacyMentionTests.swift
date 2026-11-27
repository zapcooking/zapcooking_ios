import Foundation
import Testing
@testable import wisp

/// Legacy NIP-08 mentions: pre-NIP-27 clients referenced people and events
/// in `content` with `#[index]` tokens pointing at the tags array. Reported
/// against event 648944ed… ("Nodestrich Early Birds"), whose 39 `#[N]` lines
/// rendered as literal text instead of @mentions.
struct ContentParserLegacyMentionTests {

    private func parse(_ content: String, tags: [[String]]) -> [ContentSegment] {
        ContentParser.parse(content: content, tags: tags)
    }

    private let p1 = "1111111111111111111111111111111111111111111111111111111111111111"
    private let p2 = "2222222222222222222222222222222222222222222222222222222222222222"
    private let p3 = "3333333333333333333333333333333333333333333333333333333333333333"

    /// Mirrors the reported event's shape: a leading non-mention tag, then
    /// one `["p", …]` tag per congratulated user, referenced as #[1]…#[N].
    @Test func nodestrichStyleBadgeListResolves() {
        let tags: [[String]] = [
            ["t", "nodestrich"],
            ["p", p1],
            ["p", p2],
            ["p", p3],
        ]
        let segments = parse("Congratulations to:\n#[1]\n#[2]\n#[3]", tags: tags)
        #expect(segments == [
            .text("Congratulations to:\n"),
            .nostrProfile(pubkey: p1, relayHints: []),
            .text("\n"),
            .nostrProfile(pubkey: p2, relayHints: []),
            .text("\n"),
            .nostrProfile(pubkey: p3, relayHints: []),
        ])
    }

    /// Index 0 counts too — NIP-08 indices are plain tags-array positions.
    @Test func zeroIndexResolves() {
        let segments = parse("#[0] said hi", tags: [["p", p1]])
        #expect(segments == [.nostrProfile(pubkey: p1, relayHints: []), .text(" said hi")])
    }

    /// A p tag's optional relay hint carries into the segment.
    @Test func profileRelayHintCarriesThrough() {
        let segments = parse("hey #[1]", tags: [["e", "abc"], ["p", p1, "wss://relay.example"]])
        #expect(segments == [.text("hey "), .nostrProfile(pubkey: p1, relayHints: ["wss://relay.example"])])
    }

    /// An e tag resolves to an event reference, like a nostr:note1… token.
    @Test func eventMentionResolvesToNoteRef() {
        let id = "648944ed2691e83b5b8f5754e0f4fb9c3377facfbe81f3682476c1016aa539a2"
        let segments = parse("re #[0]", tags: [["e", id, "wss://relay.example", "reply", p2]])
        #expect(segments == [.text("re "), .nostrNote(eventId: id, relayHints: ["wss://relay.example"], author: p2)])
    }

    /// Out-of-range indices stay literal — a client must not invent mentions.
    @Test func outOfRangeIndexStaysText() {
        let segments = parse("missing #[7] here", tags: [["p", p1]])
        #expect(segments == [.text("missing #[7] here")])
    }

    /// #[0] on the example event's ["t", …] tag isn't a mention.
    @Test func nonPersonOrEventTagStaysText() {
        let segments = parse("#[0] #[1]", tags: [["t", "nodestrich"], ["p", p1]])
        #expect(segments == [.text("#[0] "), .nostrProfile(pubkey: p1, relayHints: [])])
    }

    /// Degenerate tags (missing the value slot) stay text.
    @Test func malformedTagStaysText() {
        let segments = parse("bad #[1] keep", tags: [["p"]])
        #expect(segments == [.text("bad #[1] keep")])
    }

    /// No tags (composer preview parses with an empty array) → literal text,
    /// so composing `#[1]`-style drafts doesn't render phantom mentions.
    @Test func emptyTagsKeepsTokensLiteral() {
        let segments = parse("who is #[1]?", tags: [])
        #expect(segments == [.text("who is #[1]?")])
    }

    /// Adjacent tokens with nothing between them all resolve.
    @Test func adjacentTokensResolve() {
        let segments = parse("#[0]#[1]", tags: [["p", p1], ["p", p2]])
        #expect(segments == [.nostrProfile(pubkey: p1, relayHints: []), .nostrProfile(pubkey: p2, relayHints: [])])
    }

    /// Modern hashtags still parse; `#[N]` never leaks into the hashtag path.
    @Test func hashtagsUnaffected() {
        let segments = parse("#nostr #[0]", tags: [["p", p1]])
        #expect(segments == [.hashtag("nostr"), .text(" "), .nostrProfile(pubkey: p1, relayHints: [])])
    }

    /// Brackets that aren't purely numeric aren't mentions (`#[1a]`, `#[]`).
    @Test func nonNumericBracketIsUntouched() {
        #expect(parse("#[1a]", tags: [["p", p1]]) == [.text("#[1a]")])
        #expect(parse("#[]", tags: [["p", p1]]) == [.text("#[]")])
    }
}
