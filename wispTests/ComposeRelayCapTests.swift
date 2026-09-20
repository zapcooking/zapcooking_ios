import Foundation
import Testing
@testable import wisp

/// `ComposeViewModel.topWriteRelays()` used to return the entire relay
/// scoreboard — hundreds of URLs, other people's junk included — and stamp
/// every one into a poll's `relay` tags (one kind-1068 went out at 21.5 KB
/// with 480 tags). These pin the filter-then-cap so that can't come back.
struct ComposeRelayCapTests {

    private static let good = (1...8).map { "wss://relay\($0).example.com" }

    @Test func capsAtFiveConnectableRelaysInScoreboardOrder() {
        let out = ComposeViewModel.capWriteRelays(Self.good)
        #expect(out.count == ComposeViewModel.maxAdvertisedRelays)
        #expect(out == Array(Self.good.prefix(5)))
    }

    @Test func junkIsDroppedBeforeTheCapIsApplied() {
        // Each of these shapes was seen in a real scoreboard; none may take a slot.
        let junk = [
            "wss://abcdef1234567890.onion",
            "wss://https//relay.example.com",
            "ws://relay.example.com",
            "wss://localhost",
            "wss://192.168.1.10",
            "wss://relay.example.com:8080",
            "nostr+walletconnect://relay.getalby.com?relay=wss://relay.getalby.com/v1",
        ]
        let out = ComposeViewModel.capWriteRelays(junk + Self.good)
        #expect(out.count == 5)
        #expect(out.allSatisfy { RelayUrlValidator.isConnectable($0) })
        #expect(out == Array(Self.good.prefix(5)))
    }

    @Test func allJunkYieldsEmptySoTheFallbackListIsUsed() {
        let out = ComposeViewModel.capWriteRelays(["wss://localhost", "wss://https//x.y"])
        #expect(out.isEmpty)
    }
}
