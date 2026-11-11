import Foundation
import Observation

/// One row of the Fresh list as the divider sees it. v1 has no special
/// cards in the list itself (the recipe row sits after the finish line).
nonisolated struct FreshRow: FreshDividable, Identifiable, Equatable {
    let event: NostrEvent
    var id: String { event.id }
    var isSpecialCard: Bool { false }
    var dividerCreatedAt: Int { event.createdAt }

    static func == (a: FreshRow, b: FreshRow) -> Bool { a.event.id == b.event.id }
}

extension FreshDividedRow where R == FreshRow {
    /// Stable identity for a list: the post's id, or the divider's.
    nonisolated var stableId: String {
        switch self {
        case .row(let row): return row.id
        case .divider: return "fresh-divider"
        }
    }
}

/// The live tail as the list sees it.
nonisolated enum FreshTailStatus: Equatable, Sendable {
    /// Not running: before the first page, or while the feed is not shown.
    case idle
    case live
    /// The connection dropped; a revive is pending (foreground, pull-to-
    /// refresh, or the in-foreground retry with backoff).
    case lost
    /// The relay refused the tail (`.floor` / `.invalid`). A refresh or
    /// re-showing the feed starts a new one.
    case ended
}

/// The Fresh feed: the curated relay `wss://feed.zap.cooking`, free tier,
/// read-only (build spec §2 "Fresh feed relay"). Behind
/// `FeatureFlags.freshFeedEnabled`.
///
/// Composes the foundation pieces: `FreshRelayClient` (own socket, no AUTH,
/// verified events), `FreshPosts` (filters), `FreshSpacing`, `FreshLastVisit`
/// and `FreshFinishLine`. What this type adds:
/// - **Hiding.** Mutes, blocks, reports and the hellthread rule apply; Web of
///   Trust does not (ruling 2026-11-10). A reported long-form post is hidden
///   by its coordinate as well as its id, so an edit (new id, same
///   coordinate) stays hidden. `.contentHidden` (block and report both post
///   it, `ContentHide.broadcast`) drops matches from what is already shown,
///   and they are remembered so a later page or the tail can't bring them
///   back before the filter snapshot catches up.
/// - **Own posts.** A new user is not on the curated list, so their post
///   never comes back from the relay. Their own posts of the last 14 days
///   are pinned from local sources (the event store and fresh publishes), in
///   time order, unlabelled; the relay's copy replaces one by id.
/// - **The tail.** Started after the first page, closed when the feed goes
///   away, revived on foreground and pull-to-refresh, and retried with
///   backoff while the app stays in the foreground.
///
/// Nothing about viewing leaves the device: the client names no reader, and
/// the last-visit mark is device-local.
@Observable
@MainActor
final class FreshFeedViewModel {
    // MARK: Published state

    /// What the list shows, newest first: the relay's posts (author-spaced)
    /// with the user's own recent posts placed by time.
    private(set) var posts: [NostrEvent] = []
    private(set) var profiles: [String: ProfileData] = [:]
    private(set) var isLoading = false
    private(set) var isPaging = false
    /// The first page failed or timed out with nothing to show.
    private(set) var loadFailed = false
    private(set) var hasLoaded = false
    /// The end of the free window was reached.
    private(set) var finishLine: FreshFinishLine = .none
    /// The recipe row after the caught-up card (newest first, one per
    /// coordinate, the reader's own rules applied, old edits kept).
    private(set) var recipePicks: [NostrEvent] = []
    /// This session's previous-visit mark (`FreshLastVisit`).
    private(set) var visitMark: Int?
    private(set) var tailStatus: FreshTailStatus = .idle

    /// `posts` with the "new since your last visit" divider placed.
    var rows: [FreshDividedRow<FreshRow>] {
        FreshDivider.withDivider(posts.map(FreshRow.init(event:)), mark: visitMark)
    }

    var isEmpty: Bool { hasLoaded && posts.isEmpty && !loadFailed }

    // MARK: Tunables

    nonisolated static let recipeRowLimit = 12
    /// Paging starts this many rows before the end.
    nonisolated static let loadMorePrefetch = 6
    /// Waits before each in-foreground revive of a lost tail. The last value
    /// repeats; any delivered post starts the sequence again.
    nonisolated static let tailRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    // MARK: Dependencies

