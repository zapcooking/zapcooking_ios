import Foundation
import Observation

/// One-shot OnlyFood relay query. Injected so hermetic tests can assert
/// §7.4 (toggle does not re-query) without opening a socket.
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
/// set (Concern 3.3). Modes: Global and Following. Filtering is mute-only in
/// v1 (§7.3) — this type never calls `SpamScorer`.
///
/// **Per-mode cache — DON'T re-query on toggle (§7.4).** Search relays
/// rate-limit repeated queries per connection: the first identical query
/// returns ~99 events, a repeat ~12s later returns 0. Each mode is queried
/// **once** and cached; toggling ``setMode`` swaps the visible list with
/// **no relay query**. A mode that legitimately returns 0 still gets
/// `loaded = true`. Pull-to-refresh is the only re-query path.
///
/// **§7.2 / §7.5:** subscription IDs come from a process-wide atomic
/// sequence; teardown CLOSEs only the subIds actually opened, on the relays
/// they were opened on. Load / mode-toggle / pagination serialize through
/// one ``submit`` that cancels the previous job before the next REQ.
@Observable
@MainActor
final class OnlyFoodFeedViewModel {

    enum Mode: String, CaseIterable, Hashable {
        case global
        case following
    }

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
    static let authorChunk = 500
    static let maxRetainedEvents = 3000
    static let queryTimeout: TimeInterval = 10

    var notes: [NostrEvent] = []
    var profiles: [String: ProfileData] = [:]
    var mode: Mode = .global
    var isLoading = false
    var isPaging = false
    var isRefreshing = false
    var emptyFollows = false
    var wotDropped = 0
    /// True when the last initial/refresh query of the visible mode finished
    /// without a genuine EOSE (timeout, dropped send, connect miss) and nothing
    /// is on screen. Distinct from ``isEmpty`` (EOSE arrived, zero accepted).
    var loadFailed = false

    /// Relay queries issued this session. Tests assert the §7.4 latch against
    /// this rather than sockets. Production increments it too, which is how
    /// the live gate reports "second Global issued no new REQ."
    private(set) var queryCount = 0

    let pubkey: String

    @ObservationIgnored private var started = false
    @ObservationIgnored private let states: [Mode: ModeState] = [
        .global: ModeState(),
        .following: ModeState(),
    ]
    @ObservationIgnored private(set) var inFlight: Task<Void, Never>?
    @ObservationIgnored private var submitGeneration = 0
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var sweepSourceId: UUID?

