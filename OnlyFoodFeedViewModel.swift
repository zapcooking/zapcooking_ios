import Foundation
import Observation

/// One-shot OnlyFood relay query. Injected so hermetic tests can assert
/// §7.4 (a second `start()` does not re-query) without opening a socket.
struct OnlyFoodQueryRequest {
    var relays: [String]
    var filter: NostrFilter
    var subId: String
}

struct OnlyFoodQueryResult: Sendable {
    var events: [NostrEvent]
    var connected: Bool
    var anySent: Bool
    var eoseFired: Bool

    static let empty = OnlyFoodQueryResult(events: [], connected: false, anySent: false, eoseFired: false)
}

/// OnlyFood 🍳 — a kind-1 social food feed over the expanded ``FoodHashtags``
/// set (Concern 3.3), rendered inside the unified feed tab. Filtering is
/// mute-only in v1 (§7.3) — this type never calls `SpamScorer`.
///
/// **Queried once per session — DON'T re-query on re-entry (§7.4).** Search
/// relays rate-limit repeated queries per connection: the first identical
/// query returns ~99 events, a repeat ~12s later returns 0. The feed is
/// queried **once** and cached; a second ``start()`` (tab re-appear, feed-kind
/// switch away and back) is a no-op with **no relay query**. A load that
/// legitimately returns 0 still gets `loaded = true`. Pull-to-refresh is the
/// only re-query path.
///
/// **§7.2 / §7.5:** subscription IDs come from a process-wide atomic
/// sequence; teardown CLOSEs only the subIds actually opened, on the relays
/// they were opened on. Load / refresh / pagination serialize through one
/// ``submit`` that cancels the previous job before the next REQ.
@Observable
@MainActor
final class OnlyFoodFeedViewModel {

    enum Load: Equatable {
        case initial
        case page
        case refresh
    }

    /// Prefetch margin (in rows) for scroll-end pagination. Matches Android
    /// `PAGE_PREFETCH_DISTANCE`.
    static let loadMorePrefetch = 6

    /// Hashtag REQ target. Android's OnlyFood hashtag path is also
    /// `SearchViewModel.DEFAULT_SEARCH_RELAY` alone (`wss://search.nostrarchives.com`)
    /// for both initial and paging. Android's extra `nos.lol` / `primal` /
    /// `nostr.net` set is the keyword-only firehose (`discoverContentOnlyFood`),
    /// a separate protocol file skipped in 3.3. Single-relay here is parity,
    /// not a gap versus that hashtag path.
    static let searchRelay = SearchViewModel.defaultSearchRelay
    static let maxRetainedEvents = 3000
    static let queryTimeout: TimeInterval = 10

    var notes: [NostrEvent] = []
    var profiles: [String: ProfileData] = [:]
    var isLoading = false
    var isPaging = false
    var isRefreshing = false
    var wotDropped = 0
    /// True when the last initial/refresh query finished
    /// without a genuine EOSE (timeout, dropped send, connect miss) and nothing
    /// is on screen. Distinct from ``isEmpty`` (EOSE arrived, zero accepted).
    var loadFailed = false

    /// Relay queries issued this session. Tests assert the §7.4 latch against
    /// this rather than sockets. Production increments it too, which is how
    /// the live gate reports "second Global issued no new REQ."
    private(set) var queryCount = 0

    let pubkey: String

    @ObservationIgnored private var started = false
    @ObservationIgnored private let state = ModeState()
    @ObservationIgnored private(set) var inFlight: Task<Void, Never>?
    @ObservationIgnored private var submitGeneration = 0
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var sweepSourceId: UUID?
    @ObservationIgnored private var hideObserver: NSObjectProtocol?
    @ObservationIgnored private var publishObserver: NSObjectProtocol?

    @ObservationIgnored private let filter: OnlyFoodFilter
    @ObservationIgnored private let query: (OnlyFoodQueryRequest) async -> OnlyFoodQueryResult
    @ObservationIgnored private let seedCache: () async -> [NostrEvent]
    @ObservationIgnored private let persist: ([NostrEvent]) -> Void
    @ObservationIgnored private let profileRepo: ProfileRepository