    let pubkey: String
    @ObservationIgnored private let client: FreshRelayClient
    @ObservationIgnored private let now: @Sendable () -> Int
    @ObservationIgnored private let rules: () -> SafetyFilterSnapshot?
    @ObservationIgnored private let isReportedCoordinate: (String) -> Bool
    @ObservationIgnored private let ownLocalPosts: () async -> [NostrEvent]
    @ObservationIgnored private let persist: ([NostrEvent]) -> Void
    @ObservationIgnored private let visitStorage: FreshVisitStorage?
    @ObservationIgnored private let lastVisit: FreshLastVisit
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let profileRepo: ProfileRepository?

    // MARK: Internal state

    @ObservationIgnored private var started = false
    /// The feed is the selected kind (its body is shown).
    @ObservationIgnored private(set) var isActive = false
    /// The app is in the foreground.
    @ObservationIgnored private var appActive = true
    /// The relay's posts in display order (spaced; tail posts placed by time).
    @ObservationIgnored private var relayPosts: [NostrEvent] = []
    /// Own posts from local sources, by id.
    @ObservationIgnored private var ownPosts: [String: NostrEvent] = [:]
    /// `until` for the next page: the oldest event the last page returned,
    /// whatever the filters kept (so a page of muted posts can't stall paging).
    @ObservationIgnored private var pageCursor: Int?
    @ObservationIgnored private var recipesRequested = false
    /// Hidden by `.contentHidden` since this VM started; checked at ingest.
    @ObservationIgnored private var hiddenIds: Set<String> = []
    @ObservationIgnored private var hiddenPubkeys: Set<String> = []
    @ObservationIgnored private var hiddenCoordinates: Set<String> = []
    @ObservationIgnored private var tailTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var hideObserver: NSObjectProtocol?
    @ObservationIgnored private var publishObserver: NSObjectProtocol?

    init(
        pubkey: String,
        client: FreshRelayClient? = nil,
        now: (@Sendable () -> Int)? = nil,
        rules: (() -> SafetyFilterSnapshot?)? = nil,
        isReportedCoordinate: ((String) -> Bool)? = nil,
        ownLocalPosts: (() async -> [NostrEvent])? = nil,
        persist: (([NostrEvent]) -> Void)? = nil,
        visitStorage: FreshVisitStorage? = UserDefaults.standard,
        lastVisit: FreshLastVisit? = nil,
        notificationCenter: NotificationCenter = .default,
        retryDelays: [Duration] = FreshFeedViewModel.tailRetryDelays,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        profileRepo: ProfileRepository? = nil
    ) {
        self.pubkey = pubkey
        self.client = client ?? FreshRelayClient()
        self.now = now ?? { NostrClock.now() }
        self.rules = rules ?? { SafetyFilter.shared.snapshot }
        self.isReportedCoordinate = isReportedCoordinate ?? { ReportedContent.shared.isHidden(coordinate: $0) }
        self.ownLocalPosts = ownLocalPosts ?? {
            await EventStore.shared.loadRecentByAuthor(pubkey: pubkey, kinds: FreshPosts.feedKinds, limit: 100)
        }
        self.persist = persist ?? { events in
            guard !events.isEmpty else { return }
            Task { await EventPersistQueue.shared.enqueue(events) }
        }
        self.visitStorage = visitStorage
        self.lastVisit = lastVisit ?? .shared
        self.center = notificationCenter
        self.retryDelays = retryDelays.isEmpty ? FreshFeedViewModel.tailRetryDelays : retryDelays
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        self.profileRepo = profileRepo
    }

    deinit {
        tailTask?.cancel()
        retryTask?.cancel()
        loadTask?.cancel()
        profileUpdatesTask?.cancel()
        if let hideObserver { center.removeObserver(hideObserver) }
        if let publishObserver { center.removeObserver(publishObserver) }
        let client = self.client
        Task { await client.close() }
    }

    // MARK: - Lifecycle

    /// The feed became the selected kind. First time: load page 1, then
    /// start the tail. Later: start the tail again (the list is kept; no
    /// page is re-requested).
    func activate() {
        guard !isActive else { return }
        isActive = true
        if !started {
            started = true
            observeContentHidden()
            observeOwnPublishes()
            ensureProfileUpdates()
            loadTask = Task { [weak self] in await self?.loadFirstPage() }
        } else if hasLoaded {
            startTail(since: tailResumeSince())
        }
    }

    /// Async form for tests: activate and wait for page 1.
    func activateAndWait() async {
        activate()
        await loadTask?.value
    }

