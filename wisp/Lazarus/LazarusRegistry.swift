import Foundation

// Lazarus: recovery of user data from relay history.
//
// The kind registry is the single source of truth for how each recoverable
// kind is counted, ranked, and warned about. The algorithm (scan / rank /
// delta / recover, `Lazarus` in LazarusRecovery.swift) never hardcodes kind
// semantics, so a new kind is added here and nowhere else.
//
// Tracks spec 0.6.2-draft, the revision the zap.cooking web app follows:
// https://github.com/dmnyc/lazarus/blob/main/SPEC.md
// Ranking rules change only with a spec version bump; port changes from the
// spec rather than tuning thresholds here.

nonisolated enum LazarusRanking: Sendable {
    /// Clobber detection over item counts (spec "Rank").
    case count
    /// Newest first, the user picks; nothing is recommended.
    case recency
    /// `meaningful-empty` kinds: ranking is forbidden, the user answers an
    /// intent question and nothing is pre-selected.
    case intent
}

nonisolated enum LazarusWarning: Sendable {
    /// Restoring a mute list re-silences accounts the user may have unmuted.
    case remute
    /// An old relay list can strand the user on dead relays.
    case staleRelays
    /// The list changes how other people's clients treat the user.
    case affectsOthers
}

nonisolated struct LazarusCountRange: Equatable, Sendable {
    var min: Int
    var max: Int
}

/// How many items a version holds, at the certainty the spec's private-items
/// section describes: exact (public tags, plus decrypted private items),
/// estimated from the encrypted payload size, or flagged as unknown.
nonisolated struct LazarusItemCount: Equatable, Sendable {
    /// Publicly visible items.
    var count: Int
    /// True when encrypted private items weren't decrypted for this count.
    var partial: Bool
    /// Private items, once the encrypted content has been decrypted.
    var privateCount: Int? = nil
    /// Private items estimated from the encrypted payload size, enough to
    /// tell an emptied private list from a full one.
    var privateEstimate: LazarusCountRange? = nil

    /// Total size as a range: exact once decrypted (or when there are no
    /// private items), estimated otherwise.
    var range: LazarusCountRange {
        if let privateCount { return LazarusCountRange(min: count + privateCount, max: count + privateCount) }
        if let privateEstimate {
            return LazarusCountRange(min: count + privateEstimate.min, max: count + privateEstimate.max)
        }
        return LazarusCountRange(min: count, max: count)
    }

    /// False when encrypted private items could be neither decrypted nor sized.
    var isSizeKnown: Bool { !partial || privateEstimate != nil }
}

nonisolated struct LazarusKindProfile: Sendable, Identifiable {
    nonisolated enum Counting: Sendable {
        /// Count tags whose name is in the set. Private items apply only when
        /// the content is actually encrypted: a kind 3's content is often
        /// legacy relay JSON, which is not a hidden part of the list.
        case tags(Set<String>, mayHavePrivateItems: Bool)
        /// Kind 0: its items are the content fields that hold a value
        /// (spec 0.6.2), so a profile wiped to `{}` is empty.
        case profileFields
    }

    let kind: Int
    let name: String
    /// Short label for the kind picker.
    let label: String
    /// What one item is called on version rows and in the restore button.
    let itemSingular: String
    let itemPlural: String
    let tier: Int
    let ranking: LazarusRanking
    /// An empty item set is a defined state with its own meaning (kind 10044
    /// announces "I no longer use NIP-4e"), not the fingerprint of a
    /// clobbering client: empty versions stay valid options, are never
    /// labeled as damage, and nothing is ranked.
    let meaningfulEmpty: Bool
    let requiredWarnings: [LazarusWarning]
    let counting: Counting
    /// Tag types counted among decrypted private items (NIP-51).
    let privateItemTypes: Set<String>?
    /// True when the items are relay URLs, which compare normalized
    /// (spec 0.6.2): a client that rewrote `wss://Relay.Example/` as
    /// `wss://relay.example` changed nothing.
    let relayItems: Bool

    init(
        kind: Int, name: String, label: String,
        itemSingular: String, itemPlural: String,
        tier: Int, ranking: LazarusRanking, meaningfulEmpty: Bool,
        requiredWarnings: [LazarusWarning], counting: Counting,
        privateItemTypes: Set<String>?, relayItems: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.label = label
        self.itemSingular = itemSingular
        self.itemPlural = itemPlural
        self.tier = tier
        self.ranking = ranking
        self.meaningfulEmpty = meaningfulEmpty
        self.requiredWarnings = requiredWarnings
        self.counting = counting
        self.privateItemTypes = privateItemTypes
        self.relayItems = relayItems
    }

    /// The tag types that are items of this kind, or nil when the kind's
    /// items aren't tags.
    var itemTypes: Set<String>? {
        guard case .tags(let types, _) = counting else { return nil }
        return types
    }

    var id: Int { kind }

    func itemCount(_ event: NostrEvent) -> LazarusItemCount {
        switch counting {
        case .profileFields:
            return LazarusItemCount(count: Lazarus.profileFieldCount(event), partial: false)
        case .tags(let types, let mayHavePrivateItems):
            // Items are distinct (spec 0.6.2): a tag repeated, or a client's
            // rewrite of a relay URL's spelling, is one item, and a tag
            // without a value is none.
            let count = Set(event.tags.compactMap { itemKey($0) }).count
            guard mayHavePrivateItems, LazarusPrivateItems.encryption(of: event.content) != nil else {
                return LazarusItemCount(count: count, partial: false)
            }
            return LazarusItemCount(
                count: count,
                partial: true,
                privateEstimate: LazarusPrivateItems.estimate(event.content)
            )
        }
    }

    /// What makes a tag an item of this kind, and two tags the same item:
    /// its type and value (the relay marker counts on relay lists, since it
    /// changes what the relay is for). Nil when the tag isn't an item: it
    /// has no type or no value, or its type isn't one of this kind's.
    func itemKey(_ tag: [String]) -> [String]? {
        guard let types = itemTypes else { return nil }
        return Lazarus.itemKey(tag, kind: kind, types: types, relayItems: relayItems)
    }

    /// "1 follow" / "1,945 follows".
    func itemsLabel(_ n: Int) -> String {
        "\(n.formatted()) \(n == 1 ? itemSingular : itemPlural)"
    }
}

