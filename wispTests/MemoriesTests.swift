import Foundation
import Testing
@testable import wisp

/// Memories ("On this day") — hermetic coverage of the four pure helpers
/// (windows, reply predicate, cache rule, date key), the per-account store,
/// and the repository's cache gating with an injected relay fetch. No socket
/// is opened: `MemoriesRepository` takes `fetch:` and `persistEvents:` and the
/// store takes a throwaway `UserDefaults` suite.
@MainActor
struct MemoriesTests {

    // MARK: - Helpers

    private func calendar(_ tz: String = "America/New_York") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, in cal: Calendar) -> Date {
        var p = DateComponents()
        p.year = y; p.month = m; p.day = d; p.hour = h; p.minute = min; p.second = 0
        return cal.date(from: p)!
    }

    private func ymd(_ sec: Int, in cal: Calendar) -> (Int, Int, Int, Int, Int, Int) {
        let p = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(sec)))
        return (p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
    }

    private func expectDaySpan(_ w: MemoryWindow, _ y: Int, _ m: Int, _ d: Int, in cal: Calendar,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        let s = ymd(w.since, in: cal)
        let u = ymd(w.until, in: cal)
        #expect(s.0 == y && s.1 == m && s.2 == d, "since day", sourceLocation: sourceLocation)
        #expect(s.3 == 0 && s.4 == 0 && s.5 == 0, "since is local midnight", sourceLocation: sourceLocation)
        #expect(u.0 == y && u.1 == m && u.2 == d, "until day", sourceLocation: sourceLocation)
        #expect(u.3 == 23 && u.4 == 59 && u.5 == 59, "until is 23:59:59 local", sourceLocation: sourceLocation)
        #expect(w.since < w.until, sourceLocation: sourceLocation)
    }

    nonisolated private static let eid = String(repeating: "e", count: 64)
    nonisolated private static let fid = String(repeating: "f", count: 64)
    nonisolated private static let pk = String(repeating: "a", count: 64)

    private func ev(tags: [[String]] = [], id: String = "i", pubkey: String = MemoriesTests.pk,
                    kind: Int = 1, createdAt: Int = 1, content: String = "x") -> NostrEvent {
        NostrEvent(id: id, pubkey: pubkey, kind: kind, createdAt: createdAt, tags: tags, content: content, sig: "")
    }

    private func group(_ resolved: MemoryResolved, withEvent: Bool = false, yearsAgo: Int = 1) -> MemoryGroup {
        MemoryGroup(yearsAgo: yearsAgo, dateSec: 0, events: withEvent ? [ev()] : [], resolvedVia: resolved)
    }

    private func freshDefaults() -> (UserDefaults, () -> Void) {
        let suite = "MemoriesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: - memoryWindows

    @Test func windows_returnThreeInOrderWithLocalDayBounds() {
        let cal = calendar()
        let w = memoryWindows(now: date(2026, 9, 19, 15, 30, in: cal), calendar: cal)
        #expect(w.map(\.yearsAgo) == [1, 2, 3])
        expectDaySpan(w[0], 2025, 9, 19, in: cal)
        expectDaySpan(w[1], 2024, 9, 19, in: cal)
        expectDaySpan(w[2], 2023, 9, 19, in: cal)
        for win in w { #expect(win.until - win.since == 86_399) }
    }

    @Test func windows_handleJan1_startOfYear() {
        let cal = calendar()
        let w = memoryWindows(now: date(2026, 1, 1, 0, 5, in: cal), calendar: cal)
        expectDaySpan(w[0], 2025, 1, 1, in: cal)
        expectDaySpan(w[1], 2024, 1, 1, in: cal)
        expectDaySpan(w[2], 2023, 1, 1, in: cal)
    }

    @Test func windows_handleDec31_endOfYear() {
        let cal = calendar()
        let w = memoryWindows(now: date(2025, 12, 31, 23, 55, in: cal), calendar: cal)
        expectDaySpan(w[0], 2024, 12, 31, in: cal)
        expectDaySpan(w[1], 2023, 12, 31, in: cal)
        expectDaySpan(w[2], 2022, 12, 31, in: cal)
    }

    @Test func windows_fallBackToFeb28_whenTargetYearHasNoFeb29() {
        // Feb 29 2024 (leap); 2023/2022/2021 are non-leap.
        let cal = calendar()
        let w = memoryWindows(now: date(2024, 2, 29, in: cal), calendar: cal)
        expectDaySpan(w[0], 2023, 2, 28, in: cal)
        expectDaySpan(w[1], 2022, 2, 28, in: cal)
        expectDaySpan(w[2], 2021, 2, 28, in: cal)
    }

    @Test func leapYear_followsTheGregorianRule() {
        #expect(isLeapYear(2024))
        #expect(isLeapYear(2000))
        #expect(!isLeapYear(1900))
        #expect(!isLeapYear(2023))
    }

    @Test func windows_keepFeb28AsFeb28_regardlessOfLeapStatus() {
        let cal = calendar()
        let w = memoryWindows(now: date(2025, 2, 28, in: cal), calendar: cal)
        expectDaySpan(w[0], 2024, 2, 28, in: cal) // 2024 leap, but source is the 28th
        expectDaySpan(w[1], 2023, 2, 28, in: cal)
        expectDaySpan(w[2], 2022, 2, 28, in: cal)
    }

    @Test func windows_useTheUsersTimeZone_notUTC() {
        // 03:00Z on Sept 19 is still Sept 18 in New York but already Sept 19 in Tokyo.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = date(2026, 9, 19, 3, 0, in: utc)
        let ny = calendar("America/New_York")
        let tokyo = calendar("Asia/Tokyo")
        expectDaySpan(memoryWindows(now: instant, calendar: ny)[0], 2025, 9, 18, in: ny)
        expectDaySpan(memoryWindows(now: instant, calendar: tokyo)[0], 2025, 9, 19, in: tokyo)
        // And the bounds are that zone's midnight, so the two 1-year windows differ.
        #expect(memoryWindows(now: instant, calendar: ny)[0] != memoryWindows(now: instant, calendar: tokyo)[0])
    }

    // MARK: - isMemoryReply

    @Test func reply_keepsTopLevelNotes() {
        #expect(!isMemoryReply(ev()))
        #expect(!isMemoryReply(ev(tags: [["p", Self.pk], ["t", "zapcooking"]])))
    }

    @Test func reply_dropsRootReplyAndUnmarked() {
        #expect(isMemoryReply(ev(tags: [["e", Self.eid, "", "root"]])))
        #expect(isMemoryReply(ev(tags: [["e", Self.eid, "", "reply"]])))
        #expect(isMemoryReply(ev(tags: [["e", Self.eid]])))                          // unmarked positional
        #expect(isMemoryReply(ev(tags: [["e", Self.eid, "wss://relay.example"]])))   // relay hint, no marker
        #expect(isMemoryReply(ev(tags: [["e", Self.eid, "", "fork"]])))              // unknown marker
    }

    @Test func reply_keepsMentionsAndQuotes() {
        #expect(!isMemoryReply(ev(tags: [["e", Self.eid, "", "mention"]])))
        #expect(!isMemoryReply(ev(tags: [["e", Self.eid, "wss://relay.example", "mention"]])))
        #expect(!isMemoryReply(ev(tags: [["q", Self.eid]])))
        #expect(!isMemoryReply(ev(tags: [["q", Self.eid], ["p", Self.pk]])))
    }

    /// The defect the shared helpers have: `"Mention"` must not count as a reply.
    @Test func reply_mentionMarkerIsCaseInsensitive() {
        #expect(!isMemoryReply(ev(tags: [["e", Self.eid, "", "Mention"]])))
        #expect(!isMemoryReply(ev(tags: [["e", Self.eid, "", "MENTION"]])))
        // Control: the shared helper is case-sensitive, which is why Memories has its own.
        #expect(ev(tags: [["e", Self.eid, "", "Mention"]]).hasThreadingETag)
    }

    @Test func reply_mixedMentionPlusReply_isReply() {
        #expect(isMemoryReply(ev(tags: [["e", Self.eid, "", "mention"], ["e", Self.fid, "", "reply"]])))
    }

    /// The other shared-helper defect: id-less / empty-id `e` tags are not threading.
    @Test func reply_ignoresETagsWithNoEventId() {
        #expect(!isMemoryReply(ev(tags: [["e"]])))       // bare, no id at all
        #expect(!isMemoryReply(ev(tags: [["e", ""]])))   // empty id
        #expect(!isMemoryReply(ev(tags: [["e", ""], ["q", Self.eid]])))
        // Control: `hasThreadingETag` counts a bare ["e"].
        #expect(ev(tags: [["e"]]).hasThreadingETag)
    }

    // MARK: - shouldCacheMemories

    @Test func cache_cachesOnlyWhenEveryWindowEosed() {
        // All windows EOSE'd (even empty ones) → complete → cacheable ("nothing that day").
        #expect(shouldCacheMemories([group(.eose), group(.eose, yearsAgo: 2), group(.eose, yearsAgo: 3)]))
        // Same, but the 1-year window has notes — still all-EOSE → cacheable.
        #expect(shouldCacheMemories([group(.eose, withEvent: true), group(.eose, yearsAgo: 2), group(.eose, yearsAgo: 3)]))
    }

    @Test func cache_doesNotCacheAnyTimeoutWindow() {
        // Any TIMEOUT window = incomplete → NOT cacheable, so a transient miss re-fetches.
        #expect(!shouldCacheMemories([group(.timeout), group(.timeout, yearsAgo: 2), group(.timeout, yearsAgo: 3)]))
        // The frozen-3-year case: 1-year had notes + EOSE, 3-year timed out → not cached.
        #expect(!shouldCacheMemories([group(.eose, withEvent: true), group(.eose, yearsAgo: 2), group(.timeout, yearsAgo: 3)]))
        // A TIMEOUT window with events is still incomplete → not durably cached.
        #expect(!shouldCacheMemories([group(.timeout, withEvent: true), group(.eose, yearsAgo: 2)]))
    }

    @Test func cache_doesNotCacheEmptyGroupList() {
        #expect(!shouldCacheMemories([]))
    }

    // MARK: - memoriesLocalDateKey

    @Test func dateKey_isZeroPaddedLocalYMD() {
        let cal = calendar()
        #expect(memoriesLocalDateKey(now: date(2026, 1, 5, in: cal), calendar: cal) == "2026-01-05")
        #expect(memoriesLocalDateKey(now: date(2025, 12, 31, 23, 59, in: cal), calendar: cal) == "2025-12-31")
    }

    @Test func dateKey_followsTheUsersTimeZone() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = date(2026, 9, 19, 3, 0, in: utc)
        #expect(memoriesLocalDateKey(now: instant, calendar: calendar("America/New_York")) == "2026-09-18")
        #expect(memoriesLocalDateKey(now: instant, calendar: calendar("Asia/Tokyo")) == "2026-09-19")
    }

    // MARK: - MemoriesStore

    @Test func store_keysArePerPubkeyAndVersioned() {
        #expect(MemoriesStore.cacheVersion == "v1")
        #expect(MemoriesStore.cacheKey("abc") == "memories_v1_abc")
        #expect(MemoriesStore.dismissKey("abc") == "memories_dismissed_abc")
    }

    @Test func store_roundTripsACompleteResult_forTodayOnly() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let store = MemoriesStore(defaults: defaults)
        let note = ev(tags: [["t", "foodstr"]], id: "n1", createdAt: 1_700_000_000, content: "pancakes 🥞 \"quoted\"")
        let groups = [
            MemoryGroup(yearsAgo: 1, dateSec: 10, events: [note], resolvedVia: .eose),
            MemoryGroup(yearsAgo: 2, dateSec: 20, events: [], resolvedVia: .eose),
            MemoryGroup(yearsAgo: 3, dateSec: 30, events: [], resolvedVia: .eose),
        ]
        store.writeCache(pubkey: "pk", dateKey: "2026-09-19", groups: groups)

        let back = store.readCache(pubkey: "pk", dateKey: "2026-09-19")
        #expect(back?.count == 3)
        #expect(back?[0].events.map(\.id) == ["n1"])
        #expect(back?[0].events.first?.content == note.content)
        #expect(back?[0].events.first?.tags == note.tags)
        #expect(back?[0].dateSec == 10)
        #expect(back?[2].resolvedVia == .eose)

        // A different day is a miss (the entry is today's only) …
        #expect(store.readCache(pubkey: "pk", dateKey: "2026-09-20") == nil)
        // … and so is a different pubkey.
        #expect(store.readCache(pubkey: "other", dateKey: "2026-09-19") == nil)
        // Writing tomorrow prunes today by overwrite: one key per pubkey.
        store.writeCache(pubkey: "pk", dateKey: "2026-09-20", groups: groups)
        #expect(store.readCache(pubkey: "pk", dateKey: "2026-09-19") == nil)
        #expect(store.readCache(pubkey: "pk", dateKey: "2026-09-20") != nil)
    }

    /// A stored PARTIAL reads as a miss so it re-fetches and self-heals.
    @Test func store_treatsAStoredPartialAsAMiss() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let store = MemoriesStore(defaults: defaults)
        store.writeCache(pubkey: "pk", dateKey: "d", groups: [group(.eose, withEvent: true), group(.eose, yearsAgo: 2), group(.timeout, yearsAgo: 3)])
        #expect(store.readCache(pubkey: "pk", dateKey: "d") == nil)
        store.writeCache(pubkey: "pk", dateKey: "d", groups: [])
        #expect(store.readCache(pubkey: "pk", dateKey: "d") == nil)
    }

    @Test func store_dismissalIsPerDayAndUndoable() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let store = MemoriesStore(defaults: defaults)
        #expect(!store.isDismissed(pubkey: "pk", dateKey: "2026-09-19"))
        store.dismiss(pubkey: "pk", dateKey: "2026-09-19")
        #expect(store.isDismissed(pubkey: "pk", dateKey: "2026-09-19"))
        #expect(!store.isDismissed(pubkey: "pk", dateKey: "2026-09-20"))   // tomorrow shows again
        #expect(!store.isDismissed(pubkey: "other", dateKey: "2026-09-19")) // other account unaffected
        store.undismiss(pubkey: "pk", dateKey: "2026-09-20")                // wrong day: no-op
        #expect(store.isDismissed(pubkey: "pk", dateKey: "2026-09-19"))
        store.undismiss(pubkey: "pk", dateKey: "2026-09-19")
        #expect(!store.isDismissed(pubkey: "pk", dateKey: "2026-09-19"))
    }

    // MARK: - MemoriesRepository (injected fetch)

    private final class FetchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [MemoriesFetchRequest] = []
        func record(_ r: MemoriesFetchRequest) { lock.lock(); _requests.append(r); lock.unlock() }
        var requests: [MemoriesFetchRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        var count: Int { requests.count }
    }

    private func makeRepo(
        defaults: UserDefaults,
        log: FetchLog,
        delayMs: Int = 0,
        respond: @escaping @Sendable (MemoriesFetchRequest) -> MemoriesFetchResult
    ) -> MemoriesRepository {
        MemoriesRepository(
            store: MemoriesStore(defaults: defaults),
            fetch: { request in
                log.record(request)
                if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
                return respond(request)
            },
            relays: ["wss://a.example", "wss://b.example"],
            calendar: calendar(),
            persistEvents: { _ in }
        )
    }

    @Test func repo_completeResultIsCached_soRelaysAreQueriedOncePerDay() async {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let log = FetchLog()
        let pk = Self.pk
        let repo = makeRepo(defaults: defaults, log: log) { req in
            let note = NostrEvent(id: "n\(req.window.yearsAgo)", pubkey: pk, kind: 1, createdAt: req.window.since + 60, tags: [], content: "hi", sig: "")
            return MemoriesFetchResult(events: req.window.yearsAgo == 1 ? [note] : [], resolvedVia: .eose)
        }
        let now = date(2026, 9, 19, in: calendar())
        let first = await repo.getMemoriesCached(pubkey: pk, now: now)
        #expect(first.map(\.yearsAgo) == [1, 2, 3])
        #expect(first[0].events.map(\.id) == ["n1"])
        #expect(log.count == 3)

        let second = await repo.getMemoriesCached(pubkey: pk, now: now)
        #expect(second[0].events.map(\.id) == ["n1"])
        #expect(log.count == 3, "cache hit: no second relay round")
    }

    /// THE rule: a partial result (3-year window timed out) is shown but NOT
    /// cached, so the next open re-fetches and can self-heal.
    @Test func repo_partialResultIsReturnedButNotCached() async {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let log = FetchLog()
        let pk = Self.pk
        let repo = makeRepo(defaults: defaults, log: log) { req in
            let note = NostrEvent(id: "n\(req.window.yearsAgo)", pubkey: pk, kind: 1, createdAt: req.window.since + 60, tags: [], content: "hi", sig: "")
            return req.window.yearsAgo == 3
                ? MemoriesFetchResult(events: [], resolvedVia: .timeout)
                : MemoriesFetchResult(events: [note], resolvedVia: .eose)
        }
        let now = date(2026, 9, 19, in: calendar())
        let first = await repo.getMemoriesCached(pubkey: pk, now: now)
        #expect(first[0].events.count == 1 && first[1].events.count == 1 && first[2].events.isEmpty)
        #expect(first[2].resolvedVia == .timeout)
        #expect(MemoriesStore(defaults: defaults).readCache(pubkey: pk, dateKey: "2026-09-19") == nil)

        _ = await repo.getMemoriesCached(pubkey: pk, now: now)
        #expect(log.count == 6, "partial was not cached, so the next open re-fetched all windows")
    }

    /// An all-EOSE result with ZERO notes is a real answer and IS cached.
    @Test func repo_emptyButCompleteResultIsCached() async {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let log = FetchLog()
        let repo = makeRepo(defaults: defaults, log: log) { _ in MemoriesFetchResult(events: [], resolvedVia: .eose) }
        let now = date(2026, 9, 19, in: calendar())
        _ = await repo.getMemoriesCached(pubkey: Self.pk, now: now)
        _ = await repo.getMemoriesCached(pubkey: Self.pk, now: now)
        #expect(log.count == 3)
        #expect(MemoriesStore(defaults: defaults).readCache(pubkey: Self.pk, dateKey: "2026-09-19")?.count == 3)
    }

    @Test func repo_refreshKeepsCacheWhenNotAuthoritative() async {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let log = FetchLog()
        let pk = Self.pk
        let flaky = FlakySwitch()
        let repo = makeRepo(defaults: defaults, log: log) { req in
            if flaky.timeoutNow {
                return MemoriesFetchResult(events: [], resolvedVia: .timeout)
            }
            let note = NostrEvent(id: "n\(req.window.yearsAgo)", pubkey: pk, kind: 1, createdAt: req.window.since + 5, tags: [], content: "hi", sig: "")
            return MemoriesFetchResult(events: [note], resolvedVia: .eose)
        }
        let now = date(2026, 9, 19, in: calendar())
        _ = await repo.getMemoriesCached(pubkey: pk, now: now) // primes a complete cache

        flaky.timeoutNow = true
        let (fresh, refreshed) = await repo.refreshMemories(pubkey: pk, now: now)
        #expect(!refreshed)
        #expect(fresh.allSatisfy { $0.resolvedVia == .timeout })
        // Cache untouched: a cache-first read still serves the complete result without a fetch.
        let before = log.count
        let cached = await repo.getMemoriesCached(pubkey: pk, now: now)
        #expect(cached.flatMap(\.events).count == 3)
        #expect(log.count == before)

        flaky.timeoutNow = false
        let (_, refreshed2) = await repo.refreshMemories(pubkey: pk, now: now)
        #expect(refreshed2)
    }

    private final class FlakySwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var _timeout = false
        var timeoutNow: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _timeout }
            set { lock.lock(); _timeout = newValue; lock.unlock() }
        }
    }

    @Test func repo_filtersRepliesEmptiesForeignAndOutOfWindow_andSortsOldestFirst() async {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let log = FetchLog()
        let pk = Self.pk
        let repo = makeRepo(defaults: defaults, log: log) { req in
            guard req.window.yearsAgo == 1 else { return MemoriesFetchResult(events: [], resolvedVia: .eose) }
            let s = req.window.since
            return MemoriesFetchResult(events: [
                NostrEvent(id: "late", pubkey: pk, kind: 1, createdAt: s + 3000, tags: [], content: "later", sig: ""),
                NostrEvent(id: "reply", pubkey: pk, kind: 1, createdAt: s + 10, tags: [["e", Self.eid, "", "reply"]], content: "r", sig: ""),
                NostrEvent(id: "empty", pubkey: pk, kind: 1, createdAt: s + 20, tags: [], content: "  \n ", sig: ""),
                NostrEvent(id: "foreign", pubkey: Self.fid, kind: 1, createdAt: s + 30, tags: [], content: "not mine", sig: ""),
                NostrEvent(id: "reaction", pubkey: pk, kind: 7, createdAt: s + 40, tags: [], content: "+", sig: ""),
                NostrEvent(id: "outside", pubkey: pk, kind: 1, createdAt: req.window.until + 1, tags: [], content: "tomorrow", sig: ""),
                NostrEvent(id: "quote", pubkey: pk, kind: 1, createdAt: s + 100, tags: [["e", Self.eid, "", "Mention"]], content: "q", sig: ""),
                NostrEvent(id: "early", pubkey: pk, kind: 1, createdAt: s + 1, tags: [], content: "first", sig: ""),
            ], resolvedVia: .eose)
        }
        let groups = await repo.getMemoriesCached(pubkey: pk, now: date(2026, 9, 19, in: calendar()))
        #expect(groups[0].events.map(\.id) == ["early", "quote", "late"])
    }

    /// Card and screen mounting together share one relay round.
    @Test func repo_coalescesConcurrentCacheFirstLoads() async {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let log = FetchLog()
        let repo = makeRepo(defaults: defaults, log: log, delayMs: 80) { _ in
            MemoriesFetchResult(events: [], resolvedVia: .timeout) // never cached, so coalescing is what dedupes
        }
        let now = date(2026, 9, 19, in: calendar())
        async let a = repo.getMemoriesCached(pubkey: Self.pk, now: now)
        async let b = repo.getMemoriesCached(pubkey: Self.pk, now: now)
        let (ga, gb) = await (a, b)
        #expect(ga.count == 3 && gb.count == 3)
        #expect(log.count == 3, "two concurrent opens, one fetch per window")
    }

    @Test func repo_subIdsAreProcessWideUniqueAndNameTheWindow() async {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let log = FetchLog()
        let repo = makeRepo(defaults: defaults, log: log) { _ in MemoriesFetchResult(events: [], resolvedVia: .timeout) }
        let repo2 = makeRepo(defaults: defaults, log: log) { _ in MemoriesFetchResult(events: [], resolvedVia: .timeout) }
        let now = date(2026, 9, 19, in: calendar())
        _ = await repo.fetchMemories(pubkey: Self.pk, now: now)
        _ = await repo2.fetchMemories(pubkey: Self.pk, now: now)
        let ids = log.requests.map(\.subId)
        #expect(Set(ids).count == 6, "no subId reused across instances (§7.2)")
        for r in log.requests {
            #expect(r.subId.hasPrefix("memories-\(r.window.yearsAgo)-"))
            #expect(r.relays == ["wss://a.example", "wss://b.example"])
        }
    }

    @Test func subSeq_isMonotonic() {
        let seq = MemoriesSubSeq()
        let a = seq.next(), b = seq.next(), c = seq.next()
        #expect(a < b && b < c)
        #expect(seq.nextSubId(yearsAgo: 3).hasPrefix("memories-3-"))
    }

    // MARK: - Relay constants

    @Test func relay_budgetsGraduateByDepth() {
        #expect(MemoriesRelay.eoseTimeout(yearsAgo: 1) == 10)
        #expect(MemoriesRelay.eoseTimeout(yearsAgo: 2) == 12)
        #expect(MemoriesRelay.eoseTimeout(yearsAgo: 3) == 14)
        #expect(MemoriesRelay.connectTimeout == 8)
        #expect(MemoriesRelay.eoseGrace == 4)
        #expect(MemoriesRelay.windowLimit == 50)
    }

    @Test func relay_unionIsDefaultsPlusArchive_dedupedAndPrimalIsNotAnArchive() {
        let union = MemoriesRelay.relays
        #expect(Set(union).count == union.count)
        for r in RelayDefaults.defaults { #expect(union.contains(r)) }
        #expect(union.contains("wss://nostr.wine"))
        #expect(!MemoriesRelay.archiveRelays.contains("wss://relay.primal.net"))
        #expect(!MemoriesRelay.archiveRelays.contains("wss://relay.damus.io"))
    }

    @Test func relay_filterIsAuthorScopedKind1WithinTheWindow() {
        let w = MemoryWindow(yearsAgo: 2, since: 100, until: 200)
        let f = MemoriesRelay.filter(pubkey: Self.pk, window: w)
        #expect(f.kinds == [1])
        #expect(f.authors == [Self.pk])
        #expect(f.since == 100 && f.until == 200)
        #expect(f.limit == 50)
    }

    // MARK: - Presentation helpers

    @Test func card_summaryCountsNotesAndListsYears() {
        let cal = calendar()
        let d2025 = Int(date(2025, 9, 19, 0, in: cal).timeIntervalSince1970)
        let d2023 = Int(date(2023, 9, 19, 0, in: cal).timeIntervalSince1970)
        let one = [MemoryGroup(yearsAgo: 1, dateSec: d2025, events: [ev()], resolvedVia: .eose)]
        #expect(MemoriesCard.summary(for: one, calendar: cal) == "1 note · 2025")
        let two = one + [MemoryGroup(yearsAgo: 3, dateSec: d2023, events: [ev(id: "a"), ev(id: "b")], resolvedVia: .eose)]
        #expect(MemoriesCard.summary(for: two, calendar: cal) == "3 notes · 2025, 2023")
    }

    @Test func view_yearLabelPluralises() {
        #expect(MemoriesView.yearLabel(1) == "1 year ago")
        #expect(MemoriesView.yearLabel(2) == "2 years ago")
    }

    @Test func viewModel_refreshNoticeOnlyWhenNotAuthoritative() async {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let log = FetchLog()
        let repo = makeRepo(defaults: defaults, log: log) { _ in MemoriesFetchResult(events: [], resolvedVia: .timeout) }
        let vm = MemoriesViewModel(pubkey: Self.pk, repo: repo)
        await vm.load()
        #expect(vm.loaded)
        #expect(vm.allEmpty)
        await vm.refresh()
        #expect(vm.refreshNotice == MemoriesViewModel.refreshFailedNotice)
    }
}
