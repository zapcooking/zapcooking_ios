import Foundation
import Testing
@testable import wisp

/// Issue #1 Part A — prune at ingest. The shipped `RelayDefaults.decommissioned`
/// is empty (relay.damus.io answered a live REQ on 2026-09-07), so every test
/// injects its own set; nothing here depends on production constants except
/// the tripwire that documents the empty default.
@MainActor
struct RelayDecommissionTests {

    private let dead: Set<String> = ["wss://dead.example"]
    private let deadAndOther: Set<String> = ["wss://dead.example", "wss://Gone.Example/"]

    // MARK: - Set semantics

    @Test func shippedSet_isEmpty_untilAShutdownIsConfirmed() {
        #expect(RelayDefaults.decommissioned.isEmpty)
        #expect(RelayDecommission.version() == "empty")
        // With an empty set every prune is the identity.
        let tags = [["r", "wss://relay.damus.io"], ["r", "wss://nos.lol", "read"]]
        #expect(RelayDecommission.pruneTags(tags).tags == tags)
        #expect(RelayDecommission.pruneTags(tags).removed.isEmpty)
    }

    @Test func isDecommissioned_matchesByHostAcrossSpellings() {
        #expect(RelayDecommission.isDecommissioned("wss://dead.example", in: dead))
        #expect(RelayDecommission.isDecommissioned("wss://DEAD.example/", in: dead))
        #expect(RelayDecommission.isDecommissioned("wss://dead.example/inbox", in: dead))
        #expect(RelayDecommission.isDecommissioned("ws://dead.example", in: dead))
        #expect(!RelayDecommission.isDecommissioned("wss://notdead.example", in: dead))
        #expect(!RelayDecommission.isDecommissioned("wss://dead.example.org", in: dead))
        #expect(!RelayDecommission.isDecommissioned("garbage", in: dead))
        // Set entries are canonicalized too.
        #expect(RelayDecommission.isDecommissioned("wss://gone.example", in: deadAndOther))
    }

    @Test func version_isStableAcrossOrderAndSpelling() {
        let a: Set<String> = ["wss://b.example", "wss://A.example/"]
        let b: Set<String> = ["wss://a.example", "wss://B.EXAMPLE"]
        #expect(RelayDecommission.version(of: a) == RelayDecommission.version(of: b))
        #expect(RelayDecommission.version(of: a) == "a.example,b.example")
        #expect(RelayDecommission.version(of: a) != RelayDecommission.version(of: dead))
    }

    // MARK: - Pruning preserves everything else

    @Test func pruneGeneralRelays_keepsOrderAndFlags() {
        let input = [
            GeneralRelay(url: "wss://nos.lol", read: true, write: false, auth: true),
            GeneralRelay(url: "wss://dead.example", read: true, write: true),
            GeneralRelay(url: "wss://relay.primal.net", read: false, write: true),
        ]
        let out = RelayDecommission.prune(input, decommissioned: dead)
        #expect(out == [input[0], input[2]])
        // Fixed point.
        #expect(RelayDecommission.prune(out, decommissioned: dead) == out)
    }

