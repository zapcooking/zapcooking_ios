import Foundation
import Observation

/// One row of the Fresh list as the divider sees it: a post, or a special
/// card (recipe box or spotlight, behind `FeatureFlags.freshSpecialsEnabled`)
/// placed after its anchor post.
nonisolated struct FreshRow: FreshDividable, Identifiable, Equatable {
    enum Content {
        case post(NostrEvent)
        case card(key: String, special: FreshSpecial)
    }

    let content: Content

    init(event: NostrEvent) { content = .post(event) }
    init(cardKey: String, special: FreshSpecial) { content = .card(key: cardKey, special: special) }

    /// The post, or nil for a card.
    var event: NostrEvent? {
        if case .post(let e) = content { return e }
        return nil
    }

    var special: FreshSpecial? {
        if case .card(_, let special) = content { return special }
        return nil
    }

    /// The post's id, or the card's slot key (`sp:<n>`).
    var id: String {
        switch content {
        case .post(let e): return e.id
        case .card(let key, _): return key
        }
    }

    var isSpecialCard: Bool { event == nil }
    /// Cards are skipped by the divider; the value is never read for one.
    var dividerCreatedAt: Int { event?.createdAt ?? 0 }

    static func == (a: FreshRow, b: FreshRow) -> Bool {
        switch (a.content, b.content) {
        case let (.post(x), .post(y)): return x.id == y.id
        case let (.card(k1, s1), .card(k2, s2)): return k1 == k2 && s1 == s2
        default: return false
        }
    }
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

/// Where Fresh gets author profiles. The live source is the app's profile
/// cache plus `MissingProfileWatcher` (which fetches missing kind 0s);
/// tests pass one that fetches nothing.
@MainActor
protocol FreshProfileSource {
    func cached(_ pubkey: String) -> ProfileData?
    func observe(_ events: [NostrEvent])
    func updates() -> AsyncStream<String>
}

@MainActor
struct LiveFreshProfileSource: FreshProfileSource {
    func cached(_ pubkey: String) -> ProfileData? { ProfileRepository.shared.get(pubkey) }
    func observe(_ events: [NostrEvent]) { MissingProfileWatcher.shared.observe(events) }
    func updates() -> AsyncStream<String> { MissingProfileWatcher.shared.updates }
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
///   never comes back from the relay. Their own signed, public posts of the
///   last 14 days are pinned from local sources (the event store, reloaded on
///   refresh, and fresh publishes), in time order, unlabelled; the relay's
///   copy replaces one by id, and long-form keeps the newest per coordinate.
///   Private replies (`PrivateInteractionStore`) never appear.
/// - **Lifecycle.** The socket is open only while Fresh is the selected kind.
///   Leaving bumps `epoch`: work in flight is dropped before it can send a
///   request or apply a result, and the next connection waits for the close.
///   A first load cut short this way starts again on the next activation.
/// - **The tail.** Started after page 1 from the newest post (clamped to now
///   + skew), closed when the feed goes away, revived on foreground, restarted
///   with an overlap on pull-to-refresh, and retried with backoff while the
///   app stays in the foreground.
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
    /// Recipes from the relay, newest first, one per coordinate, filtered;
    /// `recipePicks` is what of it the row shows.
    private(set) var recipePool: [NostrEvent] = []

    /// The recipe row: the pool minus any recipe already shown in the feed
    /// above it (by id or by coordinate, so another edit of the same recipe
    /// counts as shown), at most `recipeRowLimit`.
    var recipePicks: [NostrEvent] {
        // Minus what the recipe-box cards took (Seth, 2026-11-11).
        FreshRecipeBox.rowPicks(pool: recipePool, feed: posts, boxTaken: boxTaken, limit: Self.recipeRowLimit)
    }
    /// Decided special-card slots, in slot order (`freshSpecialsEnabled`):
    /// a card after its anchor post, or a skipped slot.
    private(set) var placedSlots: [FreshPlacedSlot] = []
    /// Recipe coordinates the box cards took since the last refresh.
    private(set) var boxTaken: Set<String> = []
    /// This session's previous-visit mark (`FreshLastVisit`).
    private(set) var visitMark: Int?
    private(set) var tailStatus: FreshTailStatus = .idle
    /// Tail posts waiting behind the "N new posts" pill. They are never put
    /// into the list on their own: the reader taps the pill
    /// (`showNewPosts`), which scrolls to the top and inserts them, so the
    /// list never moves under them.
    private(set) var newPostsCount = 0
    /// How many waiting posts the reader dismissed the pill for; the pill
    /// comes back when more arrive.
    /// Observed: closing the pill must update the overlay at once.
    private var pillDismissedAt = 0

    /// The pill shows while posts wait that the reader hasn't dismissed.
    var showsNewPostsPill: Bool { newPostsCount > pillDismissedAt }

    /// `posts` with the special cards after their anchors and the "new since
    /// your last visit" divider placed (cards don't count for it).
    var rows: [FreshDividedRow<FreshRow>] {
        let items: [FreshRow]
        if placedSlots.isEmpty {
            items = posts.map(FreshRow.init(event:))
        } else {
            items = FreshSpecials.place(posts, id: { $0.id }, slots: placedSlots).map {
                switch $0 {
                case .item(let event): return FreshRow(event: event)
                case .card(let key, let special): return FreshRow(cardKey: key, special: special)
                }
            }
        }
        return FreshDivider.withDivider(items, mark: visitMark)
    }

    var isEmpty: Bool { hasLoaded && posts.isEmpty && !loadFailed }

    /// The "nothing yet" message. Once the end is reached the list shows
    /// instead, so the caught-up line and the recipe row are visible even
    /// when no post is.
    var showsEmptyMessage: Bool { isEmpty && !finishLine.caughtUp && newPostsCount == 0 }

    /// "Couldn't reach Fresh": page 1 failed with nothing to show. Posts
    /// waiting behind the pill show the list (and its pill) instead.
    var showsFailureMessage: Bool { loadFailed && posts.isEmpty && newPostsCount == 0 }

    // MARK: Tunables

    nonisolated static let recipeRowLimit = 12
    /// How many recipes are kept for the row, before excluding the feed's.
    nonisolated static let recipePoolLimit = 60
    /// Paging starts this many rows before the end.
    nonisolated static let loadMorePrefetch = 6
    /// Waits before each in-foreground revive of a lost tail. The last value
    /// repeats; any delivered post starts the sequence again.
    nonisolated static let tailRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]
    /// A full page whose posts are all filtered out adds no row to scroll to;
    /// this many such pages in a row are fetched without waiting for a scroll.
    nonisolated static let maxEmptyPageHops = 5
    /// Special-card slots are decided once their anchor is at most this many
    /// posts below the deepest post the reader has reached. An index stand-in
    /// for web's "within three screens" (a LazyVStack exposes no geometry).
    nonisolated static let slotDecideAhead = 12
    /// More than this many posts below the reader, a slot waits for the
    /// rotation's own next type (web `strict`, "more than two screens
    /// below"); closer, whichever type is ready takes it. A slot whose anchor
    /// the reader has already reached is skipped: nothing is inserted above
    /// what the reader is reading.
    nonisolated static let slotNearPosts = 4

    // MARK: Dependencies

    let pubkey: String
    @ObservationIgnored private let client: FreshRelayClient
    @ObservationIgnored private let now: @Sendable () -> Int
    @ObservationIgnored private let rules: () -> SafetyFilterSnapshot?
    @ObservationIgnored private let isReportedCoordinate: (String) -> Bool
    @ObservationIgnored private let isPrivate: (String) -> Bool
    @ObservationIgnored private let isDeleted: (NostrEvent) -> Bool
    @ObservationIgnored private let ownLocalPosts: () async -> [NostrEvent]
    @ObservationIgnored private let persist: ([NostrEvent]) -> Void
    @ObservationIgnored private let visitStorage: FreshVisitStorage?
    @ObservationIgnored private let lastVisit: FreshLastVisit
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let profileSource: FreshProfileSource
    /// `FeatureFlags.freshSpecialsEnabled` (tests and the screenshot
    /// fixtures pass true). Off: no slots, no topic list, no preview, no early
    /// recipe download; the list is exactly as before.
    @ObservationIgnored let specialsEnabled: Bool
    @ObservationIgnored private let specialsStore: FreshSpecialsStore
    @ObservationIgnored private let specialsRng: FreshRandom
    @ObservationIgnored private let topicGroups: () async -> [FreshTopicGroup]
    @ObservationIgnored private let topicPreview: ((String) async -> FreshAnswer)?
    @ObservationIgnored private let specialsSchedule: ((TimeInterval, @escaping @MainActor () -> Void) -> () -> Void)?

    // MARK: Internal state

    @ObservationIgnored private var observing = false
    /// The feed is the selected kind (its body is shown).
    @ObservationIgnored private(set) var isActive = false
    /// The app is in the foreground.
    @ObservationIgnored private var appActive = true
    /// Bumped on every deactivation; async work captures it and stops when
    /// it changes.
    @ObservationIgnored private var epoch = 0
    /// The close started by the last deactivation; new connections wait for it.
    @ObservationIgnored private var pendingClose: Task<Void, Never>?
    /// The relay's posts in display order (spaced; tail posts placed by time).
    @ObservationIgnored private var relayPosts: [NostrEvent] = []
    /// Tail posts held behind the pill, in arrival order.
    @ObservationIgnored private var pendingNew: [NostrEvent] = []
    /// Own posts from local sources, by id.
    @ObservationIgnored private var ownPosts: [String: NostrEvent] = [:]
    /// `until` for the next page: the oldest event the last page returned,
    /// whatever the filters kept (so a page of muted posts can't stall paging).
    @ObservationIgnored private var pageCursor: Int?
    @ObservationIgnored private var recipesLoaded = false
    /// Hidden by `.contentHidden` since this VM started; checked at ingest.
    @ObservationIgnored private var hiddenIds: Set<String> = []
    @ObservationIgnored private var hiddenPubkeys: Set<String> = []
    @ObservationIgnored private var hiddenCoordinates: Set<String> = []
    @ObservationIgnored private var tailTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var recipeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var hideObserver: NSObjectProtocol?
    @ObservationIgnored private var publishObserver: NSObjectProtocol?
    @ObservationIgnored private var deletionObserver: NSObjectProtocol?
    // Specials (session state lives as long as this view model; a refresh
    // resets the slots and keeps the rotation and the used topics, as web).
    @ObservationIgnored private var spotlights: FreshSpotlightLoader?
    @ObservationIgnored private var slotPlan: FreshSlots
    @ObservationIgnored private var rotation = FreshRotation()
    @ObservationIgnored private var slotSerial = 0
    /// The deepest post the reader's list has shown (by id, so posts inserted
    /// above it don't move it).
    @ObservationIgnored private var deepestSeenId: String?
    /// Older recipes for the box cards (`FreshRecipeBox.buildPool`), from the
    /// same download as the recipe row, uncapped.
    @ObservationIgnored private var boxPool: [NostrEvent] = []
    /// Cards whose appearance was recorded in the shown stores.
    @ObservationIgnored private var recordedCards: Set<String> = []

    init(
        pubkey: String,
        client: FreshRelayClient? = nil,
        now: (@Sendable () -> Int)? = nil,
        rules: (() -> SafetyFilterSnapshot?)? = nil,
        isReportedCoordinate: ((String) -> Bool)? = nil,
        isPrivate: ((String) -> Bool)? = nil,
        isDeleted: ((NostrEvent) -> Bool)? = nil,
        ownLocalPosts: (() async -> [NostrEvent])? = nil,
        persist: (([NostrEvent]) -> Void)? = nil,
        visitStorage: FreshVisitStorage? = UserDefaults.standard,
        lastVisit: FreshLastVisit? = nil,
        notificationCenter: NotificationCenter = .default,
        retryDelays: [Duration] = FreshFeedViewModel.tailRetryDelays,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        profileSource: FreshProfileSource? = nil,
        specialsEnabled: Bool = FeatureFlags.freshSpecialsEnabled,
        specialsStore: FreshSpecialsStore? = nil,
        specialsRng: FreshRandom? = nil,
        topicGroups: (() async -> [FreshTopicGroup])? = nil,
        topicPreview: ((String) async -> FreshAnswer)? = nil,
        specialsSchedule: ((TimeInterval, @escaping @MainActor () -> Void) -> () -> Void)? = nil
    ) {
        self.pubkey = pubkey
        self.client = client ?? FreshRelayClient()
        self.now = now ?? { NostrClock.now() }
        self.rules = rules ?? { SafetyFilter.shared.snapshot }
        self.isReportedCoordinate = isReportedCoordinate ?? { ReportedContent.shared.isHidden(coordinate: $0) }
        self.isPrivate = isPrivate ?? { PrivateInteractionStore.shared.privateEventIds.contains($0) }
        // The app's deletion handling (NIP-09, `DeletionTracker`), in its
        // strict form: a kind 5 counts only from the post's own author.
        self.isDeleted = isDeleted ?? { DeletionTracker.shared.isDeleted(eventId: $0.id, author: $0.pubkey) }
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
        self.profileSource = profileSource ?? LiveFreshProfileSource()
        self.specialsEnabled = specialsEnabled
        self.specialsStore = specialsStore ?? FreshSpecialsStore(pubkey: pubkey)
        let rng = specialsRng ?? { Double.random(in: 0..<1) }
        self.specialsRng = rng
        self.slotPlan = FreshSlots(rng: rng)
        self.topicGroups = topicGroups ?? { await FreshTopicList.shared.groups() }
        self.topicPreview = topicPreview
        self.specialsSchedule = specialsSchedule
    }

    deinit {
        tailTask?.cancel()
        retryTask?.cancel()
        loadTask?.cancel()
        pageTask?.cancel()
        recipeTask?.cancel()
        profileUpdatesTask?.cancel()
        if let hideObserver { center.removeObserver(hideObserver) }
        if let publishObserver { center.removeObserver(publishObserver) }
        if let deletionObserver { center.removeObserver(deletionObserver) }
        let client = self.client
        Task { await client.close() }
    }

    // MARK: - Lifecycle

    /// The feed became the selected kind. Until page 1 has loaded: load it
    /// (again, if a previous attempt was cut short), then start the tail.
    /// After that: start the tail again; the list is kept and no page is
    /// re-requested.
    func activate() {
        guard !isActive else { return }
        isActive = true
        if !observing {
            observing = true
            observeContentHidden()
            observeOwnPublishes()
            observeDeletions()
            ensureProfileUpdates()
        }
        if !hasLoaded {
            guard loadTask == nil else { return }
            let epoch = self.epoch
            loadTask = Task { [weak self] in await self?.loadFirstPage(epoch: epoch) }
            // Special cards: the recipe box needs the recipe download, which is
            // much bigger than page 1. Asked alongside it, so the first slot
            // (after post 5–7) isn't reached before a recipe is ready.
            if specialsEnabled && !recipesLoaded { startRecipes() }
        } else {
            startTail(since: tailAnchor() - FreshRelayClient.tailResumeOverlapSeconds)
            if finishLine.caughtUp && !recipesLoaded { startRecipes() }
            startSpecials()
        }
    }

    /// Async form for tests: activate and wait for page 1.
    func activateAndWait() async {
        activate()
        await loadTask?.value
    }

    /// The feed went away (another kind picked, or the screen closed): work
    /// in flight is abandoned, the tail stops and the socket closes. The list
    /// is kept.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        epoch += 1
        stopTail()
        for task in [loadTask, pageTask, recipeTask] { task?.cancel() }
        loadTask = nil
        pageTask = nil
        recipeTask = nil
        isLoading = false
        isPaging = false
        let client = self.client
        let previous = pendingClose
        pendingClose = Task {
            await previous?.value
            await client.close()
        }
    }

    func deactivateAndWait() async {
        deactivate()
        await pendingClose?.value
    }

    /// Foreground return (`MainView`'s scene-phase hook, forwarded whatever
    /// the selected kind so `appActive` is always current).
    func appDidBecomeActive() {
        appActive = true
        // Page 1 (or a refresh) starts the tail itself when it finishes.
        guard isActive, hasLoaded, loadTask == nil, !refreshing else { return }
        retryAttempt = 0
        reviveOrRestartTail()
    }

    /// Background: no in-foreground retries while suspended.
    func appDidEnterBackground() {
        appActive = false
        retryTask?.cancel()
        retryTask = nil
    }

    /// Pull-to-refresh: the tail is stopped first (so nothing it delivers is
    /// marked seen and then lost), page 1 is loaded from scratch with own
    /// posts reloaded from local storage, and a new tail starts from the new
    /// page with the overlap.
    func refreshAndWait() async {
        guard hasLoaded else {
            activate()
            await loadTask?.value
            return
        }
        guard isActive, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let epoch = self.epoch
        stopTail()
        pageTask?.cancel()
        pageTask = nil
        recipeTask?.cancel()
        recipeTask = nil
        await client.stopTail()
        await client.resetSeen()
        guard epoch == self.epoch else { return }
        await loadOwnLocalPosts()
        guard epoch == self.epoch else { return }
        let fresh = await fetchPages(first: true, epoch: epoch, refresh: true)
        guard fresh, epoch == self.epoch, isActive else { return }
        retryAttempt = 0
        startTail(since: tailAnchor() - FreshRelayClient.tailResumeOverlapSeconds)
        startSpecials()
    }

    // MARK: - Paging

    /// `currentIndex` is the appearing row's index in `rows`, which is what
    /// the list enumerates. Rows also hold the divider (and special cards),
    /// so the threshold counts the posts up to that row: comparing the row
    /// index with `posts.count` paged one post early per non-post row above.
    func loadMoreIfNeeded(currentIndex: Int) {
        guard let position = Self.postPosition(ofRow: currentIndex, in: rows),
              position >= posts.count - Self.loadMorePrefetch else { return }
        loadMore()
    }

    /// The 0-based position among posts of the post at `rowIndex`, or nil
    /// when that row is not a post (the divider, a special card) or is out
    /// of range.
    nonisolated static func postPosition(ofRow rowIndex: Int, in rows: [FreshDividedRow<FreshRow>]) -> Int? {
        guard rows.indices.contains(rowIndex),
              case .row(let row) = rows[rowIndex], !row.isSpecialCard else { return nil }
        return rows[..<rowIndex].reduce(0) { count, r in
            if case .row(let other) = r, !other.isSpecialCard { return count + 1 }
            return count
        }
    }

    func loadMore() {
        guard canPage else { return }
        isPaging = true
        let epoch = self.epoch
        pageTask = Task { [weak self] in
            _ = await self?.fetchPages(first: false, epoch: epoch)
            self?.pageTask = nil
        }
    }

    func loadMoreAndWait() async {
        loadMore()
        await pageTask?.value
    }

    private var canPage: Bool {
        isActive && hasLoaded && !isPaging && !refreshing && !finishLine.caughtUp && pageCursor != nil
    }

    private func loadFirstPage(epoch: Int) async {
        if visitMark == nil {
            visitMark = lastVisit.beginVisit(pubkey: pubkey, storage: visitStorage)
        }
        isLoading = true
        await loadOwnLocalPosts()
        guard epoch == self.epoch else { return }
        let applied = await fetchPages(first: true, epoch: epoch)
        guard applied, epoch == self.epoch else { return }
        isLoading = false
        loadTask = nil
        if isActive {
            startTail(since: tailAnchor())
            startSpecials()
        }
    }

    /// One page, then more while a full page added no visible row (bounded,
    /// and only while the cursor moves back). Returns false when abandoned.
    /// A refresh (`refresh`) that fails or times out keeps the list as it
    /// was: only an answered page (or the floor) replaces it.
    private func fetchPages(first: Bool, epoch: Int, refresh: Bool = false) async -> Bool {
        var replace = first
        var hops = 0
        while true {
            await pendingClose?.value
            guard epoch == self.epoch, !Task.isCancelled else { return false }
            let previousCursor = replace ? nil : pageCursor
            let answer = await client.feedPage(until: replace ? nil : pageCursor)
            guard epoch == self.epoch, !Task.isCancelled else { return false }

            let answered = answer.outcome == .answered || answer.outcome == .floor
            if replace && refresh && !answered {
                // Failed / timed-out / refused refresh: keep what is shown.
                // Posts that did arrive are already marked seen by the
                // client, so the restarted tail won't send them again: they
                // wait behind the pill instead of being lost.
                holdBehindPill(answer.events.filter(accept))
                persist(answer.events.filter(accept))
                // The refresh cancelled an unfinished recipe load; a kept
                // finish line needs its row.
                if finishLine.caughtUp && !recipesLoaded { startRecipes() }
                isPaging = false
                return true
            }
            let accepted = answer.events.filter(accept)
            if replace {
                let incoming = collapseEdits(accepted, replacing: false)
                relayPosts = FreshSpacing.spaceAuthors(before: [], incoming: incoming)
                pageCursor = nil
                finishLine = .none
                if refresh {
                    // The new page holds what the pill was holding; anything
                    // newer comes again on the tail, which restarts with the
                    // overlap.
                    pendingNew = []
                    newPostsCount = 0
                    pillDismissedAt = 0
                    resetSlotsForRefresh()
                }
            }
            let shownIds = Set(relayPosts.map(\.id))
            let incoming = replace ? [] : collapseEdits(accepted.filter { !shownIds.contains($0.id) }, replacing: true)
            if !replace {
                relayPosts += FreshSpacing.spaceAuthors(before: relayPosts, incoming: incoming)
            }
            if let oldest = answer.events.map(\.createdAt).min() { pageCursor = oldest }
            persist(accepted)

            if first && replace {
                hasLoaded = true
                switch answer.outcome {
                case .answered, .floor: loadFailed = false
                case .invalid, .failed, .timedOut: loadFailed = answer.events.isEmpty
                }
            }
            let reachedEnd: Bool
            switch answer.outcome {
            case .floor: reachedEnd = true
            case .answered: reachedEnd = answer.isShortPage
            case .invalid, .failed, .timedOut: reachedEnd = false
            }
            let added = replace ? relayPosts.count : incoming.count
            replace = false
            emit()

            if reachedEnd {
                reachEnd()
                break
            }
            let cursorMoved = pageCursor.map { new in previousCursor.map { new < $0 } ?? true } ?? false
            hops += 1
            guard answer.outcome == .answered, added == 0, cursorMoved, hops <= Self.maxEmptyPageHops else { break }
        }
        isPaging = false
        return true
    }

    private func reachEnd() {
        finishLine = .of(reached: true)
        // Own posts older than the last page are placed once the end is
        // reached, so the list is rebuilt here.
        emit()
        if !recipesLoaded { startRecipes() }
    }

    private func startRecipes() {
        guard isActive, recipeTask == nil else { return }
        let epoch = self.epoch
        recipeTask = Task { [weak self] in
            await self?.loadRecipes(epoch: epoch)
        }
    }

    private func loadRecipes(epoch: Int) async {
        await pendingClose?.value
        guard epoch == self.epoch, !Task.isCancelled else { return }
        let answer = await client.recipes()
        guard epoch == self.epoch, !Task.isCancelled else { return }
        let rules = self.rules()
        var byCoordinate: [String: NostrEvent] = [:]
        let ceiling = now() + FreshRelayClient.futureSkewSeconds
        for event in answer.events where FreshPosts.isRecipe(kind: event.kind, tags: event.tags) {
            // The feed's rules, minus the old-edit rule (recipes keep old
            // edits): reader filters, local hides, deletions, future dates.
            guard FreshPosts.passesReaderFilters(event, rules: rules), !isHiddenLocally(event),
                  !isDeleted(event), event.createdAt <= ceiling else { continue }
            let coordinate = RecipeRepository.coordinate(event)
            if let kept = byCoordinate[coordinate], kept.createdAt >= event.createdAt { continue }
            byCoordinate[coordinate] = event
        }
        // Kept beyond the row's limit so recipes excluded for being in the
        // feed leave room for others.
        let all = FreshRelayClient.newestFirst(Array(byCoordinate.values))
        recipePool = Array(all.prefix(Self.recipePoolLimit))
        recipesLoaded = answer.outcome == .answered
        recipeTask = nil
        observeProfiles(in: recipePool)
        if specialsEnabled {
            boxPool = FreshRecipeBox.buildPool(all, now: now())
            observeProfiles(in: boxPool)
            decideSlots()
        }
    }

    // MARK: - Tail

    private func startTail(since: Int) {
        stopTail()
        let client = self.client
        let epoch = self.epoch
        let close = pendingClose
        tailStatus = .live
        tailTask = Task { [weak self] in
            await close?.value
            guard let self, epoch == self.epoch, self.isActive, !Task.isCancelled else { return }
            let stream = await client.liveTail(since: since)
            for await update in stream {
                guard !Task.isCancelled, epoch == self.epoch else { return }
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

    /// The newest relay post, clamped to now + skew: a future-dated post must
    /// not start a tail days ahead and miss everything until then.
    private func tailAnchor() -> Int {
        let ceiling = now() + FreshRelayClient.futureSkewSeconds
        return min(relayPosts.map(\.createdAt).max() ?? now(), ceiling)
    }

    private func reviveOrRestartTail() {
        switch tailStatus {
        case .lost:
            let client = self.client
            let epoch = self.epoch
            Task { [weak self] in
                let revived = await client.reviveTail()
                guard let self, epoch == self.epoch, self.isActive else { return }
                if !revived { self.startTail(since: self.tailAnchor() - FreshRelayClient.tailResumeOverlapSeconds) }
            }
        case .ended, .idle:
            startTail(since: tailAnchor() - FreshRelayClient.tailResumeOverlapSeconds)
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
            persist([event])
            // Held behind the pill: nothing moves until the reader taps it.
            holdBehindPill([event])
        case .lost:
            tailStatus = .lost
            scheduleTailRetry()
        case .revived:
            tailStatus = .live
        case .ended:
            tailStatus = .ended
        }
    }

    /// The optimistic "publishing" row is shown only for kinds Fresh keeps
    /// (notes, long-form, polls): a gallery post (20/21/22) would vanish
    /// when its published event arrives, since Fresh can't pin it.
    nonisolated static func showsPendingRow(kind: Int) -> Bool {
        FreshPosts.feedKinds.contains(kind)
    }

    /// Queue posts behind the pill, skipping any already shown or waiting.
    private func holdBehindPill(_ events: [NostrEvent]) {
        for event in events
        where !relayPosts.contains(where: { $0.id == event.id })
            && !pendingNew.contains(where: { $0.id == event.id }) {
            pendingNew.append(event)
        }
        newPostsCount = pendingNew.count
    }

    /// The pill was tapped: the waiting posts go into the list (a new post on
    /// top, a late-admitted one at its time, an edit in its row). The view
    /// scrolls to the top in the same tap.
    func showNewPosts() {
        let waiting = pendingNew.filter { accept($0) }
        pendingNew = []
        newPostsCount = 0
        pillDismissedAt = 0
        for event in waiting {
            if event.kind == 30023, replaceEdit(event) { continue }
            let index = relayPosts.firstIndex { $0.createdAt < event.createdAt } ?? relayPosts.endIndex
            relayPosts.insert(event, at: index)
        }
        emit()
    }

    /// The pill's close button: the pill hides until another post arrives;
    /// the waiting posts stay waiting (still not inserted under the reader).
    func dismissNewPostsPill() {
        pillDismissedAt = newPostsCount
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
        let epoch = self.epoch
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, epoch == self.epoch else { return }
            self.retryTask = nil
            guard self.isActive, self.appActive, self.tailStatus == .lost else { return }
            _ = await client.reviveTail()
        }
    }

    // MARK: - Ingest

    private func accept(_ event: NostrEvent) -> Bool {
        guard FreshPosts.feedKinds.contains(event.kind) else { return false }
        // Dated more than the app's skew ahead: dropped (ruling 2026-11-10).
        guard event.createdAt <= now() + FreshRelayClient.futureSkewSeconds else { return false }
        guard !isDeleted(event) else { return false }
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

    /// Long-form edits share a coordinate: keep the newest per coordinate
    /// within the incoming page, and (when `replacing`) against what is
    /// already shown, where an older row is replaced in place.
    private func collapseEdits(_ incoming: [NostrEvent], replacing: Bool) -> [NostrEvent] {
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
                if replacing, replaceEdit(event) { continue }
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
        if relayPosts[i].createdAt < event.createdAt {
            renameAnchor(relayPosts[i].id, to: event.id)
            relayPosts[i] = event
        }
        return true
    }

    // MARK: - Own posts

    /// The user's own public, signed post in the window that passes the
    /// filters. A private reply is persisted and broadcast as an unsigned
    /// synthetic kind 1 (`PrivateReplyPublisher`); it must never show here.
    private func isOwnCandidate(_ event: NostrEvent, floor: Int) -> Bool {
        event.pubkey == pubkey
            && FreshPosts.feedKinds.contains(event.kind)
            && event.createdAt >= floor
            && !event.sig.isEmpty
            && !isPrivate(event.id)
            && Self.isTopLevel(event)
            && accept(event)
    }

    /// A note that replies to nothing (NIP-10, mentions ignored). Own replies
    /// are never pinned: they belong to their thread. Long-form and polls
    /// are always top-level.
    nonisolated static func isTopLevel(_ event: NostrEvent) -> Bool {
        guard event.kind == 1 else { return true }
        return Nip10.replyTarget(of: event) == nil
    }

    /// Reload own posts from the event store (activation and refresh). This
    /// is also how a recipe published from the editor arrives: the recipe
    /// publisher persists it but posts no `.nostrEventPublished`.
    private func loadOwnLocalPosts() async {
        let floor = now() - FreshPosts.freeWindowSeconds
        let local = await ownLocalPosts()
        for event in local where isOwnCandidate(event, floor: floor) {
            ownPosts[event.id] = event
        }
    }

    private func observeOwnPublishes() {
        guard publishObserver == nil else { return }
        publishObserver = center.addObserver(forName: .nostrEventPublished, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? NostrEvent else { return }
            let isPrivate = note.userInfo?["isPrivate"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard !isPrivate else { return }
                self?.insertOwnPublished(event)
            }
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

    /// A deletion the app just recorded (`DeletionSender`, after the kind 5
    /// is published): the post goes at once, own pinned posts included.
    private func observeDeletions() {
        guard deletionObserver == nil else { return }
        deletionObserver = center.addObserver(forName: .eventDeletionRecorded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropDeleted() }
        }
    }

    func dropDeleted() {
        relayPosts.removeAll(where: isDeleted)
        pendingNew.removeAll(where: isDeleted)
        newPostsCount = pendingNew.count
        pillDismissedAt = min(pillDismissedAt, newPostsCount)
        ownPosts = ownPosts.filter { !isDeleted($0.value) }
        recipePool.removeAll(where: isDeleted)
        boxPool.removeAll(where: isDeleted)
        filterCards(dropping: isDeleted)
        emit()
    }

    /// Instant hide for block and report (`ContentHide.broadcast`).
    func dropHidden(eventIds: Set<String>, pubkeys: Set<String>, coordinates: Set<String>) {
        guard !eventIds.isEmpty || !pubkeys.isEmpty || !coordinates.isEmpty else { return }
        hiddenIds.formUnion(eventIds)
        hiddenPubkeys.formUnion(pubkeys.map { $0.lowercased() })
        hiddenCoordinates.formUnion(coordinates)
        relayPosts.removeAll(where: isHiddenLocally)
        pendingNew.removeAll(where: isHiddenLocally)
        newPostsCount = pendingNew.count
        pillDismissedAt = min(pillDismissedAt, newPostsCount)
        ownPosts = ownPosts.filter { !isHiddenLocally($0.value) }
        recipePool.removeAll(where: isHiddenLocally)
        boxPool.removeAll(where: isHiddenLocally)
        filterCards(dropping: isHiddenLocally)
        emit()
    }

    // MARK: - Emit

    private func emit() {
        let floor = now() - FreshPosts.freeWindowSeconds
        let oldestRelay = relayPosts.map(\.createdAt).min()
        var merged = relayPosts
        var shownIds = Set(merged.map(\.id))
        var rowByCoordinate: [String: Int] = [:]
        for (i, event) in merged.enumerated() where event.kind == 30023 {
            rowByCoordinate[RecipeRepository.coordinate(event)] = i
        }

        // Own posts the relay didn't return, within the window, and not older
        // than what is loaded (unless the end is reached), newest first.
        // Long-form: one per coordinate, the newest of own and relay copies.
        var candidates = ownPosts.values
            .filter { !shownIds.contains($0.id) && $0.createdAt >= floor && !isDeleted($0) }
            .filter { own in finishLine.caughtUp || oldestRelay.map { own.createdAt >= $0 } ?? true }
            .sorted { $0.createdAt > $1.createdAt }
        var seenOwnCoordinates: Set<String> = []
        candidates = candidates.filter { own in
            guard own.kind == 30023 else { return true }
            let c = RecipeRepository.coordinate(own)
            guard seenOwnCoordinates.insert(c).inserted else { return false }  // an older own edit
            if let row = rowByCoordinate[c] {
                if merged[row].createdAt < own.createdAt {
                    renameAnchor(merged[row].id, to: own.id)
                    merged[row] = own
                }
                return false
            }
            return true
        }
        for own in candidates {
            let index = merged.firstIndex { $0.createdAt < own.createdAt } ?? merged.endIndex
            merged.insert(own, at: index)
            shownIds.insert(own.id)
        }
        let previous = posts.map(\.id)
        posts = merged
        observeProfiles(in: merged)
        if !placedSlots.isEmpty {
            // Posts that left the list (reported, blocked, deleted): their
            // cards move up to the post above (S1 `reanchor`).
            let removed = Set(previous).subtracting(merged.map(\.id))
            if !removed.isEmpty {
                placedSlots = FreshSpecials.reanchor(placedSlots, order: previous, removed: removed)
            }
        }
        decideSlots()

        // The newest row shown is the next visit's mark (own posts and edits
        // included), clamped like the tail anchor.
        if isActive, appActive, let newest = merged.map(\.createdAt).max() {
            let ceiling = now() + FreshRelayClient.futureSkewSeconds
            lastVisit.recordNewest(min(newest, ceiling), pubkey: pubkey, storage: visitStorage)
        }
    }

    // MARK: - Special cards (FeatureFlags.freshSpecialsEnabled)

    /// A post row appeared (the list's `onAppear`): paging, and how far down
    /// the reader is, which decides the special-card slots.
    func postAppeared(rowIndex: Int) {
        let rows = self.rows
        if let position = Self.postPosition(ofRow: rowIndex, in: rows),
           position >= posts.count - Self.loadMorePrefetch {
            loadMore()
        }
        guard specialsEnabled, rows.indices.contains(rowIndex),
              case .row(let row) = rows[rowIndex], let event = row.event else { return }
        let index = postIndex()
        let deepest = deepestSeenId.flatMap { index[$0] } ?? -1
        if let at = index[event.id], at > deepest {
            deepestSeenId = event.id
            decideSlots()
        }
    }

    /// A card appeared: it counts as shown for this account (web marks a
    /// spotlight when half of it is on screen and a box recipe as it nears
    /// the screen; here, when the row appears). Once per card.
    func cardAppeared(key: String) {
        guard specialsEnabled, recordedCards.insert(key).inserted,
              let special = placedSlots.first(where: { $0.key == key })?.special else { return }
        let now = now()
        switch special {
        case .recipe(let recipe):
            specialsStore.markRecipeBoxSeen(FreshRecipeBox.address(recipe), now: now)
        case .spotlight(let topic, let posts):
            specialsStore.markShown(posts.map(\.id), now: now)
            specialsStore.markTopicShown(topic.slug, now: now)
        }
    }

    /// Create the spotlight loader once, and keep one spotlight ready while
    /// the feed is shown.
    private func startSpecials() {
        guard specialsEnabled, isActive else { return }
        if spotlights == nil {
            let client = self.client
            let preview = topicPreview ?? { slug in await client.topicPreview(slug: slug) }
            spotlights = FreshSpotlightLoader(.init(
                preview: preview,
                topics: topicGroups,
                accept: { [weak self] in self?.accept($0) ?? false },
                shown: { [weak self] in self?.shownSpotlightIds() ?? [] },
                exclude: { [weak self] in self?.onScreenIds() ?? [] },
                topicHistory: { [weak self] in self?.specialsStore.loadTopicHistory() ?? [:] },
                rng: specialsRng,
                schedule: specialsSchedule ?? FreshSpotlightLoader.taskTimer,
                onChange: { [weak self] in self?.spotlightChanged() },
                // Never while the feed isn't shown: its socket is closed.
                enabled: { [weak self] in (self?.specialsEnabled ?? false) && (self?.isActive ?? false) }
            ))
        }
        if !recipesLoaded { startRecipes() }
        spotlights?.kick()
        decideSlots()
    }

    /// Async form for tests: build a spotlight now and decide slots.
    func prepareSpotlightAndWait() async {
        await spotlights?.prepare()
    }

    /// Topics the spotlights used this session (tests).
    var spotlightUsedTopics: Set<String> { spotlights?.usedTopics ?? [] }

    /// The loader finished a build: ask for the ready spotlight's profiles
    /// now (before it is placed), then decide slots.
    private func spotlightChanged() {
        if case .spotlight(_, let posts)? = spotlights?.ready {
            observeSpotlightProfiles(posts)
        }
        decideSlots()
    }

    private func shownSpotlightIds() -> Set<String> {
        Set(specialsStore.loadShown(now: now()).keys)
    }

    /// Posts on screen or waiting behind the pill, and every post in a card.
    private func onScreenIds() -> Set<String> {
        var ids = Set(posts.map(\.id))
        ids.formUnion(pendingNew.map(\.id))
        for slot in placedSlots {
            switch slot.special {
            case .recipe(let e)?: ids.insert(e.id)
            case .spotlight(_, let ps)?: ids.formUnion(ps.map(\.id))
            case nil: break
            }
        }
        return ids
    }

    private func postIndex() -> [String: Int] {
        var index: [String: Int] = [:]
        for (i, e) in posts.enumerated() where index[e.id] == nil { index[e.id] = i }
        return index
    }

    /// Decide every slot that has come within reach (`slotDecideAhead`
    /// posts below the deepest post shown), in order. A slot the reader has
    /// already reached is skipped; one far below waits for the rotation's
    /// own type; nothing ready near the screen waits too (until it's reached).
    /// After the first card, slots keep their spacing from the card above,
    /// so posts inserted at the top (the pill) don't squeeze two cards
    /// together.
    private func decideSlots() {
        guard specialsEnabled, isActive, hasLoaded, !posts.isEmpty else { return }
        let anchors = slotPlan.upTo(posts.count)
        let index = postIndex()
        let reader = deepestSeenId.flatMap { index[$0] } ?? -1
        while placedSlots.count < anchors.count {
            let k = placedSlots.count
            let anchorIndex: Int
            if k > 0, let last = placedSlots.last, let lastIndex = index[last.anchorId] {
                anchorIndex = lastIndex + (anchors[k] - anchors[k - 1])
            } else {
                anchorIndex = anchors[k] - 1
            }
            guard anchorIndex < posts.count else { break }
            let distance = anchorIndex - reader
            var special: FreshSpecial?
            if distance > 0 {
                guard distance <= Self.slotDecideAhead else { break }
                let strict = distance > Self.slotNearPosts
                guard let type = rotation.choose(
                    ready: { [self] in $0 == .recipe ? nextBoxRecipe() != nil : spotlights?.ready != nil },
                    strict: strict,
                    available: { [self] in
                        $0 == .recipe
                            ? nextBoxRecipe() != nil || (strict && recipeTask != nil)
                            : spotlights?.isAvailable(strict: strict) ?? false
                    }
                ), let taken = take(type) else { break }
                special = taken
                rotation.record(type)
            }
            placedSlots.append(FreshPlacedSlot(key: "sp:\(slotSerial)", anchorId: posts[anchorIndex].id, special: special))
            slotSerial += 1
        }
    }

    private func take(_ type: FreshSpecialType) -> FreshSpecial? {
        switch type {
        case .recipe:
            guard let recipe = nextBoxRecipe() else { return nil }
            boxTaken.insert(FreshRecipeBox.address(recipe))
            return .recipe(recipe)
        case .spotlight:
            return spotlights?.take()
        }
    }

    /// A random older recipe this account hasn't been shown, not taken this
    /// session, and not in the feed (by id or coordinate). The box picks
    /// first and the finish-line row leaves out what it took
    /// (`recipePicks`), so the two never show the same recipe and a recipe
    /// never leaves a row the reader may already see.
    private func nextBoxRecipe() -> NostrEvent? {
        guard !boxPool.isEmpty else { return nil }
        let seen = Set(specialsStore.loadRecipeBoxSeen(now: now()).keys)
        var excluding = Set(posts.map(\.id))
        excluding.formUnion(posts.filter { $0.kind == 30023 }.map(FreshRecipeBox.address))
        return FreshRecipeBox.pickRandom(boxPool, seen: seen, taken: boxTaken, excluding: excluding, random: specialsRng)
    }

    /// A refresh: new slots for the new page, and recipes the box took go back
    /// (web `loadFirst`). The rotation and the used topics carry on.
    private func resetSlotsForRefresh() {
        placedSlots = []
        boxTaken = []
        slotPlan = FreshSlots(rng: specialsRng)
        deepestSeenId = nil
    }

    /// An edit replaced a post in its row: a card anchored on it stays.
    private func renameAnchor(_ old: String, to new: String) {
        guard old != new, placedSlots.contains(where: { $0.anchorId == old }) else { return }
        placedSlots = placedSlots.map {
            guard $0.anchorId == old else { return $0 }
            var slot = $0
            slot.anchorId = new
            return slot
        }
    }

    /// Reported, blocked or deleted: a recipe card goes; a spotlight loses
    /// that post at once and goes when none is left. The slot stays decided.
    private func filterCards(dropping drop: (NostrEvent) -> Bool) {
        guard !placedSlots.isEmpty else { return }
        placedSlots = placedSlots.map { slot in
            switch slot.special {
            case .recipe(let e)? where drop(e):
                return FreshPlacedSlot(key: slot.key, anchorId: slot.anchorId, special: nil)
            case .spotlight(let topic, let ps)?:
                let kept = ps.filter { !drop($0) }
                if kept.count == ps.count { return slot }
                return FreshPlacedSlot(key: slot.key, anchorId: slot.anchorId,
                                       special: kept.isEmpty ? nil : .spotlight(topic, posts: kept))
            default:
                return slot
            }
        }
    }

    // MARK: - Profiles

    private func observeProfiles(in events: [NostrEvent]) {
        for pk in Set(events.map(\.pubkey)) where profiles[pk] == nil {
            if let cached = profileSource.cached(pk) { profiles[pk] = cached }
        }
        profileSource.observe(events)
    }

    /// Spotlight posts: their authors and everyone their text mentions
    /// (`referencedAuthorPubkeys`, the same set `MissingProfileWatcher`
    /// fetches), so a tile shows names and avatars rather than short npubs.
    /// Profiles that arrive later reach `profiles` through `updates()`.
    private func observeSpotlightProfiles(_ posts: [NostrEvent]) {
        for pk in Set(posts.flatMap(\.referencedAuthorPubkeys)) where profiles[pk] == nil {
            if let cached = profileSource.cached(pk) { profiles[pk] = cached }
        }
        profileSource.observe(posts)
    }

    private func ensureProfileUpdates() {
        guard profileUpdatesTask == nil else { return }
        let source = profileSource
        profileUpdatesTask = Task { @MainActor [weak self] in
            for await pk in source.updates() {
                guard let self else { return }
                if let p = source.cached(pk) { self.profiles[pk] = p }
            }
        }
    }
}