nonisolated enum LazarusRegistry {
    static let muteTagTypes: Set<String> = ["p", "word", "t", "e"]

    static let profiles: [Int: LazarusKindProfile] = {
        let all = [
            LazarusKindProfile(
                kind: 3, name: "Follow list", label: "Follows",
                itemSingular: "follow", itemPlural: "follows",
                tier: 1, ranking: .count, meaningfulEmpty: false, requiredWarnings: [],
                counting: .tags(["p"], mayHavePrivateItems: true), privateItemTypes: ["p"]
            ),
            LazarusKindProfile(
                kind: 10000, name: "Mute list", label: "Mutes",
                itemSingular: "muted item", itemPlural: "muted items",
                tier: 1, ranking: .count, meaningfulEmpty: false,
                requiredWarnings: [.remute, .affectsOthers],
                counting: .tags(muteTagTypes, mayHavePrivateItems: true), privateItemTypes: muteTagTypes
            ),
            LazarusKindProfile(
                kind: 0, name: "Profile", label: "Profile",
                itemSingular: "field", itemPlural: "fields",
                tier: 2, ranking: .recency, meaningfulEmpty: false, requiredWarnings: [],
                counting: .profileFields, privateItemTypes: nil
            ),
            LazarusKindProfile(
                kind: 10003, name: "Bookmarks", label: "Bookmarks",
                itemSingular: "bookmark", itemPlural: "bookmarks",
                tier: 2, ranking: .count, meaningfulEmpty: false, requiredWarnings: [],
                counting: .tags(["e", "a"], mayHavePrivateItems: true), privateItemTypes: ["e", "a"]
            ),
            // NIP-4e lists encryption pubkeys in `n` tags (spec 0.6.1 corrected
            // the registry row, which named `p` tags and read every list as empty).
            LazarusKindProfile(
                kind: 10044, name: "Encryption keys", label: "Encryption keys",
                itemSingular: "key", itemPlural: "keys",
                tier: 2, ranking: .intent, meaningfulEmpty: true, requiredWarnings: [.affectsOthers],
                counting: .tags(["n"], mayHavePrivateItems: false), privateItemTypes: nil
            ),
            LazarusKindProfile(
                kind: 10002, name: "Relay list", label: "Relay list",
                itemSingular: "relay", itemPlural: "relays",
                tier: 3, ranking: .recency, meaningfulEmpty: false, requiredWarnings: [.staleRelays],
                counting: .tags(["r"], mayHavePrivateItems: false), privateItemTypes: nil,
                relayItems: true
            ),
            LazarusKindProfile(
                kind: 10050, name: "DM relays", label: "DM relays",
                itemSingular: "relay", itemPlural: "relays",
                tier: 3, ranking: .recency, meaningfulEmpty: false, requiredWarnings: [.staleRelays],
                counting: .tags(["relay"], mayHavePrivateItems: false), privateItemTypes: nil,
                relayItems: true
            ),
            LazarusKindProfile(
                kind: 10006, name: "Blocked relays", label: "Blocked relays",
                itemSingular: "relay", itemPlural: "relays",
                tier: 3, ranking: .count, meaningfulEmpty: false, requiredWarnings: [],
                counting: .tags(["relay"], mayHavePrivateItems: false), privateItemTypes: nil,
                relayItems: true
            ),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })
    }()

    static func profile(for kind: Int) -> LazarusKindProfile? { profiles[kind] }

    /// Registry order: tier ascending, then kind ascending. This is every
    /// registered kind, the scope the zap.cooking Android app offers.
    static var ordered: [LazarusKindProfile] {
        profiles.values.sorted { ($0.tier, $0.kind) < ($1.tier, $1.kind) }
    }
}