    @Test func pruneTags_removesOnlyDeadRelayTags_byteForByte() {
        let tags: [[String]] = [
            ["r", "wss://Relay.Primal.Net/", "read"],   // odd spelling, must survive verbatim
            ["r", "wss://dead.example"],
            ["client", "someclient"],                   // foreign tag, must survive
            ["r", "wss://nos.lol", "write", "extra"],   // extra positional field, must survive
            ["relay", "wss://dead.example/"],           // relay-alias spelling of the dead host
            ["r", "wss://relay.nostr.net"],
            ["alt", "relay list"],
        ]
        let (kept, removed) = RelayDecommission.pruneTags(tags, decommissioned: dead)
        #expect(removed == ["wss://dead.example", "wss://dead.example/"])
        #expect(kept == [
            ["r", "wss://Relay.Primal.Net/", "read"],
            ["client", "someclient"],
            ["r", "wss://nos.lol", "write", "extra"],
            ["r", "wss://relay.nostr.net"],
            ["alt", "relay list"],
        ])
        // Idempotent.
        let again = RelayDecommission.pruneTags(kept, decommissioned: dead)
        #expect(again.tags == kept)
        #expect(again.removed.isEmpty)
    }

    // MARK: - Harvested community lists (RelayProber)

    @Test func proberCandidates_dropDecommissionedFromHarvest() {
        // Five mega-relays in every list (10×) take the top-5 exclusion;
        // `dead.example` sits just below them (7×) and `mid.example` (4×)
        // clears the ≥3 floor — the shape a zombie relay would take. Counts
        // are distinct so the tally sort is deterministic.
        let ranked = ["wss://a.example", "wss://b.example", "wss://c.example",
                      "wss://d.example", "wss://e.example"]
        var events: [NostrEvent] = []
        for i in 0..<10 {
            var tags = ranked.map { ["r", $0] }
            if i < 7 { tags.append(["r", "wss://dead.example"]) }  // 7 occurrences
            if i < 4 { tags.append(["r", "wss://mid.example"]) }   // 4 occurrences
            events.append(makeEvent(kind: 10002, tags: tags, createdAt: 1_700_000_000 + i))
        }
        let unpruned = RelayProber.candidates(from: events, decommissioned: [])
        #expect(unpruned.contains("wss://dead.example"))
        #expect(unpruned.contains("wss://mid.example"))

        let pruned = RelayProber.candidates(from: events, decommissioned: dead)
        #expect(!pruned.contains("wss://dead.example"))
        #expect(pruned.contains("wss://mid.example"))
    }

    // MARK: - Fallback path is probed, never published verbatim

    @Test func probedFallback_publishesOnlyPassers_inConstantOrder() async {
        let failing = RelayProber.fallbackRelays[1].url
        let probed = ProbeLog()
        let out = await RelayProber.probedFallback(decommissioned: []) { url in
            await probed.record(url)
            return url != failing
        }
        let expected = RelayProber.fallbackRelays.filter { $0.url != failing }
        #expect(out == expected)
        #expect(await probed.urls.sorted() == RelayProber.fallbackRelays.map(\.url).sorted())
    }

    @Test func probedFallback_neverProbesDecommissioned_andCanReturnEmpty() async {
        let deadFallback = RelayProber.fallbackRelays[0].url
        let probed = ProbeLog()
        let out = await RelayProber.probedFallback(decommissioned: [deadFallback]) { url in
            await probed.record(url)
            return true
        }
        #expect(!out.map(\.url).contains(deadFallback))
        #expect(!(await probed.urls).contains(deadFallback))
        #expect(out.count == RelayProber.fallbackRelays.count - 1)

        // Offline: nothing passes → nothing to publish (SignUpViewModel then signs no list).
        let none = await RelayProber.probedFallback(decommissioned: []) { _ in false }
        #expect(none.isEmpty)
    }

    // MARK: - Caches

    @Test func relayListRepository_ingestDropsDecommissioned_keepsMarkers() {
        let pubkey = "ab" + String(repeating: "c", count: 62)
        defer { UserDefaults.standard.removeObject(forKey: "relaylist_\(pubkey)") }
        let event = makeEvent(kind: 10002, tags: [
            ["r", "wss://dead.example"],
            ["r", "wss://nos.lol", "read"],
            ["r", "wss://relay.primal.net", "write"],
        ], pubkey: pubkey, createdAt: 1_800_000_000)
        #expect(RelayListRepository.shared.ingest(event, decommissioned: dead))
        #expect(RelayListRepository.shared.cachedReadRelays(pubkey) == ["wss://nos.lol"])
    }

    @Test func scoreBoard_buildSkipsDecommissioned() {
        let author = "de" + String(repeating: "f", count: 62)
        let board = RelayScoreBoard()
        board.build(
            follows: [author],
            writeRelaysByAuthor: [author: ["wss://dead.example", "wss://nos.lol", "wss://relay.primal.net"]],
            redundancy: 2,
            decommissioned: dead
        )
        #expect(board.scoredRelays.map(\.url).sorted() == ["wss://nos.lol", "wss://relay.primal.net"])
    }

    // MARK: - Helpers

    private actor ProbeLog {
        var urls: [String] = []
        func record(_ url: String) { urls.append(url) }
    }

    private func makeEvent(kind: Int, tags: [[String]],
                           pubkey: String = String(repeating: "1", count: 64),
                           createdAt: Int) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: pubkey,
            kind: kind,
            createdAt: createdAt,
            tags: tags,
            content: "",
            sig: String(repeating: "2", count: 128)
        )
    }
}