    /// The feed went away (another kind picked, or the screen closed): the
    /// socket is closed and the tail stops. The list is kept.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        stopTail()
        let client = self.client
        Task { await client.close() }
    }

    func deactivateAndWait() async {
        guard isActive else { return }
        isActive = false
        stopTail()
        await client.close()
    }

    /// Foreground return (`MainView`'s scene-phase hook).
    func appDidBecomeActive() {
        appActive = true
        guard isActive, started else { return }
        retryAttempt = 0
        reviveOrRestartTail()
    }

    /// Background: no in-foreground retries while suspended.
    func appDidEnterBackground() {
        appActive = false
        retryTask?.cancel()
        retryTask = nil
    }

    /// Pull-to-refresh: page 1 again (from scratch), and the tail revived.
    func refreshAndWait() async {
        guard started else {
            await activateAndWait()
            return
        }
        await client.resetSeen()
        relayPosts = []
        pageCursor = nil
        finishLine = .none
        recipePicks = []
        recipesRequested = false
        await loadPage(first: true)
        if isActive {
            retryAttempt = 0
            reviveOrRestartTail()
        }
    }

    // MARK: - Paging

    func loadMoreIfNeeded(currentIndex: Int) {
        guard currentIndex >= posts.count - Self.loadMorePrefetch else { return }
        loadMore()
    }

    func loadMore() {
        guard hasLoaded, !isPaging, !finishLine.caughtUp, pageCursor != nil else { return }
        isPaging = true
        Task { [weak self] in
            await self?.loadPage(first: false)
        }
    }

    func loadMoreAndWait() async {
        guard hasLoaded, !isPaging, !finishLine.caughtUp, pageCursor != nil else { return }
        isPaging = true
        await loadPage(first: false)
    }

    private func loadFirstPage() async {
        visitMark = lastVisit.beginVisit(pubkey: pubkey, storage: visitStorage)
        isLoading = true
        let floor = now() - FreshPosts.freeWindowSeconds
        let local = await ownLocalPosts()
        for event in local where isOwnCandidate(event, floor: floor) {
            ownPosts[event.id] = event
        }
        await loadPage(first: true)
        isLoading = false
        if isActive {
            startTail(since: relayPosts.map(\.createdAt).max() ?? now())
        }
    }

    private func loadPage(first: Bool) async {
        let answer = await client.feedPage(until: first ? nil : pageCursor)
        let accepted = answer.events.filter(accept)
        if first {
            relayPosts = FreshSpacing.spaceAuthors(before: [], incoming: collapseEdits(accepted, into: []))
        } else {
            relayPosts += FreshSpacing.spaceAuthors(before: relayPosts, incoming: collapseEdits(accepted, into: relayPosts))
        }
        if let oldest = answer.events.map(\.createdAt).min() { pageCursor = oldest }
        persist(accepted)
        switch answer.outcome {
        case .floor:
            reachEnd()
        case .answered where answer.isShortPage:
            reachEnd()
        case .answered:
            break
        case .invalid, .failed, .timedOut:
            // Kept what arrived; the next scroll or refresh asks again.
            break
        }
        if first {
            hasLoaded = true
            switch answer.outcome {
            case .answered, .floor: loadFailed = false
            case .invalid, .failed, .timedOut: loadFailed = answer.events.isEmpty
            }
            if let newest = relayPosts.map(\.createdAt).max() {
                lastVisit.recordNewest(newest, pubkey: pubkey, storage: visitStorage)
            }
        }
        isPaging = false
        emit()
    }

    private func reachEnd() {
        finishLine = .of(reached: true)
        guard !recipesRequested else { return }
        recipesRequested = true
        Task { [weak self] in await self?.loadRecipes() }
    }

    /// Async form for tests.
    func loadRecipesAndWait() async {
        recipesRequested = true
        await loadRecipes()
    }

    private func loadRecipes() async {
        let answer = await client.recipes()
        let rules = self.rules()
        var byCoordinate: [String: NostrEvent] = [:]
        for event in answer.events where FreshPosts.isRecipe(kind: event.kind, tags: event.tags) {
            guard FreshPosts.passesReaderFilters(event, rules: rules), !isHiddenLocally(event) else { continue }
            let coordinate = RecipeRepository.coordinate(event)
            if let kept = byCoordinate[coordinate], kept.createdAt >= event.createdAt { continue }
            byCoordinate[coordinate] = event
        }
        recipePicks = Array(FreshRelayClient.newestFirst(Array(byCoordinate.values)).prefix(Self.recipeRowLimit))
        observeProfiles(in: recipePicks)
    }

    // MARK: - Tail

    private func startTail(since: Int) {
        stopTail()
        let client = self.client
        tailStatus = .live
        tailTask = Task { [weak self] in
            let stream = await client.liveTail(since: since)
            for await update in stream {
                guard let self, !Task.isCancelled else { return }
                self.handleTail(update)
            }
        }
    }

    private func stopTail() {
        tailTask?.cancel()
        tailTask = nil
        retryTask?.cancel()
        retryTask = nil
        tailStatus = .idle
    }

    /// A new tail asks from the newest relay post minus the client's overlap;
    /// the client's seen-set drops what is already shown.
    private func tailResumeSince() -> Int {
        let newest = relayPosts.map(\.createdAt).max() ?? now()
        return newest - FreshRelayClient.tailResumeOverlapSeconds
    }

    private func reviveOrRestartTail() {
        switch tailStatus {
        case .lost:
            let client = self.client
            Task { [weak self] in
                let revived = await client.reviveTail()
                if !revived { self?.startTail(since: self?.tailResumeSince() ?? 0) }
            }
        case .ended, .idle:
            startTail(since: tailResumeSince())
        case .live:
            break
        }
    }

    private func handleTail(_ update: FreshTailUpdate) {
        switch update {
        case .event(let event):
            tailStatus = .live
            retryAttempt = 0
            guard accept(event) else { return }
            if event.kind == 30023, replaceEdit(event) {
                emit()
                return
            }
            let index = relayPosts.firstIndex { $0.createdAt < event.createdAt } ?? relayPosts.endIndex
            relayPosts.insert(event, at: index)
            persist([event])
            if let newest = relayPosts.map(\.createdAt).max() {
                lastVisit.recordNewest(newest, pubkey: pubkey, storage: visitStorage)
            }
            emit()
        case .lost:
            tailStatus = .lost
            scheduleTailRetry()
        case .revived:
            tailStatus = .live
        case .ended:
            tailStatus = .ended
        }
    }

    /// While the app stays in the foreground, a lost tail is revived after a
    /// growing wait. Backgrounding stops it; the foreground hook revives at
    /// once instead.
    private func scheduleTailRetry() {
        guard isActive, appActive, retryTask == nil else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        let sleep = self.sleep
        let client = self.client
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            guard self.isActive, self.appActive, self.tailStatus == .lost else { return }
            _ = await client.reviveTail()
        }
    }

    // MARK: - Ingest

    private func accept(_ event: NostrEvent) -> Bool {
        guard FreshPosts.feedKinds.contains(event.kind) else { return false }
        guard FreshPosts.passesFreshFilters(event, rules: rules(), now: now()) else { return false }
        return !isHiddenLocally(event)
    }

    /// Reported coordinates (persisted) and anything `.contentHidden` named.
    private func isHiddenLocally(_ event: NostrEvent) -> Bool {
        if hiddenIds.contains(event.id) || hiddenPubkeys.contains(event.pubkey.lowercased()) { return true }
        if Self.isAddressable(event) {
            let coordinate = RecipeRepository.coordinate(event)
            if hiddenCoordinates.contains(coordinate) || isReportedCoordinate(coordinate) { return true }
        }
        return false
    }

    nonisolated private static func isAddressable(_ event: NostrEvent) -> Bool {
        event.kind == 30023 || event.kind == 30024
    }

    /// Long-form edits share a coordinate: keep the newest per coordinate,
    /// within the incoming page and against what is already shown (an older
    /// one already shown is replaced in place).
    private func collapseEdits(_ incoming: [NostrEvent], into existing: [NostrEvent]) -> [NostrEvent] {
        var newestByCoordinate: [String: NostrEvent] = [:]
        for event in incoming where event.kind == 30023 {
            let c = RecipeRepository.coordinate(event)
            if let kept = newestByCoordinate[c], kept.createdAt >= event.createdAt { continue }
            newestByCoordinate[c] = event
        }
        var out: [NostrEvent] = []
        for event in incoming {
            if event.kind == 30023 {
                let c = RecipeRepository.coordinate(event)
                guard newestByCoordinate[c]?.id == event.id else { continue }
                if replaceEdit(event) { continue }
            }
            out.append(event)
        }
        return out
    }

    /// True when `event` (kind 30023) matched a shown post's coordinate: the
    /// newer of the two now sits in that row, and nothing is added.
    private func replaceEdit(_ event: NostrEvent) -> Bool {
        let c = RecipeRepository.coordinate(event)
        guard let i = relayPosts.firstIndex(where: { $0.kind == 30023 && RecipeRepository.coordinate($0) == c }) else {
            return false
        }
        if relayPosts[i].createdAt < event.createdAt { relayPosts[i] = event }
        return true
    }

    // MARK: - Own posts

    private func isOwnCandidate(_ event: NostrEvent, floor: Int) -> Bool {
        event.pubkey == pubkey
            && FreshPosts.feedKinds.contains(event.kind)
            && event.createdAt >= floor
            && accept(event)
    }

    private func observeOwnPublishes() {
        guard publishObserver == nil else { return }
        publishObserver = center.addObserver(forName: .nostrEventPublished, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? NostrEvent else { return }
            MainActor.assumeIsolated { self?.insertOwnPublished(event) }
        }
    }

    /// Pin a post the user just published (no relay query).
    func insertOwnPublished(_ event: NostrEvent) {
        guard isOwnCandidate(event, floor: now() - FreshPosts.freeWindowSeconds) else { return }
        ownPosts[event.id] = event
        emit()
    }

    // MARK: - Hiding

    private func observeContentHidden() {
        guard hideObserver == nil else { return }
        hideObserver = center.addObserver(forName: .contentHidden, object: nil, queue: .main) { [weak self] note in
            let ids = Set(note.userInfo?[ContentHideKey.eventIds] as? [String] ?? [])
            let pubkeys = Set((note.userInfo?[ContentHideKey.pubkeys] as? [String] ?? []).map { $0.lowercased() })
            let coordinates = Set(note.userInfo?[ContentHideKey.coordinates] as? [String] ?? [])
            MainActor.assumeIsolated {
                self?.dropHidden(eventIds: ids, pubkeys: pubkeys, coordinates: coordinates)
            }
        }
    }

    /// Instant hide for block and report (`ContentHide.broadcast`).
    func dropHidden(eventIds: Set<String>, pubkeys: Set<String>, coordinates: Set<String>) {
        guard !eventIds.isEmpty || !pubkeys.isEmpty || !coordinates.isEmpty else { return }
        hiddenIds.formUnion(eventIds)
        hiddenPubkeys.formUnion(pubkeys.map { $0.lowercased() })
        hiddenCoordinates.formUnion(coordinates)
        relayPosts.removeAll(where: isHiddenLocally)
        ownPosts = ownPosts.filter { !isHiddenLocally($0.value) }
        recipePicks.removeAll(where: isHiddenLocally)
        emit()
    }

    // MARK: - Emit

    private func emit() {
        let relayIds = Set(relayPosts.map(\.id))
        let oldestRelay = relayPosts.map(\.createdAt).min()
        let floor = now() - FreshPosts.freeWindowSeconds
        // Own posts the relay didn't return, within the window, and not older
        // than what is loaded (unless the end is reached): placed by time.
        let pinned = ownPosts.values
            .filter { !relayIds.contains($0.id) && $0.createdAt >= floor }
            .filter { own in finishLine.caughtUp || oldestRelay.map { own.createdAt >= $0 } ?? true }
            .sorted { $0.createdAt > $1.createdAt }
        var merged = relayPosts
        for own in pinned {
            let index = merged.firstIndex { $0.createdAt < own.createdAt } ?? merged.endIndex
            merged.insert(own, at: index)
        }
        posts = merged
        observeProfiles(in: merged)
    }

    // MARK: - Profiles

    private func observeProfiles(in events: [NostrEvent]) {
        let repo = profileRepo ?? ProfileRepository.shared
        for pk in Set(events.map(\.pubkey)) where profiles[pk] == nil {
            if let cached = repo.get(pk) { profiles[pk] = cached }
        }
        MissingProfileWatcher.shared.observe(events)
    }

    private func ensureProfileUpdates() {
        guard profileUpdatesTask == nil else { return }
        let repo = profileRepo ?? ProfileRepository.shared
        profileUpdatesTask = Task { @MainActor [weak self] in
            for await pk in MissingProfileWatcher.shared.updates {
                guard let self else { return }
                if let p = repo.get(pk) { self.profiles[pk] = p }
            }
        }
    }
}
