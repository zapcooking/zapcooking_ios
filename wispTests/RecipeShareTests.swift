import Foundation
import Testing
@testable import wisp

/// #222 — the shared naddr / share-URL builder used by `ArticleView` and
/// `RecipeDetailView`. Pins the URL shape and that the naddr round-trips to
/// the event's coordinate, so a recipient resolves the same recipe.
@MainActor
struct RecipeShareTests {
    private static func peposo() -> NostrEvent {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            fatalError("fixture decode failed")
        }
        return event
    }

    private static func decode(_ naddr: String) -> (dTag: String, relays: [String], author: String?, kind: Int?)? {
        guard case .addressRef(let dTag, let relays, let author, let kind)? = try? Nip19.naddrDecode(naddr)
        else { return nil }
        return (dTag, relays, author, kind)
    }

    @Test func url_hasCanonicalZapCookingShape() throws {
        let url = try #require(RecipeShare.url(for: Self.peposo(), relays: []))
        #expect(url.hasPrefix("https://zap.cooking/r/naddr1"))
    }

    @Test func naddr_roundTripsToCoordinate() throws {
        let event = Self.peposo()
        let naddr = try #require(RecipeShare.naddr(for: event, relays: []))
        let decoded = try #require(Self.decode(naddr))
        #expect(decoded.kind == RecipeParser.recipeKind)
        #expect(decoded.author == event.pubkey)
        // Raw d-tag, parens intact — the coordinate the repository joins on.
        #expect(decoded.dTag == "tuscan-peposo-(black-pepper-beef-stew)")
        #expect(decoded.relays.isEmpty)
    }

    @Test func naddr_carriesAtMostTwoRelayHints() throws {
        let event = Self.peposo()
        let hints = ["wss://a.example", "wss://b.example", "wss://c.example"]
        let naddr = try #require(RecipeShare.naddr(for: event, relays: hints))
        let decoded = try #require(Self.decode(naddr))
        #expect(decoded.relays == ["wss://a.example", "wss://b.example"])
    }

    @Test func naddr_unencodablePubkey_isNil_soShareIsSuppressed() {
        let event = NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: "not-hex",
            kind: RecipeParser.recipeKind,
            createdAt: 1_700_000_000,
            tags: [["d", "slug"]],
            content: "",
            sig: String(repeating: "2", count: 128)
        )
        #expect(RecipeShare.naddr(for: event, relays: []) == nil)
        #expect(RecipeShare.url(for: event, relays: []) == nil)
    }
}