    /// Process-wide subId sequence — unique across all VM instances (§7.2).
    /// An instance-scoped counter restarting at 0 per nav entry is the bug
    /// this exists to not re-earn.
    private static let subSeq = SubSeq()

    init(
        pubkey: String,
        filter: OnlyFoodFilter? = nil,
        query: ((OnlyFoodQueryRequest) async -> OnlyFoodQueryResult)? = nil,
        seedCache: (() async -> [NostrEvent])? = nil,
        persist: (([NostrEvent]) -> Void)? = nil,
        profileRepo: ProfileRepository? = nil
    ) {
        self.pubkey = pubkey
        self.filter = filter ?? OnlyFoodFilter.live()
        self.query = query ?? OnlyFoodRelay.query
        self.seedCache = seedCache ?? {
            let cached = await EventStore.shared.seedCache()
            return cached.filter { $0.kind == 1 && FoodHashtags.hasFoodTag($0) }
        }
        self.persist = persist ?? { events in
            guard !events.isEmpty else { return }
            Task { await EventPersistQueue.shared.enqueue(events) }
        }
        self.profileRepo = profileRepo ?? ProfileRepository.shared
    }

    deinit {
        profileUpdatesTask?.cancel()
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
        }
        if let publishObserver {
            NotificationCenter.default.removeObserver(publishObserver)
        }
        if let id = sweepSourceId {
            Task { @MainActor in MissingProfileWatcher.shared.unregisterSource(id) }
        }
    }

    /// True once the feed has completed a query, whatever the event count.
    /// A legitimately empty feed must not look like "never loaded."
    var hasLoaded: Bool { state.loaded }

    /// Still fetching the first window, and nothing is on screen yet.
    var isAwaitingFirstPaint: Bool { notes.isEmpty && !hasLoaded && !loadFailed }

    /// A completed load that found nothing. Distinct from a relay miss
    /// (``isLoadFailed``).
    var isEmpty: Bool { notes.isEmpty && hasLoaded }

    /// The search relay never answered. Distinct from genuine empty (EOSE,
    /// zero accepted) so the UI can say "couldn't reach" instead of
    /// "no food posts yet."
    var isLoadFailed: Bool { notes.isEmpty && loadFailed && !hasLoaded }

    /// One-shot. The feed tab calls this on appear and on every feed-kind
    /// change; a second call is a no-op so an identical filter never re-hits
    /// the same connection (§7.4).
    func start() {
        guard !started else { return }
        started = true
        ensureProfileUpdatesSubscription()
        observeContentHidden()
        observeOwnPublishes()
        if !state.loaded {
            submit(load: .initial, since: nil, until: nil)
        }
    }

    func startAndWait() async {
        start()
        await inFlight?.value
    }

    /// The ONLY path that re-queries a loaded feed. Merges newest into cache.
    func refresh() {
        state.endReached = false
        submit(load: .refresh, since: nil, until: nil)
    }

    func refreshAndWait() async {
        refresh()
        await inFlight?.value
    }

    func loadMore() {
        if isLoading || isPaging || isRefreshing || state.endReached { return }
        if state.seen.count >= Self.maxRetainedEvents {
            state.endReached = true
            return
        }
        guard let oldest = oldestPageableCreatedAt(state.seen.values) else { return }
        let bounds = pageBoundsBehind(oldest)
        submit(load: .page, since: bounds.since, until: bounds.until)
    }

    func loadMoreIfNeeded(currentIndex: Int, total: Int) {
        guard total > 0, currentIndex >= total - Self.loadMorePrefetch else { return }
        loadMore()
    }

    // MARK: - Submit

    /// Single serialized entry point. Cancels the previous job before the
    /// next REQ (§7.5).
    private func submit(load: Load, since: Int?, until: Int?) {
        inFlight?.cancel()
        submitGeneration += 1
        let generation = submitGeneration
        if load == .initial || load == .refresh { loadFailed = false }
        switch load {
        case .initial: isLoading = true
        case .page: isPaging = true
        case .refresh: isRefreshing = true
        }
        let state = self.state
        inFlight = Task { @MainActor in
            if load == .initial || load == .refresh { state.unsettle() }
            if load == .refresh { self.wotDropped = 0 }
            if load == .initial {
                await self.paintFromCache(state)
            }

            let filter = Self.baseFilter(since: since, until: until)
            let subId = Self.nextSubId()
            let result = await self.issue(relays: [Self.searchRelay], filter: filter, subId: subId)
            let accepted = self.ingestBatch(result.events, into: state)

            guard !Task.isCancelled, generation == self.submitGeneration else { return }

            let latched = shouldLatchLoaded(
                connected: result.connected, anySent: result.anySent, eoseFired: result.eoseFired
            )
            if latched {
                state.loaded = true
                if load == .page, pageEndReached(accepted.count) { state.endReached = true }
            }
            if result.eoseFired, load == .initial || load == .refresh {
                _ = mergeFeedOrder(
                    ordered: &state.ordered,
                    placedIds: &state.placedIds,
                    seen: state.seen.values,
                    settled: false
                )
                state.settled = true
            }
            self.emitNotes()
            if latched {
                self.loadFailed = false
            } else if (load == .initial || load == .refresh), self.notes.isEmpty {
                self.loadFailed = true
            }
            self.clearIndicators()
            self.persist(accepted)
            self.observeProfiles(in: Array(state.seen.values))
        }
    }

    private func paintFromCache(_ state: ModeState) async {
        guard state.seen.isEmpty else { return }
        let cached = await seedCache()
        var added = false
        for event in cached where event.kind == 1 {
            if ingestEvent(
                event,
                seen: &state.seen,
                accept: { self.accept($0) },
                onAccepted: { _ in },
                signalFlush: {}
            ) {
                added = true
            }
        }
        if added {
            emitNotes()
            observeProfiles(in: Array(state.seen.values))
        }
    }

    private func issue(relays: [String], filter: NostrFilter, subId: String) async -> OnlyFoodQueryResult {
        queryCount += 1
        return await query(OnlyFoodQueryRequest(relays: relays, filter: filter, subId: subId))
    }

    private static func baseFilter(since: Int?, until: Int?) -> NostrFilter {
        NostrFilter(
            kinds: [1],
            tTags: FoodHashtags.all,
            limit: 100,
            since: since,
            until: until
        )
    }

    // MARK: - Ingest / emit

    private func ingestBatch(_ events: [NostrEvent], into state: ModeState) -> [NostrEvent] {
        var newly: [NostrEvent] = []
        for event in events where event.kind == 1 {
            let inserted = ingestEvent(
                event,
                seen: &state.seen,
                accept: { self.accept($0) },
                onAccepted: { _ in },
                signalFlush: {}
            )
            if inserted { newly.append(event) }
        }
        return newly
    }

    private func accept(_ event: NostrEvent) -> Bool {
        guard FoodHashtags.hasFoodTag(event) else { return false }
        switch filter.decideKind1(event) {
        case .accept:
            return true
        case .wotFiltered:
            wotDropped += 1
            return false
        default:
            return false
        }
    }

    private func emitNotes() {
        notes = mergeFeedOrder(
            ordered: &state.ordered,
            placedIds: &state.placedIds,
            seen: state.seen.values,
            settled: state.settled
        )
    }

    private func clearIndicators() {
        isLoading = false
        isPaging = false
        isRefreshing = false
    }

    private func observeProfiles(in events: [NostrEvent]) {
        let pubkeys = Set(events.map(\.pubkey))
        for pk in pubkeys where profiles[pk] == nil {
            if let cached = profileRepo.get(pk) { profiles[pk] = cached }
        }
        MissingProfileWatcher.shared.observe(events)
    }

    private func ensureProfileUpdatesSubscription() {
        if profileUpdatesTask == nil {
            profileUpdatesTask = Task { @MainActor [weak self] in
                for await pk in MissingProfileWatcher.shared.updates {
                    guard let self else { return }
                    if let p = self.profileRepo.get(pk) { self.profiles[pk] = p }
                }
            }
        }
        if sweepSourceId == nil {
            sweepSourceId = MissingProfileWatcher.shared.registerSource { [weak self] in
                self?.notes ?? []
            }
        }
    }

    private func observeContentHidden() {
        guard hideObserver == nil else { return }
        hideObserver = NotificationCenter.default.addObserver(
            forName: .contentHidden, object: nil, queue: .main
        ) { [weak self] note in
            let eventIds = Set(note.userInfo?[ContentHideKey.eventIds] as? [String] ?? [])
            let pubkeys = Set(note.userInfo?[ContentHideKey.pubkeys] as? [String] ?? [])
            Task { @MainActor [weak self] in
                self?.dropHidden(eventIds: eventIds, pubkeys: pubkeys)
            }
        }
    }

    private func dropHidden(eventIds: Set<String>, pubkeys: Set<String>) {
        guard !eventIds.isEmpty || !pubkeys.isEmpty else { return }
        state.seen = state.seen.filter {
            !eventIds.contains($0.key) && !pubkeys.contains($0.value.pubkey)
        }
        state.ordered.removeAll {
            eventIds.contains($0.id) || pubkeys.contains($0.pubkey)
        }
        state.placedIds.subtract(eventIds)
        emitNotes()
    }

    // MARK: - Own publishes (Concern C-H)

    /// `.nostrEventPublished` → ``insertOwnPublished(_:)``. Same shape as the
    /// `contentHidden` observer; `FeedViewModel.observeOwnPublishes` is the
    /// home-tab precedent.
    private func observeOwnPublishes() {
        guard publishObserver == nil else { return }
        publishObserver = NotificationCenter.default.addObserver(
            forName: .nostrEventPublished, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?["event"] as? NostrEvent else { return }
            MainActor.assumeIsolated {
                _ = self?.insertOwnPublished(event)
            }
        }
    }

    /// Optimistic insert of the user's own freshly published kind-1 into the
    /// cache — **no relay query** (§7.4). The note goes through the exact
    /// `accept` the relay ingest uses: it must carry a ``FoodHashtags`` `t`
    /// tag and pass the mute / structural filter. A note that would not come
    /// back from the relay is not painted either — that is what makes the
    /// "post, then see it" gate honest rather than cosmetic. Placed at the
    /// top: `mergeFeedOrder` only appends unplaced ids on a settled feed, and
    /// re-sorts by `createdAt` on an unsettled one, so the newest note lands
    /// first either way.
    ///
    /// Returns true iff the note was inserted (tests).
    @discardableResult
    func insertOwnPublished(_ event: NostrEvent) -> Bool {
        guard event.pubkey == pubkey, event.kind == 1 else { return false }
        guard state.seen[event.id] == nil else { return false }
        guard accept(event) else { return false }
        state.seen[event.id] = event
        if state.settled {
            state.ordered.insert(event, at: 0)
            state.placedIds.insert(event.id)
        }
        emitNotes()
        observeProfiles(in: [event])
        return true
    }

    static func nextSubId() -> String {
        "onlyfood-\(subSeq.next())"
    }
}

