import Foundation
import Testing
@testable import wisp

/// Search parity with web (zap.cooking): the default relay set fans across
/// the same two NIP-50 search relays web queries, people results merge the
/// nostrarchives username index with relay kind-0s under web's ranking
/// tiers, recipe rows are re-checked client-side the way web's
/// `recipeSearchResult` is, and keyword/hashtag completions come from the
/// static food taxonomy. All pure seams — no network, no relays.
@MainActor
struct SearchParityTests {

    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)

    private func recipeEvent(
        pubkey: String,
        dTag: String,
        title: String? = nil,
        tags: [[String]]? = nil,
        kind: Int = RecipeParser.recipeKind
    ) -> NostrEvent {
        var t: [[String]] = tags ?? [["t", "zapcooking"], ["d", dTag]]
        if let tags { t = tags }
        else if let title { t.append(["title", title]) }
        return NostrEvent(
            id: "id-\(dTag)-\(kind)", pubkey: pubkey, kind: kind,
            createdAt: 1_000, tags: t, content: "", sig: String(repeating: "0", count: 128)
        )
    }

    // MARK: - Relay fan-out

    @Test func defaultSearchRelays_matchWebPair() {
        #expect(SearchViewModel.defaultSearchRelays == [
            "wss://search.nos.today", "wss://search.nostrarchives.com",
        ])
    }

    @Test func relaysToQuery_defaultFansBothSearchRelays() {
        let vm = SearchViewModel(keypair: Keypair(privkey: "", pubkey: alice))
        #expect(vm.relaysToQuery() == SearchViewModel.defaultSearchRelays)
    }

    @Test func relaysToQuery_allAddsSavedRelaysWithoutDroppingDefaults() {
        let vm = SearchViewModel(keypair: Keypair(privkey: "", pubkey: alice))
        vm.savedSearchRelays = ["wss://relay.example.com"]
        vm.relayOption = .all
        #expect(vm.relaysToQuery() == [
            "wss://search.nos.today", "wss://search.nostrarchives.com", "wss://relay.example.com",
        ])
    }

    @Test func relaysToQuery_individualFallsBackToBoth() {
        let vm = SearchViewModel(keypair: Keypair(privkey: "", pubkey: alice))
        vm.relayOption = .individual
        vm.selectedRelayUrl = nil
        #expect(vm.relaysToQuery() == SearchViewModel.defaultSearchRelays)
    }

    // MARK: - Recipe recheck (web recipeSearchResult parity)

    @Test func recipeResult_acceptsTagged30023WithTitle() {
        let event = recipeEvent(pubkey: alice, dTag: "soup", title: "Wedding Soup")
        let result = SearchViewModel.recipeResult(from: event)
        #expect(result?.author == alice)
        #expect(result?.dTag == "soup")
        #expect(result?.title == "Wedding Soup")
    }

    @Test func recipeResult_fallsBackToDTagWhenTitleMissing() {
        let event = recipeEvent(pubkey: alice, dTag: "Peposo (black pepper stew)")
        let result = SearchViewModel.recipeResult(from: event)
        #expect(result?.title == "Peposo (black pepper stew)")
    }

    @Test func recipeResult_rejectsUntaggedArticle() {
        let event = recipeEvent(
            pubkey: alice, dTag: "essay",
            tags: [["d", "essay"], ["title", "Not a recipe"]]
        )
        #expect(SearchViewModel.recipeResult(from: event) == nil)
    }

    @Test func recipeResult_acceptsLegacyNostrcookingTag() {
        let event = recipeEvent(
            pubkey: alice, dTag: "stew",
            tags: [["d", "stew"], ["t", "NostrCooking"]]
        )
        #expect(SearchViewModel.recipeResult(from: event)?.dTag == "stew")
    }

    @Test func recipeResult_rejectsMissingDTag() {
        let event = recipeEvent(pubkey: alice, dTag: "", tags: [["t", "zapcooking"]])
        #expect(SearchViewModel.recipeResult(from: event) == nil)
    }

    @Test func recipeResult_rejectsKind35000() {
        let event = recipeEvent(pubkey: alice, dTag: "legacy", kind: 35000)
        #expect(SearchViewModel.recipeResult(from: event) == nil)
    }

    @Test func recipeResult_rejectsNonHexPubkey() {
        let event = recipeEvent(pubkey: "not-hex", dTag: "soup")
        #expect(SearchViewModel.recipeResult(from: event) == nil)
    }

    @Test func recipeResult_dedupesOnCoordinate() {
        let first = recipeEvent(pubkey: alice, dTag: "soup", title: "Soup v1")
        let republish = recipeEvent(pubkey: alice.uppercased(), dTag: "soup", title: "Soup v2")
        var seen = Set<String>()
        var rows: [SearchViewModel.RecipeResult] = []
        for event in [first, republish] {
            if let r = SearchViewModel.recipeResult(from: event), seen.insert(r.id).inserted {
                rows.append(r)
            }
        }
        #expect(rows.count == 1)
    }

    // MARK: - People ranking (web rankProfiles parity)

    @Test func rankedPeople_exactNameBeatsPrefixBeatsNip05Prefix() {
        let exact = ProfileData(pubkey: alice, json: ["name": "soup"])
        let prefix = ProfileData(pubkey: bob, json: ["display_name": "souplover"])
        let nip05 = ProfileData(pubkey: String(repeating: "c", count: 64), json: ["nip05": "soup@zap.cooking"])
        let other = ProfileData(pubkey: String(repeating: "d", count: 64), json: ["name": "carrot"])

        let ranked = SearchViewModel.rankedPeople(
            [other, nip05, prefix, exact], query: "soup", follows: []
        )
        #expect(ranked.map(\.pubkey) == [alice, bob, String(repeating: "c", count: 64), String(repeating: "d", count: 64)])
    }

    @Test func rankedPeople_nip05LocalExactTiers() {
        let localExact = ProfileData(pubkey: alice, json: ["name": "chef", "nip05": "soup@zap.cooking"])
        let localPrefix = ProfileData(pubkey: bob, json: ["nip05": "souperfan@zap.cooking"])
        let ranked = SearchViewModel.rankedPeople([localPrefix, localExact], query: "soup", follows: [])
        #expect(ranked.map(\.pubkey) == [alice, bob])
    }

    @Test func rankedPeople_followedWinsWithinTier() {
        let followed = ProfileData(pubkey: alice, json: ["name": "soupfan"])
        let stranger = ProfileData(pubkey: bob, json: ["name": "soupfan"])
        let ranked = SearchViewModel.rankedPeople(
            [stranger, followed], query: "soup", follows: [alice]
        )
        #expect(ranked.first?.pubkey == alice)
    }

    // MARK: - Hashtag / keyword completions

    @Test func matchingTags_prefixFirstThenSubstring_cappedAtLimit() {
        // "coo" has both forms in the taxonomy: prefix matches ("cook",
        // "cookstr", "cooking") and substring-only matches ("zapcooking",
        // "homecooking"). Prefixes must come first.
        let matches = SearchViewModel.matchingTags(for: "coo", limit: 20)
        let prefixTags = ["cook", "cookstr", "cooking"]
        let firstPrefix = matches.firstIndex { prefixTags.contains($0) }
        let lastSubstringOnly = matches.lastIndex { !prefixTags.contains($0) }
        #expect(firstPrefix != nil)
        #expect(firstPrefix! < lastSubstringOnly!)
        #expect(matches.contains("zapcooking"))
        #expect(matches.contains("homecooking"))
        #expect(SearchViewModel.matchingTags(for: "coo", limit: 3).count == 3)
    }

    @Test func matchingTags_emptyBelowTwoChars() {
        #expect(SearchViewModel.matchingTags(for: "") == [])
        #expect(SearchViewModel.matchingTags(for: "s") == [])
    }

    @Test func matchingTags_caseInsensitive() {
        #expect(SearchViewModel.matchingTags(for: "SOUP").contains("soup"))
    }
}
