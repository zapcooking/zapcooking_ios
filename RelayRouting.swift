import Foundation

/// Shared helpers for picking which relays to publish to. Centralizes the "top write relays
/// per pubkey" rule so both the composer and ad-hoc senders (poll votes, etc.) stay in sync.
enum RelayRouting {

    /// The top 5 scored relays for `pubkey` (from `RelayScoreBoard`), or a small static
    /// fallback list if no scoreboard exists yet.
    static func topWriteRelays(for pubkey: String) -> [String] {
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            let top = board.scoredRelays.prefix(5).map(\.url)
            if !top.isEmpty { return top }
        }
        return ["wss://relay.primal.net", "wss://nos.lol"]
    }
}