// MARK: - Feed cache

/// Source of truth + display cache for the feed. Not thread-safe; the VM
/// is `@MainActor` so every mutation is on one thread.
nonisolated final class ModeState: @unchecked Sendable {
    var seen: [String: NostrEvent] = [:]
    var ordered: [NostrEvent] = []
    var placedIds: Set<String> = []
    var loaded = false
    var endReached = false
    var settled = false

    func unsettle() {
        settled = false
        ordered.removeAll()
        placedIds.removeAll()
    }
}

// MARK: - Process-wide subId sequence (§7.2)

private final class SubSeq: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 {
        lock.lock()
        value += 1
        let n = value
        lock.unlock()
        return n
    }
}

// MARK: - Production relay client (§7.5)

enum OnlyFoodRelay {
    /// One REQ, CLOSE only that subId, on the relays it was opened on.
    /// Cancellation breaks the wait and still CLOSEs.
    static func query(_ request: OnlyFoodQueryRequest) async -> OnlyFoodQueryResult {
        let urls = request.relays.compactMap(RelayPool.wsURL)
        guard !urls.isEmpty else { return .empty }

        let collector = OnlyFoodQueryCollector()
        let reqFrame = "[\"REQ\",\"\(request.subId)\",\(request.filter.toJSON())]"
        let relayReqs = urls.map { (url: $0, req: reqFrame) }
        let sink = RelaySink(
            onEvent: { event, _ in collector.add(event) },
            onEose: { _ in collector.markEose() }
        )
        // `register` can refuse every relay under the connection cap — do not
        // pretend the socket is up. A queued REQ (`addSub`) is "sent" for the
        // latch; a refused register is a connect miss and must not wait 10s
        // for an EOSE that cannot arrive.
        let registered = await RelayConnectionPool.shared.register(
            subId: request.subId, relays: relayReqs, sink: sink
        )
        let connected = registered > 0
        let anySent = registered > 0
        if !connected {
            await RelayConnectionPool.shared.deregister(subId: request.subId)
            return OnlyFoodQueryResult(events: [], connected: false, anySent: false, eoseFired: false)
        }

        let deadline = Date().addingTimeInterval(OnlyFoodFeedViewModel.queryTimeout)
        while Date() < deadline, !Task.isCancelled {
            if collector.eoseCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let eoseFired = collector.eoseCount > 0
        if eoseFired, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
        }

        await RelayConnectionPool.shared.deregister(subId: request.subId)
        return OnlyFoodQueryResult(
            events: collector.events,
            connected: connected,
            anySent: anySent,
            eoseFired: eoseFired
        )
    }
}

