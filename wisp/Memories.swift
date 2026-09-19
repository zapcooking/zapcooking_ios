import Foundation

/// Memories — "On this day". Finds the signed-in user's OWN kind-1 notes from
/// this same calendar day 1, 2, and 3 years ago, fetched from relays, with a
/// per-day cache so relays are queried at most once per day per user.
///
/// Port of Android `repo/MemoriesRepository.kt` (itself a port of the web's
/// `src/lib/memories.ts`). Read-only — no new event kind, nothing published, so
/// §7.13's live-write protocol does not apply.
///
/// The pure helpers (`memoryWindows`, `isMemoryReply`, `shouldCacheMemories`,
/// `memoriesLocalDateKey`) are top-level functions, deliberately, so they are
/// unit-testable without a relay or a view. Android did the same.

// MARK: - Types

nonisolated enum MemoryResolved: String, Codable, Sendable {
    case eose
    case timeout
}

nonisolated struct MemoryWindow: Equatable, Sendable {
    let yearsAgo: Int
    /// Unix seconds, 00:00:00 local time on the target day.
    let since: Int
    /// Unix seconds, 23:59:59 local time on the target day.
    let until: Int
}

nonisolated struct MemoryGroup: Sendable {
    let yearsAgo: Int
    /// Start of the target day (unix seconds, local midnight).
    let dateSec: Int
    /// Oldest first.
    let events: [NostrEvent]
    /// How the window's fetch resolved. `.timeout` means no relay ever sent
    /// EOSE, so an empty result may just mean "relays didn't answer" — used by
    /// `shouldCacheMemories` to decide whether an empty day is cacheable.
    let resolvedVia: MemoryResolved
}

// MARK: - Date windows (pure)

nonisolated func isLeapYear(_ year: Int) -> Bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// Local-time day windows for 1, 2, and 3 years before `now`, computed in
/// `calendar`'s time zone so "this day" means the USER's day. Feb 29 falls back
/// to Feb 28 in non-leap target years (mirrors the web's `getMemoryWindows`).
nonisolated func memoryWindows(now: Date, calendar: Calendar = .current) -> [MemoryWindow] {
    let parts = calendar.dateComponents([.year, .month, .day], from: now)
    guard let nowYear = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return [] }
    return [1, 2, 3].compactMap { yearsAgo in
        let year = nowYear - yearsAgo
        var day = dayOfMonth
        if month == 2, day == 29, !isLeapYear(year) { day = 28 }
        var startParts = DateComponents()
        startParts.year = year; startParts.month = month; startParts.day = day
        startParts.hour = 0; startParts.minute = 0; startParts.second = 0
        var endParts = startParts
        endParts.hour = 23; endParts.minute = 59; endParts.second = 59
        guard let start = calendar.date(from: startParts), let end = calendar.date(from: endParts) else { return nil }
        return MemoryWindow(
            yearsAgo: yearsAgo,
            since: Int(start.timeIntervalSince1970),
            until: Int(end.timeIntervalSince1970)
        )
    }
}

// MARK: - Reply predicate (pure, NIP-10 aware)

/// True if the event is a reply per NIP-10: it has a non-empty `e` tag marked
/// `root`/`reply`, an unmarked `e` tag (legacy positional reply), or an `e`
/// tag with an unknown marker. Mention-only `e` tags and `q`-tag quotes are
/// NOT replies. Marker comparison is case-insensitive; `e` tags with no id or
/// an empty id are ignored.
///
/// Deliberately not `NostrEvent.hasThreadingETag` / `Nip10`: those compare
/// `"mention"` case-sensitively and count id-less `e` tags (`hasThreadingETag`
/// even counts a bare `["e"]`). Android hit the same defects in its own
/// `Nip10.isReply` and wrote this predicate separately; the shared-helper fix
/// is filed as its own concern.
nonisolated func isMemoryReply(_ event: NostrEvent) -> Bool {
    let eTags = event.tags.filter { $0.count >= 2 && $0[0] == "e" && !$0[1].isEmpty }
    if eTags.isEmpty { return false }
    return eTags.contains { tag in
        guard tag.count >= 4 else { return true }
        return tag[3].lowercased() != "mention"
    }
}

