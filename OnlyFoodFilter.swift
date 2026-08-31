import Foundation

/// Pure, dependency-injected OnlyFood food-quality filter — the single
/// accept/reject decision for a kind-1 food note. Port of Android
/// `repo/OnlyFoodFilter.kt`.
///
/// **Pure**: no insertion, no caching, no counters, no I/O. The caller owns
/// those side effects.
///
/// **Mute-only in v1 (§7.3):** the OnlyFood collector must not call
/// `SpamScorer`. This type is the mute / block / structural / reply gate;
/// ``Decision/wotFiltered`` exists so a later opt-in WoT predicate can plug
/// in without rewriting the chain. Production wires `isWotFiltered` to a
/// no-op. Do not "helpfully" fold `SafetyFilter.shouldDrop` in here — that
/// path is fail-closed on an empty qualified network and is the
/// drawer-goes-blank failure mode Android already paid for.
///
/// Check order matches Android verbatim: future-dated → app blocklist →
/// user-blocked → deleted → muted-word → thread-muted → structural-spam →
/// reply → web-of-trust.
nonisolated struct OnlyFoodFilter: Sendable {

    enum Decision: Equatable, Sendable {
        case accept
        case futureDated
        case blockedPubkey
        case userBlocked
        case deleted
        case mutedWord
        case threadMuted
        case structuralSpam
        case reply
        case wotFiltered
    }

    /// Clock skew tolerance for future-dated events (seconds).
    static let futureSkewSeconds = 30
    /// OnlyFood structural spam caps — mirror the web client's FoodstrFeed thresholds.
    static let hellthreadPLimit = 25
    static let maxHashtags = 5

    /// App-level OnlyFood blocklist (curation). Applies to ALL users' OnlyFood
    /// feed and is SEPARATE from each user's personal mute list.
    static let blockedPubkeys: Set<String> = [
        // npub1m354es2t3hpx0wslegv7qrrpt4dmjyzh6feazktpuze0vnqw6jcqx5ps3x
        "dc695cc14b8dc267ba1fca19e00c615d5bb91057d273d15961e0b2f64c0ed4b0",
        // npub1qvv7xqpkeugn4qsa9lqjuypjttpx6gewk3gzz80mew07lgpw57sq2u5jtf
        "0319e30036cf113a821d2fc12e10325ac26d232eb450211dfbcb9fefa02ea7a0",
    ]

    var nowSeconds: @Sendable () -> Int
    var blockedPubkeys: Set<String>
    var isUserBlocked: @Sendable (String) -> Bool
    var containsMutedWord: @Sendable (String) -> Bool
    var isThreadMuted: @Sendable (String) -> Bool
    var isDeleted: @Sendable (String) -> Bool
    var isWotFiltered: @Sendable (String) -> Bool

    init(
        nowSeconds: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
        blockedPubkeys: Set<String> = OnlyFoodFilter.blockedPubkeys,
        isUserBlocked: @escaping @Sendable (String) -> Bool,
        containsMutedWord: @escaping @Sendable (String) -> Bool,
        isThreadMuted: @escaping @Sendable (String) -> Bool,
        isDeleted: @escaping @Sendable (String) -> Bool,
        isWotFiltered: @escaping @Sendable (String) -> Bool
    ) {
        self.nowSeconds = nowSeconds
        self.blockedPubkeys = blockedPubkeys
        self.isUserBlocked = isUserBlocked
        self.containsMutedWord = containsMutedWord
        self.isThreadMuted = isThreadMuted
        self.isDeleted = isDeleted
        self.isWotFiltered = isWotFiltered
    }

    /// Production v1: mute / block / structural / reply. WoT is a no-op
    /// (`isWotFiltered` always false) so an unready social graph cannot blank
    /// the feed. NIP-09 deletion is not tracked in this path yet.
    static func live() -> OnlyFoodFilter {
        OnlyFoodFilter(
            isUserBlocked: {
                let s = SafetyFilter.shared.snapshot
                return s.blockedPubkeys.contains($0) || s.reportedPubkeys.contains($0)
            },
            containsMutedWord: { content in
                let words = SafetyFilter.shared.snapshot.mutedWords
                guard !words.isEmpty else { return false }
                let lower = content.lowercased()
                for w in words where lower.contains(w) { return true }
                return false
            },
            isThreadMuted: { SafetyFilter.shared.snapshot.mutedThreads.contains($0) },
            isDeleted: { SafetyFilter.shared.snapshot.reportedEventIds.contains($0) },
            isWotFiltered: { _ in false }
        )
    }

    func decideKind1(_ event: NostrEvent) -> Decision {
        if event.createdAt > nowSeconds() + Self.futureSkewSeconds { return .futureDated }
        if blockedPubkeys.contains(event.pubkey) { return .blockedPubkey }
        if isUserBlocked(event.pubkey) { return .userBlocked }
        if isDeleted(event.id) { return .deleted }
        if containsMutedWord(event.content) { return .mutedWord }
        let threadRoot = Nip10.rootId(of: event) ?? Nip10.replyTarget(of: event) ?? event.id
        if isThreadMuted(threadRoot) { return .threadMuted }
        if Self.isStructuralSpam(event) { return .structuralSpam }
        if event.hasThreadingETag { return .reply }
        if isWotFiltered(event.pubkey) { return .wotFiltered }
        return .accept
    }

    /// Mirror the web client's structural caps: hellthread p-tags and hashtag
    /// spam. Counts **all** p-tags (not distinct) — that is the Android
    /// contract, and it is not `NostrEvent.isHellthread`.
    static func isStructuralSpam(_ event: NostrEvent) -> Bool {
        var pCount = 0
        var tCount = 0
        for tag in event.tags {
            guard let name = tag.first else { continue }
            switch name {
            case "p": pCount += 1
            case "t": tCount += 1
            default: break
            }
        }
        let hashtagCount = max(countContentHashtags(event.content), tCount)
        return pCount >= hellthreadPLimit || hashtagCount > maxHashtags
    }

    /// Count inline #hashtags in note content, mirroring the web's
    /// `HASHTAG_PATTERN = /(^|\s)#([^\s#]+)/g`.
    static func countContentHashtags(_ content: String) -> Int {
        content.matches(of: Self.contentHashtagRegex).count
    }

    private static let contentHashtagRegex = /(?:^|\s)#([^\s#]+)/
}
