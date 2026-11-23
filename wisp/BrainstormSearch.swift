import Foundation

/// Brainstorm's NIP-50 search relay — NosFabrica's `vespa-relay` at
/// `wss://search.brainstorm.world` — the primary search backend, replacing
/// Nostr Archives (unreliable, and under incident when search was reworked).
/// Port of web `nameSearch.ts`, from the same handoff
/// (zapcooking `docs/handoffs/name-search-brainstorm.md`).
///
/// Relay rules that shape this module (verified against the live relay,
/// 2026-11-17):
///  - a NIP-50 search without `observer:<64-hex>` is refused (CLOSED,
///    auth-required) — the relay ranks through a web of trust;
///  - the observer token goes to THIS relay only. Another NIP-50 relay has
///    no such extension and may match `observer:…` as literal words, which
///    would empty the results — always split per-relay subscriptions;
///  - words shaped like `key:value` and a leading `-` are relay instructions
///    (`observer:`, `sort:`, `include:`, exclusions) — strip them from what
///    the user typed, or a user can change the viewpoint or lift the spam
///    floor from the search box;
///  - the house observer is the relay's own key, so nothing about the
///    person typing — not even their public key — is tied to a search;
///  - `limit` is not honored for short or prefix queries — slice results
///    client-side;
///  - authors below the relay's trust floor (and unscored accounts) do not
///    appear. That is the deliberate trade for ranked search; do not lift
///    it with `include:spam`.
enum BrainstormSearch {
    static let relay = "wss://search.brainstorm.world"

    /// The viewpoint the relay ranks through when the query names none — its
    /// own house key, so no user identity is ever attached to a search.
    static let houseObserver = "be7bf5de068c1d842ed34a7c270507ec940f5ea51671cfd062a95e9d09420d0a"

    /// After one unanswered query, skip the relay for this long (web backs
    /// off 30s so a hung relay doesn't add its whole timeout to every search).
    static let backoffInterval: TimeInterval = 30

    @MainActor private static var downUntil: Date = .distantPast

    @MainActor static var isDown: Bool { Date() < downUntil }

    @MainActor static func markDown() {
        downUntil = Date().addingTimeInterval(backoffInterval)
    }

    @MainActor static func clearBackoff() {
        downUntil = .distantPast
    }

    /// Record one relay's answer to a search REQ: an unanswered Brainstorm
    /// query starts the backoff window. Other relays are never marked down
    /// here — their emptiness is already handled by the coverage flags.
    @MainActor static func recordAnswer(relay: String, responded: Int) {
        if relay == Self.relay, responded == 0 {
            downUntil = Date().addingTimeInterval(backoffInterval)
        }
    }

    /// What was typed, made safe to put in a NIP-50 search string: control
    /// characters become spaces, a leading `@` goes, words shaped like
    /// `key:value` or a leading `-` are relay instructions and drop,
    /// quote-only words drop. Capped at 64 chars like web. nil when nothing
    /// searchable remains — ask no relay.
    static func cleanQuery(_ raw: String) -> String? {
        let sanitized = String(raw.unicodeScalars.map { scalar -> Character in
            (scalar.value < 0x20 || scalar.value == 0x7f) ? " " : Character(scalar)
        })
        var s = Substring(sanitized)
        while s.hasPrefix("@") { s = s.dropFirst() }
        let kept = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { word in
                guard !word.isEmpty else { return false }
                if word.hasPrefix("-") { return false }
                if word.range(of: "^[a-z]+:\\S", options: [.regularExpression, .caseInsensitive]) != nil { return false }
                if word.range(of: "^['\"*]+$", options: .regularExpression) != nil { return false }
                return true
            }
        let capped = String(kept.joined(separator: " ").prefix(64))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// The search string for one relay: Brainstorm gets the cleaned text plus
    /// the house observer token; every other relay gets the cleaned text only.
    /// Never send the observer form to another relay.
    static func searchQueryString(forRelay url: String, query: String) -> String? {
        guard let cleaned = cleanQuery(query) else { return nil }
        return url == relay ? "\(cleaned) observer:\(houseObserver)" : cleaned
    }
}