// MARK: - Cache gating (pure)

/// A result is durably cacheable only when COMPLETE: EVERY window resolved via
/// EOSE — i.e. at least one queried relay sent EOSE for that window, so the
/// query reached a relay that finished its stored-events scan. A window that
/// resolved via TIMEOUT saw NO EOSE at all, so there's no evidence any relay
/// finished — its emptiness may be a transient miss (especially the deep
/// 3-year window, whose notes live on slower/fewer archive relays), so a
/// PARTIAL result is not cached; it re-fetches next open and self-heals.
///
/// An EOSE'd window with genuinely zero notes IS cacheable ("nothing that
/// day"); a TIMEOUT window is not — that's the distinction. Stricter than the
/// web's any-EOSE rule on purpose: caching a partial (1-year had notes, 3-year
/// timed out) froze the 3-year window empty even though those notes exist.
nonisolated func shouldCacheMemories(_ groups: [MemoryGroup]) -> Bool {
    !groups.isEmpty && groups.allSatisfy { $0.resolvedVia == .eose }
}

/// Local-time `YYYY-MM-DD` key for `now` in `calendar`'s time zone.
nonisolated func memoriesLocalDateKey(now: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: now)
    let y = parts.year ?? 0, m = parts.month ?? 0, d = parts.day ?? 0
    return String(format: "%04d-%02d-%02d", y, m, d)
}

// MARK: - Per-day cache + dismissal (UserDefaults, account-scoped)

/// Storage on the `SocialGraphCache` pattern: flat `UserDefaults` keys
/// `memories_<version>_<pubkey>` / `memories_dismissed_<pubkey>`, JSON `Data`
/// payloads. `defaults` is injected so tests use a throwaway suite.
///
/// One entry per pubkey holding today's date key — writing today's entry is
/// what prunes yesterday's, so the store never grows.
nonisolated struct MemoriesStore {
    /// Cache schema version — bump to abandon a poisoned cache. iOS starts at
    /// v1: Android is on v2 only because it had to abandon caches poisoned by
    /// the partial-result bug; iOS never shipped that bug.
    static let cacheVersion = "v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func cacheKey(_ pubkey: String) -> String { "memories_\(cacheVersion)_\(pubkey)" }
    static func dismissKey(_ pubkey: String) -> String { "memories_dismissed_\(pubkey)" }

    private struct StoredGroup: Codable {
        var yearsAgo: Int
        var dateSec: Int
        var resolvedVia: MemoryResolved
        /// Events as NIP-01 JSON strings (`NostrEvent.toJSON`).
        var events: [String]
    }

    private struct StoredMemories: Codable {
        var dateKey: String
        var groups: [StoredGroup]
    }

    /// Today's cached groups if present AND complete. A cached PARTIAL (any
    /// non-EOSE window) reads as a MISS so it re-fetches and self-heals —
    /// only all-EOSE results are written, but a stale or hand-edited entry
    /// must not freeze a window empty either.
    func readCache(pubkey: String, dateKey: String) -> [MemoryGroup]? {
        guard let data = defaults.data(forKey: Self.cacheKey(pubkey)),
              let stored = try? JSONDecoder().decode(StoredMemories.self, from: data),
              stored.dateKey == dateKey else { return nil }
        let groups = stored.groups.map { g in
            MemoryGroup(
                yearsAgo: g.yearsAgo,
                dateSec: g.dateSec,
                events: g.events.compactMap(NostrEvent.fromJSON),
                resolvedVia: g.resolvedVia
            )
        }
        guard shouldCacheMemories(groups) else { return nil }
        return groups
    }

    /// Overwrite the pubkey's entry with today's groups. Callers gate on
    /// `shouldCacheMemories` first; this is the raw write.
    func writeCache(pubkey: String, dateKey: String, groups: [MemoryGroup]) {
        let stored = StoredMemories(
            dateKey: dateKey,
            groups: groups.map {
                StoredGroup(yearsAgo: $0.yearsAgo, dateSec: $0.dateSec,
                            resolvedVia: $0.resolvedVia, events: $0.events.map { $0.toJSON() })
            }
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.cacheKey(pubkey))
    }

    func isDismissed(pubkey: String, dateKey: String) -> Bool {
        defaults.string(forKey: Self.dismissKey(pubkey)) == dateKey
    }

    /// Dismiss the teaser for `dateKey`. Overwrites any prior day's dismissal.
    func dismiss(pubkey: String, dateKey: String) {
        defaults.set(dateKey, forKey: Self.dismissKey(pubkey))
    }

    /// Clear today's dismissal (the card's Undo affordance).
    func undismiss(pubkey: String, dateKey: String) {
        guard isDismissed(pubkey: pubkey, dateKey: dateKey) else { return }
        defaults.removeObject(forKey: Self.dismissKey(pubkey))
    }
}

