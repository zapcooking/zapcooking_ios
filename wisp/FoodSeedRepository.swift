import Foundation

/// The Zap Cooking curator account. Its kind-3 follow list is the food-creator
/// seed shown as "Meet the creators" at sign-up — an operational list
/// maintained by following people *from that account*, not a hardcoded pack.
/// Mirrors Android `ExtendedNetworkRepository.ZC_CURATOR_PUBKEY`; the literal
/// lives here and nowhere else.
nonisolated enum ZapCookingCurator {
    static let pubkey = "319ad3e790634dbe86f14db9c2995b26ee3c6228be55f89c4c7fea9acc01d50a"
}

/// Fetches and caches the curator's follow list (the OnlyFood "food seed").
///
/// Port of Android `ExtendedNetworkRepository.ensureFoodSeedLoaded` /
/// `getFoodSeedPubkeys`: one REQ for the curator's kind-3 on the OnlyFood +
/// indexer relays, newest replaceable wins, its `p` tags become the seed, and
/// the result is persisted so later launches start warm. Empty until the first
/// successful fetch; a failed fetch never clears a previously cached seed.
///
/// Main-actor isolated (explicitly, not just by the target default): the
/// cached list and the in-flight flag are read and written from sign-up UI.
@MainActor
final class FoodSeedRepository {
    static let shared = FoodSeedRepository()

    /// Relays the food seed and "Active in the kitchen" are read from.
    /// Mirrors Android `FeedSubscriptionManager.ONLY_FOOD_RELAYS`.
    static let onlyFoodRelays: [String] = [
        SearchViewModel.defaultSearchRelay,
        "wss://nos.lol",
        "wss://relay.primal.net"
    ]

    private static let cacheKey = "zc_food_seed_pubkeys"
    private static let fetchTimeout: TimeInterval = 6

    /// The curator's follows, in kind-3 tag order. Empty until loaded.
    private(set) var pubkeys: [String]
    private var loading = false
    private let defaults: UserDefaults

    /// The cached value is sanitized on read (lowercase 64-hex, deduplicated,
    /// curator dropped) and written back when that changed anything, so a
    /// corrupt or hand-edited cache can never pin `pubkeys` to an unusable
    /// list and suppress the refetch.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.cacheKey) ?? []
        let clean = Self.sanitize(stored)
        self.pubkeys = clean
        if clean != stored {
            if clean.isEmpty {
                defaults.removeObject(forKey: Self.cacheKey)
            } else {
                defaults.set(clean, forKey: Self.cacheKey)
            }
        }
    }

    /// Load the seed if it isn't already cached. Concurrent callers coalesce
    /// on the `loading` flag; the second caller returns immediately with
    /// whatever is cached (matches Android's compare-and-set).
    func ensureLoaded() async {
        if !pubkeys.isEmpty || loading { return }
        loading = true
        defer { loading = false }
        let relays = Self.onlyFoodRelays + RelayDefaults.onboarding
        let events = await RelayPool.query(
            relays: Array(Set(relays)),
            filter: NostrFilter(kinds: [3], authors: [ZapCookingCurator.pubkey]),
            timeout: Self.fetchTimeout
        )
        let seed = Self.parseSeed(from: events)
        guard !seed.isEmpty else { return }
        pubkeys = seed
        defaults.set(seed, forKey: Self.cacheKey)
    }

    /// Zap Cooking's card when its kind-0 didn't load, so the pre-selected
    /// follow stays visible and toggleable (Android `ZC_FALLBACK_PROFILE`).
    static var curatorFallbackProfile: ProfileData {
        ProfileData(
            pubkey: ZapCookingCurator.pubkey,
            json: ["name": "Zap Cooking", "display_name": "Zap Cooking"]
        )
    }

    // MARK: - Pure helpers (tested)

    /// A pubkey as the seed stores it — lowercase 64-hex — or nil.
    nonisolated static func normalizedPubkey(_ raw: String) -> String? {
        let pk = raw.lowercased()
        guard pk.count == 64, pk.allSatisfy(\.isHexDigit) else { return nil }
        return pk
    }

    /// Normalize, drop invalid entries and the curator itself, deduplicate,
    /// preserve order. Applied to both a parsed kind-3 and the on-disk cache.
    nonisolated static func sanitize(_ raw: [String]) -> [String] {
        var seen: Set<String> = [ZapCookingCurator.pubkey]
        var out: [String] = []
        for candidate in raw {
            guard let pk = normalizedPubkey(candidate) else { continue }
            if seen.insert(pk).inserted { out.append(pk) }
        }
        return out
    }

    /// The curator's follows from the newest kind-3 among `events`. Only
    /// kind-3 events signed by the curator count; `p` tags must be 64-hex;
    /// duplicates and the curator's own pubkey are dropped, order preserved.
    nonisolated static func parseSeed(from events: [NostrEvent]) -> [String] {
        let latest = events
            .filter { $0.kind == 3 && $0.pubkey == ZapCookingCurator.pubkey }
            .max { $0.createdAt < $1.createdAt }
        guard let latest else { return [] }
        let pTags = latest.tags.compactMap { tag -> String? in
            tag.count >= 2 && tag[0] == "p" ? tag[1] : nil
        }
        return sanitize(pTags)
    }

    /// The "Meet the creators" order: Zap Cooking first, then the seed,
    /// deduplicated and capped (Android `loadCreators`: `(listOf(ZC_PUBKEY) +
    /// seed).distinct().take(MAX_CREATORS)`).
    nonisolated static func creatorOrder(seed: [String], cap: Int) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for pk in [ZapCookingCurator.pubkey] + seed where seen.insert(pk).inserted {
            out.append(pk)
            if out.count >= cap { break }
        }
        return out
    }
}
