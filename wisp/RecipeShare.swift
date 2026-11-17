import Foundation

/// Share identifiers for addressable long-form events (recipes and articles).
///
/// An addressable event is named by an `naddr`, not the `nevent` a note would
/// use: an `naddr` keeps pointing at the event after the author edits it,
/// where an event id names one specific revision that editing leaves behind.
///
/// One implementation for `ArticleView` and `RecipeDetailView` so the two
/// readers cannot drift on the URL shape. The canonical web route is
/// `https://zap.cooking/r/{naddr}` (`ZAPCOOKING_IOS_BUILD.md`, share URLs) —
/// never the upstream host.
@MainActor
enum RecipeShare {
    static let baseURL = "https://zap.cooking/r/"

    /// Relay hints carried in the `naddr` so a recipient's client can find the
    /// event.
    static let maxRelayHints = 2

    /// `naddr` for the event, with up to `maxRelayHints` relays it was seen on.
    static func naddr(for event: NostrEvent) -> String? {
        naddr(
            for: event,
            relays: NoteSourceTracker.shared.relays(for: event.id)
        )
    }

    /// Pure core of `naddr(for:)` — relay hints injected so it is testable
    /// without the tracker singleton.
    static func naddr(for event: NostrEvent, relays: [String]) -> String? {
        let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] ?? ""
        return Nip19.naddrEncode(
            kind: event.kind,
            pubkeyHex: event.pubkey,
            dTag: dTag,
            relays: Array(relays.prefix(maxRelayHints))
        )
    }

    /// `https://zap.cooking/r/{naddr}`; nil when the event cannot be encoded
    /// (suppress Share rather than emit a dead link).
    static func url(for event: NostrEvent) -> String? {
        naddr(for: event).map { baseURL + $0 }
    }

    static func url(for event: NostrEvent, relays: [String]) -> String? {
        naddr(for: event, relays: relays).map { baseURL + $0 }
    }
}