// MARK: - Relay fetch

nonisolated struct MemoriesFetchRequest: Sendable {
    let pubkey: String
    let window: MemoryWindow
    let relays: [String]
    let subId: String
}

nonisolated struct MemoriesFetchResult: Sendable {
    /// Raw collected events — replies and empties not yet filtered.
    let events: [NostrEvent]
    let resolvedVia: MemoryResolved
}

/// Production relay client: one REQ per window on the memory relay union,
/// CLOSE only that subId on the relays it was opened on (§7.5).
///
/// Main-actor like `OnlyFoodRelay`: `NostrFilter.toJSON` and `RelaySink` are
/// main-actor types, and the wait loop only polls a lock-protected collector.
enum MemoriesRelay {
    /// Archive-friendly relays that keep old notes, unioned with
    /// `RelayDefaults.defaults` (Android `MemoriesRepository.ARCHIVE_RELAYS`).
    ///
    /// Retention re-measured 2026-09-19 (author-scoped kind-1 REQs on the
    /// actual 1/2/3-year windows for two accounts with 2022 history):
    /// - `nostr.wine` and `nos.lol`: full pages in every window and at four
    ///   years back, EOSE in 250–800 ms. The real archives.
    /// - `relay.nostr.net`: full at 1y/2y, 1 note at 3y where the two above
    ///   returned 9–18. Patchy that deep; it stays via `defaults`.
    /// - `relay.primal.net`: ZERO events in every window — 1y included, not
    ///   just "past three years" as Android's 2026-07-26 comment says. It is
    ///   not an archive and is not listed here; it rides along only because
    ///   it is in `defaults`.
    /// - `relay.damus.io`: HTTP 503 on about half the connects, 0 events when
    ///   it answered. `eden.nostr.land`: has the notes but AUTH-challenges
    ///   first. Neither belongs in an unauthenticated read.
    nonisolated static let archiveRelays: [String] = [
        "wss://nostr.wine",
    ]

    /// `RelayDefaults.defaults` ∪ `archiveRelays`, order-preserving, deduped.
    nonisolated static var relays: [String] {
        var seen = Set<String>()
        return (RelayDefaults.defaults + archiveRelays).filter { seen.insert($0).inserted }
    }

    static let windowLimit = 50
    /// Budget to bring an archive relay's socket up before the REQ.
    static let connectTimeout: TimeInterval = 8
    /// Base EOSE budget for the shallowest (1-year) window.
    static let eoseTimeoutBase: TimeInterval = 10
    /// Extra EOSE budget per year of depth — the 3-year window gets +2×this.
    static let eoseTimeoutPerYear: TimeInterval = 2
    /// Straggler window after a REAL EOSE before teardown (archive relays
    /// drip late). Not added after a timeout: an all-timeout window has no
    /// evidence anyone will deliver.
    static let eoseGrace: TimeInterval = 4

    /// Deeper windows get more EOSE budget: their notes live on slower/fewer
    /// archive relays that take longer to dig out cold events, so the 3-year
    /// window isn't torn down before it can deliver.
    static func eoseTimeout(yearsAgo: Int) -> TimeInterval {
        eoseTimeoutBase + TimeInterval(max(0, yearsAgo - 1)) * eoseTimeoutPerYear
    }

    static func filter(pubkey: String, window: MemoryWindow) -> NostrFilter {
        NostrFilter(kinds: [1], authors: [pubkey], limit: windowLimit, since: window.since, until: window.until)
    }

