import Foundation

/// Pure, dependency-injected OnlyFood food-quality filter — the single
/// accept/reject decision for a kind-1 food note (`decideKind1`, port of
/// Android `repo/OnlyFoodFilter.kt`), plus the poll and repost decisions
/// (`decidePoll`, `decideRepost`, port of the poll / kind-6 branches of
/// Android `EventRepository.addHashtagFeedEvent`).
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
        /// Kind-6 whose `content` is blank or not a kind-1 event JSON.
        case unparseable
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
    /// the feed. `isDeleted` is the reporter-local hide set (successful
    /// NIP-56), not NIP-09 tombstones — those are still untracked here.
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

    /// NIP-88 poll (kind 1068). Android `addHashtagFeedEvent`'s pre-checks
    /// (future-dated → app blocklist → user-blocked → deleted) then the poll
    /// branch: muted word on content → structural spam → web-of-trust.
    func decidePoll(_ event: NostrEvent) -> Decision {
        if let pre = preCheck(event) { return pre }
        if containsMutedWord(event.content) { return .mutedWord }
        if Self.isStructuralSpam(event) { return .structuralSpam }
        if isWotFiltered(event.pubkey) { return .wotFiltered }
        return .accept
    }

    /// NIP-18 repost (kind 6). Android's pre-checks run on the OUTER event;
    /// the inner note is parsed from `content` (blank or unparseable → drop
    /// silently) and then judged: app blocklist → user-blocked → muted word
    /// on the inner content → structural spam on the inner note → web of
    /// trust, which drops only when BOTH the reposter and the inner author
    /// fail — a trusted reposter surfacing a stranger's food note is allowed.
    ///
    /// Whether the inner note is a reply is the caller's business: Android
    /// still records the repost attribution for a reply and only skips the
    /// list insert, so that rule lives at the insert site, not here.
    func decideRepost(_ event: NostrEvent) -> (decision: Decision, inner: NostrEvent?) {
        if let pre = preCheck(event) { return (pre, nil) }
        let trimmed = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let inner = NostrEvent.fromJSON(trimmed), inner.kind == 1 else {
            return (.unparseable, nil)
        }
        if blockedPubkeys.contains(inner.pubkey) { return (.blockedPubkey, inner) }
        if isUserBlocked(inner.pubkey) { return (.userBlocked, inner) }
        if containsMutedWord(inner.content) { return (.mutedWord, inner) }
        if Self.isStructuralSpam(inner) { return (.structuralSpam, inner) }
        if isWotFiltered(event.pubkey) && isWotFiltered(inner.pubkey) { return (.wotFiltered, inner) }
        return (.accept, inner)
    }

    /// The checks Android runs on every event before switching on kind.
    private func preCheck(_ event: NostrEvent) -> Decision? {
        if event.createdAt > nowSeconds() + Self.futureSkewSeconds { return .futureDated }
        if blockedPubkeys.contains(event.pubkey) { return .blockedPubkey }
        if isUserBlocked(event.pubkey) { return .userBlocked }
        if isDeleted(event.id) { return .deleted }
        return nil
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
