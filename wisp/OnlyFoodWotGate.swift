import Foundation

/// The OnlyFood web-of-trust decision, frozen for one load (§3.4). Port of
/// Android `EventRepository.isOnlyFoodWotFiltered`, all four guards in order:
///
///     if !enabled        { return false }   // opt-in, default OFF
///     if !networkReady   { return false }   // empty-feed guard
///     if pubkey == me    { return false }
///     if inNetwork || inSeed { return false }
///     return true
///
/// plus one fail-open guard of our own between the last two: while the
/// curator food seed has not loaded yet we cannot tell a seed author from a
/// stranger, so nobody is dropped until it has (finding 2 in PR 5).
///
/// Deliberately separate from the global `SafetyFilter` / `wotFilterEnabled`
/// path, which is fail-closed on an empty qualified network — the blank-feed
/// mode Android already paid for, and this is the landing surface.
nonisolated struct OnlyFoodWotSnapshot: Sendable, Equatable {
    var enabled: Bool
    var networkReady: Bool
    var seedLoaded: Bool
    var currentUser: String
    /// First-degree follows ∪ qualified second-degree (Android
    /// `isInQualifiedNetwork`'s two sets).
    var network: Set<String>
    /// The curator's follow list (Android `isInFoodSeed`).
    var seed: Set<String>

    static let off = OnlyFoodWotSnapshot(
        enabled: false, networkReady: false, seedLoaded: false, currentUser: "", network: [], seed: []
    )

    func isFiltered(_ pubkey: String) -> Bool {
        if !enabled { return false }
        if !networkReady { return false }
        if pubkey == currentUser { return false }
        if network.contains(pubkey) || seed.contains(pubkey) { return false }
        if !seedLoaded { return false }
        return true
    }

    /// Android `isNetworkReady`: a computed cache exists and is not stale —
    /// `SocialGraphCache.isStale` is the 24 h TTL + 10 % follow-drift rule
    /// Android uses. "Cache exists" alone is not enough: a stale cache fails
    /// open here, and a computed-but-empty one is not a trust set.
    @MainActor
    static func networkIsReady(_ cache: SocialGraphCache?, currentFollows: [String]) -> Bool {
        guard let cache else { return false }
        if cache.firstDegreePubkeys.isEmpty && cache.qualifiedPubkeys.isEmpty { return false }
        return !cache.isStale(currentFollows: currentFollows)
    }

    @MainActor
    static func make(
        enabled: Bool,
        cache: SocialGraphCache?,
        currentFollows: [String],
        currentUser: String,
        seed: [String]
    ) -> OnlyFoodWotSnapshot {
        let ready = networkIsReady(cache, currentFollows: currentFollows)
        var network: Set<String> = []
        if let cache {
            network.formUnion(cache.firstDegreePubkeys)
            network.formUnion(cache.qualifiedPubkeys)
        }
        return OnlyFoodWotSnapshot(
            enabled: enabled,
            networkReady: ready,
            seedLoaded: !seed.isEmpty,
            currentUser: currentUser,
            network: network,
            seed: Set(seed)
        )
    }
}

/// Lock-protected holder for the current ``OnlyFoodWotSnapshot`` so the
/// filter's `@Sendable` predicate can read it without an actor hop (same
/// shape as `SafetyFilter.snapshot`). The view model refreshes it once per
/// load; the predicate then answers per event from the frozen copy.
nonisolated final class OnlyFoodWotGate: @unchecked Sendable {
    static let shared = OnlyFoodWotGate()

    private let lock = NSLock()
    private var _snapshot = OnlyFoodWotSnapshot.off

    var snapshot: OnlyFoodWotSnapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    func install(_ snapshot: OnlyFoodWotSnapshot) {
        lock.lock()
        _snapshot = snapshot
        lock.unlock()
    }

    func isFiltered(_ pubkey: String) -> Bool {
        snapshot.isFiltered(pubkey)
    }

    /// Rebuild from the live sources — the OnlyFood toggle, the social-graph
    /// cache, the current follow list and the curator seed — and install it.
    /// When the gate is on and the seed has not loaded, kick the one-time
    /// seed fetch (Android `ensureFoodSeedLoaded` in `subscribeOnlyFoodFeed`)
    /// and re-install once it lands; until then the snapshot fails open.
    @MainActor
    @discardableResult
    func refresh(pubkey: String) -> OnlyFoodWotSnapshot {
        let seedRepo = FoodSeedRepository.shared
        let snapshot = OnlyFoodWotSnapshot.make(
            enabled: SafetyPreferences.shared.onlyFoodWotEnabled,
            cache: SocialGraphCache.load(pubkey: pubkey),
            currentFollows: FollowsCache.shared.follows(for: pubkey),
            currentUser: pubkey,
            seed: seedRepo.pubkeys
        )
        install(snapshot)
        if snapshot.enabled, !snapshot.seedLoaded {
            Task { @MainActor in
                await seedRepo.ensureLoaded()
                if !seedRepo.pubkeys.isEmpty { self.refresh(pubkey: pubkey) }
            }
        }
        return snapshot
    }
}
