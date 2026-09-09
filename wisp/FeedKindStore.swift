import Foundation

/// Persistence and cold-start resolution for the feed picker's selection.
///
/// Mirrors Android `FeedSubscriptionManager.resolveInitialFeedType()` /
/// `persistFeedSelection()` (unified-feed §2.4):
///
/// - The landing kind is resolved **once**, before the first subscription,
///   so the app never boots one feed and swaps.
/// - `saved ?? .onlyFood`. Applying the default **never writes** the key —
///   only an explicit user pick does — so "never chose" stays distinct from
///   "chose OnlyFood" and the default can change later without stranding
///   anyone on a stale explicit choice.
/// - A `.relay` / `.relaySet` landing whose target can't be restored falls
///   back to `.onlyFood`.
///
/// Keys are per-pubkey, alongside the pre-existing `last_relay_url_<pubkey>`
/// and `last_relay_set_<pubkey>`, which this type now owns.
enum FeedKindStore {
    /// The landing feed for a user who never picked one.
    static let defaultKind: FeedKind = .onlyFood

    /// On-disk names. Raw values are the persisted form — never renumber or
    /// rename; add new cases at the end.
    ///
    /// The names mirror Android `FeedType` (`ONLY_FOOD`, `FOLLOWS`,
    /// `EXTENDED_FOLLOWS`, `RELAY`) with one deliberate exception: iOS keeps
    /// a relay *set* as its own kind and stores it as `RELAY_SET`, whereas
    /// Android folds a set into `RELAY` and uses `LIST` for people lists. A
    /// future shared-format effort must map `RELAY_SET`, not rename it.
    enum StoredType: String {
        case onlyFood = "ONLY_FOOD"
        case follows = "FOLLOWS"
        case extendedNetwork = "EXTENDED_FOLLOWS"
        case relay = "RELAY"
        case relaySet = "RELAY_SET"

        init(_ kind: FeedKind) {
            switch kind {
            case .onlyFood: self = .onlyFood
            case .follows: self = .follows
            case .extendedNetwork: self = .extendedNetwork
            case .relay: self = .relay
            case .relaySet: self = .relaySet
            }
        }
    }

    static func typeKey(_ pubkey: String) -> String { "last_feed_type_\(pubkey)" }
    static func relayUrlKey(_ pubkey: String) -> String { "last_relay_url_\(pubkey)" }
    static func relaySetKey(_ pubkey: String) -> String { "last_relay_set_\(pubkey)" }

    /// Record an **explicit** user selection. Not called for the default.
    static func persist(_ kind: FeedKind, pubkey: String, defaults: UserDefaults = .standard) {
        defaults.set(StoredType(kind).rawValue, forKey: typeKey(pubkey))
        switch kind {
        case .relay(let url):
            defaults.set(url, forKey: relayUrlKey(pubkey))
            defaults.removeObject(forKey: relaySetKey(pubkey))
        case .relaySet(let set):
            defaults.set(set.dTag, forKey: relaySetKey(pubkey))
            defaults.removeObject(forKey: relayUrlKey(pubkey))
        case .onlyFood, .follows, .extendedNetwork:
            break
        }
    }

    /// Resolve the landing kind for `pubkey`. Pure read: never writes.
    /// `relaySet` looks a stored d-tag up in the user's relay sets; return
    /// `nil` when it no longer exists so the landing falls back.
    static func resolveInitial(
        pubkey: String,
        defaults: UserDefaults = .standard,
        relaySet: (String) -> RelaySet?
    ) -> FeedKind {
        guard let raw = defaults.string(forKey: typeKey(pubkey)),
              let stored = StoredType(rawValue: raw) else {
            return defaultKind
        }
        switch stored {
        case .onlyFood:
            return .onlyFood
        case .follows:
            return .follows
        case .extendedNetwork:
            return .extendedNetwork
        case .relay:
            guard let url = defaults.string(forKey: relayUrlKey(pubkey)),
                  let normalized = Nip51Lists.normalize(url) else {
                return defaultKind
            }
            return .relay(url: normalized)
        case .relaySet:
            guard let dTag = defaults.string(forKey: relaySetKey(pubkey)),
                  !dTag.isEmpty,
                  let set = relaySet(dTag) else {
                return defaultKind
            }
            return .relaySet(set)
        }
    }
}
