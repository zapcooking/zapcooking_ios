import Foundation

nonisolated enum Nip18 {

    /// Tags for a kind-1 quote-repost referencing another event.
    /// Spec: `q` for the quoted id, `p` for the quoted author.
    ///
    /// An addressable event (recipe, article) also gets an `a` tag with its
    /// coordinate: the `q` id names one revision, and an edit replaces it, so
    /// the coordinate is what still points at the work afterwards. `q` stays
    /// an event id because the quote consumers (`QuoteGraph`, engagement,
    /// notifications) read it as one.
    static func buildQuoteTags(event: NostrEvent, relayHint: String = "") -> [[String]] {
        var tags: [[String]] = [
            ["q", event.id, relayHint],
            ["p", event.pubkey]
        ]
        if let coordinate = coordinate(of: event) {
            tags.append(["a", coordinate])
        }
        return tags
    }

    /// NIP-01 addressable range: replaced by `kind:pubkey:d`, so the event id
    /// changes on every edit.
    static func isAddressable(kind: Int) -> Bool { (30000...39999).contains(kind) }

    /// `kind:pubkey:d` for an addressable event; nil for anything else.
    static func coordinate(of event: NostrEvent) -> String? {
        guard isAddressable(kind: event.kind) else { return nil }
        let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] ?? ""
        return "\(event.kind):\(event.pubkey):\(dTag)"
    }

    /// Splits a `kind:pubkey:d` coordinate (the d-tag may itself contain `:`).
    static func parseCoordinate(_ coordinate: String) -> (kind: Int, pubkey: String, dTag: String)? {
        let parts = coordinate.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Int(parts[0]), isAddressable(kind: kind),
              parts[1].count == 64 else { return nil }
        return (kind, String(parts[1]), String(parts[2]))
    }

    /// Quote URI for `event`: `nostr:naddr…` for an addressable event, so the
    /// quote survives the author editing it; `nostr:nevent…` otherwise.
    static func appendQuoteUri(content: String, quoting event: NostrEvent, relayHints: [String] = []) -> String {
        if isAddressable(kind: event.kind) {
            let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] ?? ""
            if let naddr = Nip19.naddrEncode(
                kind: event.kind, pubkeyHex: event.pubkey, dTag: dTag, relays: Array(relayHints.prefix(2))
            ) {
                return content.isEmpty ? "nostr:\(naddr)" : "\(content)\nnostr:\(naddr)"
            }
        }
        return appendNoteUri(
            content: content, eventIdHex: event.id, relayHints: relayHints, authorHex: event.pubkey
        )
    }

    /// Append a quote URI (`\nnostr:nevent1...`) to the given content.
    static func appendNoteUri(content: String, eventIdHex: String, relayHints: [String] = [], authorHex: String? = nil) -> String {
        guard let idBytes = Hex.decode(eventIdHex) else { return content }
        let authorBytes: [UInt8]?
        if let authorHex, let bytes = Hex.decode(authorHex) {
            authorBytes = Array(bytes)
        } else {
            authorBytes = nil
        }
        guard let nevent = Nip19.neventEncode(eventId32: Array(idBytes), relays: relayHints, author32: authorBytes) else {
            return content
        }
        if content.isEmpty { return "nostr:\(nevent)" }
        return "\(content)\nnostr:\(nevent)"
    }
}
