import Foundation

// Lazarus: recovery of user data from relay history.
//
// The kind registry is the single source of truth for how each recoverable
// kind is counted, ranked, and warned about. The algorithm (scan / rank /
// delta / recover, `Lazarus` in LazarusRecovery.swift) never hardcodes kind
// semantics, so a new kind is added here and nowhere else.
//
// Tracks spec 0.6.1-draft, the same revision the zap.cooking web and Android
// apps follow: https://github.com/dmnyc/lazarus/blob/main/SPEC.md
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
        /// Kind 0: one "item" when there is any content at all.
        case contentPresence
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

    var id: Int { kind }

    func itemCount(_ event: NostrEvent) -> LazarusItemCount {
        switch counting {
        case .contentPresence:
            let hasContent = !event.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return LazarusItemCount(count: hasContent ? 1 : 0, partial: false)
        case .tags(let types, let mayHavePrivateItems):
            let count = LazarusPrivateItems.countItemTags(event.tags, types: types)
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
                itemSingular: "profile", itemPlural: "profiles",
                tier: 2, ranking: .recency, meaningfulEmpty: false, requiredWarnings: [],
                counting: .contentPresence, privateItemTypes: nil
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
                counting: .tags(["r"], mayHavePrivateItems: false), privateItemTypes: nil
            ),
            LazarusKindProfile(
                kind: 10050, name: "DM relays", label: "DM relays",
                itemSingular: "relay", itemPlural: "relays",
                tier: 3, ranking: .recency, meaningfulEmpty: false, requiredWarnings: [.staleRelays],
                counting: .tags(["relay"], mayHavePrivateItems: false), privateItemTypes: nil
            ),
            LazarusKindProfile(
                kind: 10006, name: "Blocked relays", label: "Blocked relays",
                itemSingular: "relay", itemPlural: "relays",
                tier: 3, ranking: .count, meaningfulEmpty: false, requiredWarnings: [],
                counting: .tags(["relay"], mayHavePrivateItems: false), privateItemTypes: nil
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
