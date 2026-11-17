import Foundation
import Testing
@testable import wisp

/// Quoting a recipe (or any addressable event) from "Share in Note": the body
/// embeds `naddr` so the quote survives the author editing it, and an `a` tag
/// carries the coordinate. `q` stays an event id for its existing consumers.
struct Nip18AddressableQuoteTests {
    private static func recipe() -> NostrEvent {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            fatalError("fixture decode failed")
        }
        return event
    }

    private static func note() -> NostrEvent {
        NostrEvent(
            id: String(repeating: "a", count: 64), pubkey: String(repeating: "b", count: 64),
            kind: 1, createdAt: 1_700_000_000, tags: [], content: "hi", sig: String(repeating: "c", count: 128)
        )
    }

    @Test func recipeQuote_embedsNaddr_notNevent() throws {
        let event = Self.recipe()
        let body = Nip18.appendQuoteUri(content: "Try this", quoting: event)
        #expect(body.hasPrefix("Try this\nnostr:naddr1"))
        #expect(!body.contains("nevent1"))
        let naddr = String(body.dropFirst("Try this\nnostr:".count))
        guard case .addressRef(let dTag, _, let author, let kind)? = try? Nip19.naddrDecode(naddr) else {
            Issue.record("naddr did not decode"); return
        }
        #expect(dTag == RecipeParser.dTag(event))
        #expect(author == event.pubkey)
        #expect(kind == RecipeParser.recipeKind)
    }

    @Test func recipeQuote_emptyBody_isJustTheUri() {
        let body = Nip18.appendQuoteUri(content: "", quoting: Self.recipe())
        #expect(body.hasPrefix("nostr:naddr1"))
        #expect(!body.contains("\n"))
    }

    @Test func plainNote_stillQuotesWithNevent() {
        let body = Nip18.appendQuoteUri(content: "", quoting: Self.note())
        #expect(body.hasPrefix("nostr:nevent1"))
    }

    @Test func recipeQuoteTags_haveQPAndCoordinate() {
        let event = Self.recipe()
        let tags = Nip18.buildQuoteTags(event: event)
        #expect(tags.contains(["q", event.id, ""]))
        #expect(tags.contains(["p", event.pubkey]))
        #expect(tags.contains(["a", "30023:\(event.pubkey):\(RecipeParser.dTag(event))"]))
    }

    @Test func plainNoteQuoteTags_haveNoCoordinate() {
        let tags = Nip18.buildQuoteTags(event: Self.note())
        #expect(!tags.contains { $0.first == "a" })
    }

    @Test func parseCoordinate_roundTrips_andKeepsColonsInDTag() {
        let pub = String(repeating: "d", count: 64)
        let parsed = Nip18.parseCoordinate("30023:\(pub):stew:v2 (spicy)")
        #expect(parsed?.kind == 30023)
        #expect(parsed?.pubkey == pub)
        #expect(parsed?.dTag == "stew:v2 (spicy)")
        #expect(Nip18.parseCoordinate("1:\(pub):x") == nil)
        #expect(Nip18.parseCoordinate("30023:short:x") == nil)
    }
}