    /// Never throws — resolves to an empty `.timeout` result on trouble.
    ///
    /// `RelayConnectionPool` queues the REQ per relay and sends it the moment
    /// that socket comes up, so Android's separate "connect first" gate is
    /// implicit; the connect budget is folded into one deadline
    /// (`connectTimeout + eoseTimeout`) measured from register. EOSE from ANY
    /// relay ends the wait (then the grace); zero EOSEs by the deadline is
    /// `.timeout`.
    static func fetch(_ request: MemoriesFetchRequest) async -> MemoriesFetchResult {
        let urls = request.relays.compactMap(RelayPool.wsURL)
        guard !urls.isEmpty else { return MemoriesFetchResult(events: [], resolvedVia: .timeout) }

        let collector = MemoriesCollector()
        let reqFrame = "[\"REQ\",\"\(request.subId)\",\(filter(pubkey: request.pubkey, window: request.window).toJSON())]"
        let relayReqs = urls.map { (url: $0, req: reqFrame) }
        let sink = RelaySink(
            onEvent: { event, _ in collector.add(event) },
            onEose: { _ in collector.markEose() }
        )
        // A refused register (connection cap) is a connect miss — do not wait
        // for an EOSE that cannot arrive.
        let registered = await RelayConnectionPool.shared.register(
            subId: request.subId, relays: relayReqs, sink: sink
        )
        if registered == 0 {
            await RelayConnectionPool.shared.deregister(subId: request.subId)
            return MemoriesFetchResult(events: [], resolvedVia: .timeout)
        }

        let budget = connectTimeout + eoseTimeout(yearsAgo: request.window.yearsAgo)
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline, !Task.isCancelled {
            if collector.eoseCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let resolved: MemoryResolved = collector.eoseCount > 0 ? .eose : .timeout
        if resolved == .eose, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(eoseGrace))
        }

        await RelayConnectionPool.shared.deregister(subId: request.subId)
        return MemoriesFetchResult(events: collector.events, resolvedVia: resolved)
    }
}

private final class MemoriesCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [NostrEvent] = []
    private var seen = Set<String>()
    private var _eose = 0

    func add(_ event: NostrEvent) {
        lock.lock(); defer { lock.unlock() }
        guard seen.insert(event.id).inserted else { return }
        _events.append(event)
    }

    func markEose() {
        lock.lock(); defer { lock.unlock() }
        _eose += 1
    }

    var events: [NostrEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    var eoseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _eose
    }
}

/// Process-wide subId sequence (§7.2) — unique across every repository /
/// screen instance for the life of the process. An instance-scoped counter
/// restarting at 0 per nav entry is the bug this exists to not re-earn.
nonisolated final class MemoriesSubSeq: @unchecked Sendable {
    static let shared = MemoriesSubSeq()
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func nextSubId(yearsAgo: Int) -> String {
        "memories-\(yearsAgo)-\(next())"
    }
}

// MARK: - Repository

/// Memories service. Holds the read-only relay/cache plumbing; one shared
/// instance serves the teaser card and the full screen so a day's fetch runs
/// once even when both mount together.
@MainActor
final class MemoriesRepository {
    static let shared = MemoriesRepository()

    typealias Fetch = @Sendable (MemoriesFetchRequest) async -> MemoriesFetchResult

    private let store: MemoriesStore
    private let fetch: Fetch
    private let relays: [String]
    private let calendar: Calendar
    private let persistEvents: @MainActor ([NostrEvent]) async -> Void

    /// In-flight cache-first loads keyed by `pubkey|dateKey`, so the card and
    /// the screen mounting together share one relay round instead of two.
    private var inFlight: [String: Task<[MemoryGroup], Never>] = [:]

    init(
        store: MemoriesStore = MemoriesStore(),
        fetch: @escaping Fetch = { await MemoriesRelay.fetch($0) },
        relays: [String] = MemoriesRelay.relays,
        calendar: Calendar = .current,
        persistEvents: @escaping @MainActor ([NostrEvent]) async -> Void = { EventStore.shared.persist($0) }
    ) {
        self.store = store
        self.fetch = fetch
        self.relays = relays
        self.calendar = calendar
        self.persistEvents = persistEvents
    }

    func dateKey(now: Date = Date()) -> String {
        memoriesLocalDateKey(now: now, calendar: calendar)
    }

