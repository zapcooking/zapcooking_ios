import Foundation

/// What Fresh's special cards have already shown, per account, on this
/// device only (ported from web `specialsPrefs.ts` + `recipeBox.ts`). Never
/// sent anywhere; removed with the account (`NostrKey` wipe list).
///
/// - Shown posts: spotlight post id → when shown (seconds); never shown twice.
/// - Recipe box: recipe coordinate → when shown.
/// - Topic history: spotlight slug → when last shown, so later sessions
///   favor topics not seen recently.
///
/// Posts and recipes are kept 90 days, at most the 1,000 newest; topic
/// history keeps the 100 most recent.
///
/// ≠ web: per account (`…_<pubkey>`), since an iOS device holds several
/// accounts; web keeps one key per browser (Seth, 2026-11-11). Web's
/// `fewer` / `hiddenTopics` / `off` choices are not ported (no menus in v1).
nonisolated struct FreshSpecialsStore {
    let pubkey: String
    let defaults: UserDefaults

    init(pubkey: String, defaults: UserDefaults = .standard) {
        self.pubkey = pubkey
        self.defaults = defaults
    }

    static func shownKey(_ pubkey: String) -> String { "fresh_specials_shown_\(pubkey)" }
    static func recipeBoxSeenKey(_ pubkey: String) -> String { "fresh_recipe_box_seen_\(pubkey)" }
    static func topicHistoryKey(_ pubkey: String) -> String { "fresh_spotlight_topics_\(pubkey)" }

    /// Every key this store writes for `pubkey` (the account wipe list).
    static func allKeys(_ pubkey: String) -> [String] {
        [shownKey(pubkey), recipeBoxSeenKey(pubkey), topicHistoryKey(pubkey)]
    }

    // MARK: - Pruning

    /// Entries younger than the TTL, at most the `max` newest.
    static func prune(_ m: [String: Int], now: Int,
                      ttl: Int = FreshSpecialsConfig.shownTtlSeconds,
                      max: Int = FreshSpecialsConfig.shownMax) -> [String: Int] {
        let fresh = m.filter { $0.value > now - ttl }
        guard fresh.count > max else { return fresh }
        let kept = fresh.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(max)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    // MARK: - Shown spotlight posts

    func loadShown(now: Int) -> [String: Int] {
        Self.prune(read(Self.shownKey(pubkey)), now: now)
    }

    @discardableResult
    func markShown(_ ids: [String], now: Int) -> [String: Int] {
        var next = read(Self.shownKey(pubkey))
        for id in ids { next[id] = now }
        let pruned = Self.prune(next, now: now)
        defaults.set(pruned, forKey: Self.shownKey(pubkey))
        return pruned
    }

    // MARK: - Recipe box

    func loadRecipeBoxSeen(now: Int) -> [String: Int] {
        Self.prune(read(Self.recipeBoxSeenKey(pubkey)), now: now)
    }

    @discardableResult
    func markRecipeBoxSeen(_ address: String, now: Int) -> [String: Int] {
        var next = read(Self.recipeBoxSeenKey(pubkey))
        next[address] = now
        let pruned = Self.prune(next, now: now)
        defaults.set(pruned, forKey: Self.recipeBoxSeenKey(pubkey))
        return pruned
    }

    // MARK: - Topic history

    func loadTopicHistory() -> [String: Int] {
        read(Self.topicHistoryKey(pubkey))
    }

    @discardableResult
    func markTopicShown(_ slug: String, now: Int) -> [String: Int] {
        var next = read(Self.topicHistoryKey(pubkey))
        next[slug] = now
        let kept = Self.prune(next, now: now, ttl: Int.max / 2, max: FreshSpecialsConfig.topicHistoryMax)
        defaults.set(kept, forKey: Self.topicHistoryKey(pubkey))
        return kept
    }

    // MARK: - Storage

    /// A stored `[String: Int]`; anything else (missing, a different type,
    /// non-integer values) reads as empty or drops the bad entries.
    private func read(_ key: String) -> [String: Int] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var out: [String: Int] = [:]
        for (k, v) in raw {
            if let n = v as? Int { out[k] = n }
        }
        return out
    }
}