    @ObservationIgnored private let filter: OnlyFoodFilter
    @ObservationIgnored private let follows: () -> [String]
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
        follows: (() -> [String])? = nil,
        query: ((OnlyFoodQueryRequest) async -> OnlyFoodQueryResult)? = nil,
        seedCache: (() async -> [NostrEvent])? = nil,
        persist: (([NostrEvent]) -> Void)? = nil,
        profileRepo: ProfileRepository? = nil
    ) {
        self.pubkey = pubkey
        self.filter = filter ?? OnlyFoodFilter.live()
        self.follows = follows ?? { FollowsCache.shared.follows(for: pubkey) }
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
        if let id = sweepSourceId {
            Task { @MainActor in MissingProfileWatcher.shared.unregisterSource(id) }
        }
    }

    /// True once the current mode has completed a query, whatever the event
    /// count. A legitimately empty mode must not look like "never loaded."
    var hasLoaded: Bool { stateOf(mode).loaded }

    /// Still fetching the first window, and nothing is on screen yet.
    var isAwaitingFirstPaint: Bool { notes.isEmpty && !hasLoaded && !emptyFollows && !loadFailed }

    /// A completed load that found nothing. Distinct from empty-follows
    /// and from a relay miss (``isLoadFailed``).
    var isEmpty: Bool { notes.isEmpty && hasLoaded && !emptyFollows }

    /// The search relay never answered. Distinct from genuine empty (EOSE,
    /// zero accepted) so the UI can say "couldn't reach" instead of
    /// "no food posts yet."
    var isLoadFailed: Bool { notes.isEmpty && loadFailed && !hasLoaded && !emptyFollows }

    func isLoaded(_ mode: Mode) -> Bool { stateOf(mode).loaded }

    func cachedCount(_ mode: Mode) -> Int { stateOf(mode).seen.count }

    /// One-shot. SwiftUI re-runs `.task` on state changes; a second call is
    /// a no-op so an identical filter never re-hits the same connection (§7.4).
    func start() {
        guard !started else { return }
        started = true
        ensureProfileUpdatesSubscription()
        let mode = self.mode
        let st = stateOf(mode)
        if !st.loaded {
            submit(mode: mode, state: st, load: .initial, since: nil, until: nil)
        }
    }

    func startAndWait() async {
        start()
        await inFlight?.value
    }

    /// Instant cache swap. Queries the target mode only if it's never loaded.
    func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        let st = stateOf(mode)
        emitCurrentMode()
        emptyFollows = st.emptyFollows
        isPaging = false
        isRefreshing = false
        if st.loaded {
            isLoading = false
            loadFailed = false
        }
        if !st.loaded {
            submit(mode: mode, state: st, load: .initial, since: nil, until: nil)
        }
    }

    /// The ONLY path that re-queries a loaded mode. Merges newest into cache.
    func refresh() {
        let mode = self.mode
        let st = stateOf(mode)
        st.endReached = false
        submit(mode: mode, state: st, load: .refresh, since: nil, until: nil)
    }

    func refreshAndWait() async {
        refresh()
        await inFlight?.value
    }

    func loadMore() {
        let mode = self.mode
        let st = stateOf(mode)
        if isLoading || isPaging || isRefreshing || st.endReached { return }
        if st.seen.count >= Self.maxRetainedEvents {
            st.endReached = true
            return
        }
        guard let oldest = oldestPageableCreatedAt(st.seen.values) else { return }
        let bounds = pageBoundsBehind(oldest)
        submit(mode: mode, state: st, load: .page, since: bounds.since, until: bounds.until)
    }

    func loadMoreIfNeeded(currentIndex: Int, total: Int) {
        guard total > 0, currentIndex >= total - Self.loadMorePrefetch else { return }
        loadMore()
    }

    // MARK: - Submit

    /// Single serialized entry point. Captures `mode`/`state` at call-time so
    /// a mid-flight toggle cannot mis-route results. Cancels the previous job
    /// before the next REQ (§7.5).
    ///
    /// Empty Following is handled **synchronously**: no spinner, no REQ, and
    /// `loaded = true` so a later toggle does not re-enter this path.
    private func submit(mode: Mode, state: ModeState, load: Load, since: Int?, until: Int?) {
        let followList = (mode == .following) ? follows() : nil
        if let followList, followList.isEmpty {
            inFlight?.cancel()
            inFlight = nil
            state.loaded = true
            state.emptyFollows = true
            if self.mode == mode {
                emptyFollows = true
                loadFailed = false
                clearIndicators()
                emitCurrentMode()
            }
            return
        }

        inFlight?.cancel()
        submitGeneration += 1
        let generation = submitGeneration
        state.emptyFollows = false
        if self.mode == mode {
            emptyFollows = false
            if load == .initial || load == .refresh { loadFailed = false }
            switch load {
            case .initial: isLoading = true
            case .page: isPaging = true
            case .refresh: isRefreshing = true
            }
        }
        inFlight = Task { @MainActor in
            if load == .initial || load == .refresh { state.unsettle() }
            if load == .refresh { self.wotDropped = 0 }
            if load == .initial, mode == .global {
                await self.paintGlobalFromCache(state)
            }

            let followsSet = followList.map { Set($0) }
            var received = 0
            var connected = false
            var anySent = false
            var eoseFired = false
            var accepted: [NostrEvent] = []

            if let followList {
                let chunks = chunked(followList, into: Self.authorChunk)
                let base = Self.nextSubId()
                for (i, chunk) in chunks.enumerated() {
                    if Task.isCancelled { break }
                    var filter = Self.baseFilter(since: since, until: until)
                    filter.authors = chunk
                    let subId = "\(base)-\(i)"
                    let result = await self.issue(relays: [Self.searchRelay], filter: filter, subId: subId)
                    connected = connected || result.connected
                    anySent = anySent || result.anySent
                    eoseFired = eoseFired || result.eoseFired
                    let newly = self.ingestBatch(result.events, into: state, follows: followsSet)
                    received += newly.count
                    accepted.append(contentsOf: newly)
                }
            } else {
                let filter = Self.baseFilter(since: since, until: until)
                let subId = Self.nextSubId()
                let result = await self.issue(relays: [Self.searchRelay], filter: filter, subId: subId)
                connected = result.connected
                anySent = result.anySent
                eoseFired = result.eoseFired
                let newly = self.ingestBatch(result.events, into: state, follows: nil)
                received = newly.count
                accepted = newly
            }

            guard !Task.isCancelled, generation == self.submitGeneration else { return }

            let latched = shouldLatchLoaded(connected: connected, anySent: anySent, eoseFired: eoseFired)
            if latched {
                state.loaded = true
                if load == .page, pageEndReached(received) { state.endReached = true }
            }
            if eoseFired, load == .initial || load == .refresh {
                _ = mergeFeedOrder(
                    ordered: &state.ordered,
                    placedIds: &state.placedIds,
                    seen: state.seen.values,
                    settled: false
                )
                state.settled = true
            }
            if self.mode == mode {
                self.emitCurrentMode()
                if latched {
                    self.loadFailed = false
                } else if (load == .initial || load == .refresh), self.notes.isEmpty {
                    self.loadFailed = true
                }
                self.clearIndicators()
            }
            self.persist(accepted)
            self.observeProfiles(in: Array(state.seen.values))
        }
    }

    private func paintGlobalFromCache(_ state: ModeState) async {
        guard state.seen.isEmpty else { return }
        let cached = await seedCache()
        var added = false
        for event in cached where event.kind == 1 {
            if ingestEvent(
                event,
                seen: &state.seen,
                accept: { self.accept($0, follows: nil) },
                onAccepted: { _ in },
                signalFlush: {}
            ) {
                added = true
            }
        }
        if added, mode == .global {
            emitCurrentMode()
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

    private func ingestBatch(
        _ events: [NostrEvent],
        into state: ModeState,
        follows: Set<String>?
    ) -> [NostrEvent] {
        var newly: [NostrEvent] = []
        for event in events where event.kind == 1 {
            let inserted = ingestEvent(
                event,
                seen: &state.seen,
                accept: { self.accept($0, follows: follows) },
                onAccepted: { _ in },
                signalFlush: {}
            )
            if inserted { newly.append(event) }
        }
        return newly
    }

    private func accept(_ event: NostrEvent, follows: Set<String>?) -> Bool {
        if let follows, !follows.contains(event.pubkey) { return false }
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

    private func emitCurrentMode() {
        let st = stateOf(mode)
        notes = mergeFeedOrder(
            ordered: &st.ordered,
            placedIds: &st.placedIds,
            seen: st.seen.values,
            settled: st.settled
        )
    }

    private func clearIndicators() {
        isLoading = false
        isPaging = false
        isRefreshing = false
    }

    private func stateOf(_ mode: Mode) -> ModeState {
        states[mode]!
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

    static func nextSubId() -> String {
        "onlyfood-\(subSeq.next())"
    }
}

// MARK: - Per-mode cache

/// Source of truth + display cache for one mode. Not thread-safe; the VM
/// is `@MainActor` so every mutation is on one thread.
nonisolated final class ModeState: @unchecked Sendable {
    var seen: [String: NostrEvent] = [:]
    var ordered: [NostrEvent] = []
    var placedIds: Set<String> = []
    var loaded = false
    var endReached = false
    var emptyFollows = false
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
        await RelayConnectionPool.shared.register(subId: request.subId, relays: relayReqs, sink: sink)
        let connected = true
        let anySent = true

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

/// A mode is "loaded" (so it won't be re-queried on toggle) ONLY when the
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

private func chunked<T>(_ items: [T], into size: Int) -> [[T]] {
    guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
    var chunks: [[T]] = []
    var i = 0
    while i < items.count {
        let end = min(i + size, items.count)
        chunks.append(Array(items[i..<end]))
        i = end
    }
    return chunks
}