    // MARK: fetch

    /// Fetch one window: REQ on the relay union, await EOSE with the depth-
    /// graduated budget, then filter to the author's non-reply, non-empty
    /// kind-1 notes, oldest first.
    private func fetchWindow(pubkey: String, window: MemoryWindow) async -> MemoryGroup {
        let request = MemoriesFetchRequest(
            pubkey: pubkey,
            window: window,
            relays: relays,
            subId: MemoriesSubSeq.shared.nextSubId(yearsAgo: window.yearsAgo)
        )
        let result = await fetch(request)
        let events = result.events
            .filter { $0.kind == 1 && $0.pubkey == pubkey }
            .filter { $0.createdAt >= window.since && $0.createdAt <= window.until }
            .filter { !isMemoryReply($0) && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
        if !events.isEmpty {
            // Kind 1 is a persisted kind: seeding the event store lets the
            // thread view open a 3-year-old note from cache instead of hoping
            // the scoreboard relays still hold it.
            await persistEvents(events)
        }
        return MemoryGroup(yearsAgo: window.yearsAgo, dateSec: window.since, events: events, resolvedVia: result.resolvedVia)
    }

    /// Fetch all three windows in parallel, cache-bypassing. Empty groups are
    /// normal. Sorted 1 → 2 → 3 years ago.
    func fetchMemories(pubkey: String, now: Date = Date()) async -> [MemoryGroup] {
        let windows = memoryWindows(now: now, calendar: calendar)
        let groups = await withTaskGroup(of: MemoryGroup.self, returning: [MemoryGroup].self) { group in
            for window in windows {
                group.addTask { @MainActor in await self.fetchWindow(pubkey: pubkey, window: window) }
            }
            var out: [MemoryGroup] = []
            for await g in group { out.append(g) }
            return out
        }
        return groups.sorted { $0.yearsAgo < $1.yearsAgo }
    }

    // MARK: cache-first

    /// Today's cached memories if present AND complete, otherwise fetch from
    /// relays and cache only a COMPLETE result (every window EOSE'd — see
    /// `shouldCacheMemories`). A cached partial reads as a miss so a transient
    /// single-window timeout self-heals on the next open instead of freezing
    /// that window empty for the rest of the day. The fetched groups are
    /// returned regardless of caching, so the user still sees what arrived.
    func getMemoriesCached(pubkey: String, now: Date = Date()) async -> [MemoryGroup] {
        let key = dateKey(now: now)
        if let cached = store.readCache(pubkey: pubkey, dateKey: key) {
            return cached
        }
        let flightKey = "\(pubkey)|\(key)"
        if let running = inFlight[flightKey] {
            return await running.value
        }
        let task = Task { @MainActor [store] in
            let groups = await self.fetchMemories(pubkey: pubkey, now: now)
            if shouldCacheMemories(groups) {
                store.writeCache(pubkey: pubkey, dateKey: key, groups: groups)
            }
            return groups
        }
        inFlight[flightKey] = task
        let groups = await task.value
        inFlight[flightKey] = nil
        return groups
    }

    /// Cache-bypassing refresh: always hits relays, then overwrites today's
    /// cache only when the result is authoritative. `refreshed == false` means
    /// the caller should keep showing its current (cached) data.
    func refreshMemories(pubkey: String, now: Date = Date()) async -> (groups: [MemoryGroup], refreshed: Bool) {
        let groups = await fetchMemories(pubkey: pubkey, now: now)
        guard shouldCacheMemories(groups) else { return (groups, false) }
        store.writeCache(pubkey: pubkey, dateKey: dateKey(now: now), groups: groups)
        return (groups, true)
    }

    // MARK: per-day dismissal (the teaser card)

    func isCardDismissed(pubkey: String, now: Date = Date()) -> Bool {
        store.isDismissed(pubkey: pubkey, dateKey: dateKey(now: now))
    }

    func dismissCard(pubkey: String, now: Date = Date()) {
        store.dismiss(pubkey: pubkey, dateKey: dateKey(now: now))
    }

    func undismissCard(pubkey: String, now: Date = Date()) {
        store.undismiss(pubkey: pubkey, dateKey: dateKey(now: now))
    }
}