private final class OnlyFoodQueryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [NostrEvent] = []
    private var seen = Set<String>()
    private var _eose = 0

    func add(_ event: NostrEvent) {
        lock.lock(); defer { lock.unlock() }
        if seen.insert(event.id).inserted { _events.append(event) }
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

// MARK: - Pure helpers (Android top-level functions; unit-tested)

/// Ingest one event into `seen`. Dedup → accept → insert. Returns true iff
/// newly accepted.
@discardableResult
func ingestEvent(
    _ event: NostrEvent,
    seen: inout [String: NostrEvent],
    accept: (NostrEvent) -> Bool,
    onAccepted: (NostrEvent) -> Void,
    signalFlush: () -> Void
) -> Bool {
    if seen[event.id] != nil { return false }
    if !accept(event) { return false }
    seen[event.id] = event
    onAccepted(event)
    signalFlush()
    return true
}

/// Compute the OnlyFood display order.
///
/// - `settled == false`: rebuild `ordered`/`placedIds` from `seen` by a full
///   descending-`createdAt` sort.
/// - `settled == true`: append only unseen ids, sorted within the batch, to
///   the tail. Rows already on screen keep their position.
@discardableResult
nonisolated func mergeFeedOrder(
    ordered: inout [NostrEvent],
    placedIds: inout Set<String>,
    seen: some Collection<NostrEvent>,
    settled: Bool
) -> [NostrEvent] {
    if !settled {
        ordered.removeAll()
        placedIds.removeAll()
        for event in seen.sorted(by: { $0.createdAt > $1.createdAt }) {
            ordered.append(event)
            placedIds.insert(event.id)
        }
    } else {
        let fresh = seen.filter { !placedIds.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
        for event in fresh {
            ordered.append(event)
            placedIds.insert(event.id)
        }
    }
    return ordered
}

/// The feed is "loaded" (so a second `start()` won't re-query) ONLY when the
/// socket was connected, at least one REQ was actually sent, AND a genuine
/// EOSE arrived. EOSE-with-zero-events still latches; a timeout does not.
nonisolated func shouldLatchLoaded(connected: Bool, anySent: Bool, eoseFired: Bool) -> Bool {
    connected && anySent && eoseFired
}

struct PageBounds: Equatable {
    var since: Int?
    var until: Int
}

/// Bounds for the next page strictly older than `oldestCreatedAt`. No `since`
/// floor — `until` + `limit` walk backwards through quiet stretches.
nonisolated func pageBoundsBehind(_ oldestCreatedAt: Int) -> PageBounds {
    PageBounds(since: nil, until: oldestCreatedAt - 1)
}

nonisolated func pageEndReached(_ receivedNew: Int) -> Bool {
    receivedNew == 0
}

/// Oldest hashtag-reachable event. Keyword-only firehose candidates (no food
/// `#t`) must not move this cursor.
nonisolated func oldestPageableCreatedAt(_ seen: some Collection<NostrEvent>) -> Int? {
    seen.lazy.filter { FoodHashtags.hasFoodTag($0) }.map(\.createdAt).min()
}
