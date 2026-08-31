import Foundation
import Observation

/// The recipe read path — the one place recipes are fetched, deduped and
/// cached. Feed, detail, and tag-feed surfaces consume this; none of
/// them should query relays or dedupe on its own.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.2):
/// - `{kinds:[30023], #t:[zapcooking, nostrcooking]}` fanned out to the
///   **articles union** (`RelayDefaults.articles`) — not the general article
///   path, which routes to the wrong relays, and not `indexers`, which is the
///   kind-0/3/10002 discovery pool.
/// - Deduped by addressable coordinate `kind:author:dTag`, newest `created_at`
///   wins, **lower event id wins on a tie** (NIP-01).
/// - `requestRecipe(author:dTag:)` resolves cache-first, then through the same
///   union with the same dedup — one code path.
/// - `HiddenRecipes` (exact coordinates + d-tag prefixes) is applied inside
///   ``deduped(_:)`` / ``requestRecipe(author:dTag:)`` / ``cached(author:dTag:)``
///   so feed, tag feed, detail, and search inherit one hide. Do not
///   re-filter in views.
/// - The **feed** paints from ObjectBox before any relay is contacted
///   (Concern 1.5 / §4.1). An empty union does not wipe that paint — the
///   grid is cache ∪ live and never shrinks below the cached set.
/// - The **tag feed** (Concern 1.7) is a separate session: same union,
///   `tagFeedFilter`, same mute-only / newest-wins rules, own submit path
///   so opening a category does not cancel the mounted Recipes tab.
///
/// **The dedup is not implemented here.** `dedupeAcrossFormats` (Concern 2.2)
/// already is this contract: its comparator is `rank desc, created_at desc,
/// id asc`, and with `RecipeFormats.active == [Nip23RecipeFormat()]` every
/// surviving event is kind 30023 and every rank is 0 — so its
/// `RecipeKey(author, slug)` is exactly `30023:author:dTag` and the comparator
/// collapses to `created_at desc, id asc`. Writing a second one here is the
/// drift this concern exists to prevent, and the second one would be the
/// untested one.
///
/// Filters and relay routing likewise come from the format seam
/// (`RecipeFormats.primary`), so the kind, the `#t` values and the paging
/// window have one definition.
///
/// §7 lessons that shaped this file:
/// - **§7.3** — filtering is **mute-only**. No spam scorer runs in this path;
///   Android's over-filtered legitimate food posts and an exception inside the
///   collector could cancel the whole stream.
/// - **§7.4** — load / refresh / pagination are serialized through one submit
///   path that cancels the previous job before issuing the next REQ, because
///   search relays rate-limit per connection (99 events, then 0 twelve seconds
///   later on an identical filter).
/// - **§7.2 / §7.5** — subscription identity and teardown are `RelayPool`'s
///   job and it already satisfies both: `queryDetailed` mints
///   `"q-" + UUID().prefix(8)` (process-wide unique — Kotlin's `AtomicInteger`
///   is that lesson's *mechanism*, not its requirement) and `deregister`
///   closes only the subIds it opened, on the relays it opened them on.
///   Nothing here re-implements either.
/// - **§7.7** — union coverage is uneven and a relay returning nothing is
///   normal, so queries wait for the whole union rather than the first
///   answer, and no relay's silence fails the query.
@Observable
@MainActor
final class RecipeRepository {

    /// Deduped recipe events, newest first. The feed renders this directly.
    private(set) var recipes: [NostrEvent] = []

    private(set) var isLoading = false

    /// True once a load has completed, whatever the event count. A
    /// legitimately empty result must not look like "never loaded" or the feed
    /// re-queries and gets throttled (§7.4).
    private(set) var hasLoaded = false

    /// Independent category-feed state. Browsing `#italian` must not
    /// rewrite ``recipes`` — the Recipes tab stays mounted (§7.4 / 1.5).
    private(set) var tagRecipes: [NostrEvent] = []
    private(set) var isTagLoading = false
    private(set) var hasTagLoaded = false
    private(set) var tagExhausted = false

    /// The slug ``loadTagFeed(tag:limit:)`` last started, already normalized.
    /// Internal so tests can assert a blank tag is a no-op.
    @ObservationIgnored private(set) var activeTag: String?

    @ObservationIgnored private var tagByCoordinate: [String: NostrEvent] = [:]

    @ObservationIgnored private(set) var tagInFlight: Task<Void, Never>?
    @ObservationIgnored private var tagSubmitGeneration = 0

    /// Every recipe event seen this session, keyed by addressable coordinate.
    /// This is what makes `requestRecipe` cache-first for anything the feed has
    /// already pulled.
    @ObservationIgnored private var byCoordinate: [String: NostrEvent] = [:]

    /// §7.4: the single submit path's in-flight job. Cancelled before the next
    /// REQ is issued.
    ///
    /// Internal rather than private purely so tests can await the submit path
    /// deterministically. Production callers observe ``isLoading``; nothing in
    /// the app should await or cancel this directly.
    @ObservationIgnored private(set) var inFlight: Task<Void, Never>?

    /// Bumped by every submit, so a job can tell whether it is still the
    /// current one when it finishes. See ``submit(_:)``.
    @ObservationIgnored private var submitGeneration = 0

    /// The recipe read union. Coverage is deliberately uneven — a relay
    /// returning nothing is normal — and that is not a failure.
    @ObservationIgnored private let relays: [String]

    @ObservationIgnored private let format: any RecipeFormat

    /// The mute predicate, injected for the same reason `relays` and `format`
    /// are: `MuteRepository.shared` is a singleton whose state is `private(set)`
    /// and written through UserDefaults and a relay republish, so without this
    /// the divergence between what is *held* and what is *shown* — the thing
    /// ``oldestHeldCreatedAt`` exists to keep separate — has no test that can
    /// fail.
    @ObservationIgnored private let isMuted: @MainActor (String) -> Bool

    /// Reporter-local hide (NIP-56). Injected so tests can assert a reported
    /// coordinate leaves the feed without touching `ReportedContent.shared`.
    @ObservationIgnored private let isReported: @MainActor (NostrEvent) -> Bool

    /// ObjectBox seed. Production (`shared`) reads kind-30023; tests inject
    /// a fixture so they stay hermetic and do not touch ObjectBox.
    @ObservationIgnored private let seedCache: () async -> [NostrEvent]

    /// Persist network results so the next cold launch can paint. Tests
    /// inject a no-op; production enqueues through `EventPersistQueue`.
    @ObservationIgnored private let persist: ([NostrEvent]) -> Void

    static let shared = RecipeRepository(
        seedCache: { await EventStore.shared.seedRecipes() },
        persist: { events in
            guard !events.isEmpty else { return }
            Task { await EventPersistQueue.shared.enqueue(events) }
        }
    )

    /// `format` / `isMuted` / `seedCache` / `persist` default in the body
    /// rather than as default arguments: default arguments are evaluated in
    /// the caller's context, and this module defaults to `MainActor`
    /// isolation, so naming an isolated static there is an error under Swift 6.
    ///
    /// The no-op seed / persist defaults keep `RecipeRepository(relays:)`
    /// hermetic for tests. Production goes through ``shared``.
    init(
        relays: [String] = RelayDefaults.articles,
        format: (any RecipeFormat)? = nil,
        isMuted: (@MainActor (String) -> Bool)? = nil,
        isReported: (@MainActor (NostrEvent) -> Bool)? = nil,
        seedCache: (() async -> [NostrEvent])? = nil,
        persist: (([NostrEvent]) -> Void)? = nil
    ) {
        self.relays = relays
        self.format = format ?? RecipeFormats.primary
        self.isMuted = isMuted ?? { MuteRepository.shared.isBlocked($0) }
        self.isReported = isReported ?? { ReportedContent.shared.isHidden($0) }
        self.seedCache = seedCache ?? { [] }
        self.persist = persist ?? { _ in }
    }

    // MARK: - Coordinate

    /// The addressable coordinate `kind:author:dTag`.
    ///
    /// d-tags are stored **raw** — real ones contain `(`, `)` and `/`, and
    /// callers URL-encode at route boundaries. Sanitizing here would break the
    /// join with the events relays actually return.
    nonisolated static func coordinate(kind: Int, author: String, dTag: String) -> String {
        "\(kind):\(author):\(dTag)"
    }

    nonisolated static func coordinate(_ event: NostrEvent) -> String {
        coordinate(kind: event.kind, author: event.pubkey, dTag: RecipeParser.dTag(event))
    }

    // MARK: - The one shared reduction

    /// Drop non-recipes, dedupe by addressable coordinate, order newest first.
    ///
    /// Delegates the dedup to `dedupeAcrossFormats` — see the type doc for why
    /// that function *is* this concern's contract rather than merely resembling
    /// it. Two things are added on top, and neither duplicates it:
    ///
    /// - **Ordering.** `dedupeAcrossFormats` returns first-insertion order,
    ///   which is relay arrival order. A feed needs newest-first, and the sort
    ///   carries the same `created_at desc, id asc` tiebreaker so two launches
    ///   that received the same events in different orders render identically.
    /// - **HiddenRecipes.** Exact coordinates and d-tag prefixes (the 2.3
    ///   live-publish leftovers) drop here so feed, tag feed, detail, and
    ///   search inherit one hide. Muting is still applied separately; see
    ///   ``visible(_:)``.
    ///
    /// Note this also *filters*: `dedupeAcrossFormats` drops any event no
    /// active format claims, and `Nip23RecipeFormat.matches` is
    /// `RecipeParser.isRecipe`, which requires the recipe markdown template as
    /// well as the kind and `#t`. A plain article carrying `#t zapcooking` is
    /// dropped here rather than in the view.
    static func deduped(_ events: [NostrEvent]) -> [NostrEvent] {
        dedupeAcrossFormats(events.filter { !HiddenRecipes.isHidden($0) }) { RecipeFormats.rankOf($0) }
            .sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                return a.id < b.id
            }
    }

    /// Mute-only visibility filter (§7.3). Separate from ``deduped(_:)`` so the
    /// dedup stays one path shared with `requestRecipe`, while the feed's
    /// visibility policy stays a policy — and so a direct recipe link is not
    /// silently resolved to nil by a mute.
    func visible(_ events: [NostrEvent]) -> [NostrEvent] {
        events.filter { !isMuted($0.pubkey) && !isReported($0) }
    }

    /// Re-apply ``visible(_:)`` to whatever is held. Called after a successful
    /// report so the Recipes tab and tag feeds drop the card immediately.
    func dropHidden() {
        recipes = visible(Self.deduped(Array(byCoordinate.values)))
        tagRecipes = visible(Self.deduped(Array(tagByCoordinate.values)))
    }

    // MARK: - Feed

    /// First load. Paints ObjectBox **before** the union is contacted, then
    /// merges the live window into the same coordinate map. No-op once loaded
    /// or while a job is already running — use ``refresh()`` to re-query,
    /// which is the only re-query path (§7.4).
    ///
    /// The `isLoading` half of the guard is load-bearing, not defensive: SwiftUI
    /// re-runs `.task` / `.onAppear` on state changes, and without it each
    /// re-run would cancel the in-flight job and issue an **identical filter on
    /// the same connection** — precisely the sequence that returned 99 events
    /// and then 0 twelve seconds later on Android.
    ///
    /// `reset` is false: a silent union (airplane mode, one empty relay) must
    /// not wipe the cache-seeded paint. The grid is cache ∪ live.
    func load(limit: Int = 50) {
        guard !hasLoaded, !isLoading else { return }
        submit {
            await self.paintFromCache()
            await self.fetchPage(until: nil, limit: limit, reset: false)
        }
    }

    /// Merge persisted recipes into ``recipes`` without marking the feed
    /// loaded and without opening a socket. Called as the first step of
    /// ``load(limit:)`` so the first paint is local.
    func paintFromCache() async {
        let cached = await seedCache()
        guard !Task.isCancelled, !cached.isEmpty else { return }
        ingest(cached, reset: false)
    }

    /// Pull-to-refresh: the one deliberate re-query. Merges — does not
    /// clear — so an empty union cannot blank a painted cache.
    func refresh(limit: Int = 50) {
        submit { await self.fetchPage(until: nil, limit: limit, reset: false) }
    }

    /// Page backwards in time from ``oldestHeldCreatedAt``. Scroll fires this
    /// repeatedly, so it yields to a job already in flight for the same reason
    /// ``load(limit:)`` does.
    func loadMore(limit: Int = 50) {
        guard !isLoading, let oldest = oldestHeldCreatedAt else { return }
        submit { await self.fetchPage(until: oldest, limit: limit, reset: false) }
    }

    /// The paging cursor: the oldest event **held**, not the oldest *shown*.
    ///
    /// Those are different values and the difference is load-bearing. `recipes`
    /// is `visible(merged)`, so `recipes.last` is the oldest event that survived
    /// the mute filter. Paging from that:
    ///
    /// - **degrades** as soon as a prolific author is blocked — `until` sits
    ///   newer than the true oldest held event, so every subsequent page
    ///   re-fetches ground already covered, and it worsens as the muted
    ///   fraction rises;
    /// - **strands the feed entirely** when page one filters to nothing.
    ///   `recipes` is empty, so the cursor is nil and `loadMore` returns at its
    ///   guard; `load` no-ops because `hasLoaded` is true; `refresh` re-fetches
    ///   page one with `until: nil` and filters it away again. Empty forever,
    ///   with no control that advances it, and it reads to the member as
    ///   "there are no recipes."
    ///
    /// The cursor is a fact about what we **fetched**; visibility is a fact
    /// about what we **display**. They must not be the same value, and they
    /// diverge exactly when a member has exercised a mute.
    ///
    /// Internal rather than private so the divergence has a test that can fail.
    var oldestHeldCreatedAt: Int? {
        byCoordinate.values.map(\.createdAt).min()
    }

    /// §7.4 / §7.5 — one submit path. The previous job is cancelled before the
    /// next REQ is issued, so a burst of state changes cannot fan out into
    /// parallel identical filters on the same connections.
    ///
    /// `isLoading` is raised **synchronously here**, not inside the job: the
    /// job body does not start until the current runloop turn yields, so a
    /// flag raised in there would still be false for every caller in that same
    /// turn and the callers' guards would not hold.
    ///
    /// Only the newest job lowers it. A cancelled predecessor resuming later
    /// must not report its successor as finished — that would unstick the
    /// callers' guards mid-query and let the re-issue happen anyway.
    private func submit(_ work: @escaping @MainActor () async -> Void) {
        inFlight?.cancel()
        submitGeneration += 1
        let generation = submitGeneration
        isLoading = true
        inFlight = Task { @MainActor in
            await work()
            if generation == self.submitGeneration { self.isLoading = false }
        }
    }

    /// The feed query, from the format seam rather than a literal here — so the
    /// kind, the `#t` values and the paging window have exactly one definition
    /// and a second format changes them in one place.
    func feedFilter(limit: Int, until: Int? = nil) -> NostrFilter {
        format.feedFilter(limit: limit, until: until)
    }

    private func fetchPage(until: Int?, limit: Int, reset: Bool) async {
        let filter = feedFilter(limit: limit, until: until)
        // `waitForAllRelays: true` is the code-level form of the uneven-union
        // rule. The default breaks shortly after the FIRST relay's EOSE, which
        // on a union whose coverage is uneven by design turns "one fast relay
        // answered" into the entire feed.
        let events = await RelayPool.query(
            relays: relays,
            filter: filter,
            timeout: 12,
            waitForAllRelays: true
        )

        // A cancelled job must not publish its results over a newer one.
        guard !Task.isCancelled else { return }

        ingest(events, reset: reset)
        persist(events.filter { !HiddenRecipes.isHidden($0) })
        hasLoaded = true
    }

    /// Fold events into the coordinate cache and republish the feed.
    ///
    /// Held and incoming events are merged through ``deduped(_:)`` — the same
    /// comparator, one call — rather than by letting the later write win. That
    /// distinction is the whole point on an uneven union: a page fetched with
    /// `until` can carry an **older** version of a coordinate already on
    /// screen, because the relay that answered this page never received the
    /// edit that a different relay served on the previous page. Overwriting by
    /// arrival order would replace the current recipe with a stale one and the
    /// symptom would be wrong content, not a crash.
    ///
    /// `reset` discards what is held first, so a refresh republishes the union
    /// as it is *now* instead of accumulating events no relay still serves.
    func ingest(_ events: [NostrEvent], reset: Bool = false) {
        let held = reset ? [] : Array(byCoordinate.values)
        let merged = Self.deduped(held + events)
        // `merged` is one event per coordinate already; the uniquing closure is
        // belt-and-braces and keeps the first, which is the canonical one.
        byCoordinate = Dictionary(
            merged.map { (Self.coordinate($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        recipes = visible(merged)
    }

    // MARK: - Single recipe

    /// Resolve one recipe by coordinate, cache-first, then through the same
    /// union and the same dedup.
    ///
    /// **There are exactly two sources here and that is the contract, not an
    /// omission.** ``byCoordinate`` is the cache; the articles union is the
    /// truth. Anything that resolves a recipe without going through
    /// ``deduped(_:)`` is a second resolution path with its own tiebreaker,
    /// which is the drift this concern exists to prevent.
    ///
    /// Two persistent stores are deliberately **not** consulted:
    ///
    /// - `EventStore.loadAddressable` resolves with `.max(by: createdAt)` and
    ///   **no lower-id tiebreaker** (`EventStore.swift:530`), so two stored
    ///   versions at equal `created_at` resolve by row order. It is also
    ///   persistent, written by ~20 other subsystems, and cleared only on
    ///   logout — and a hit would return without ever asking a relay. An
    ///   addressable event is *replaceable* by definition, so a store with no
    ///   revalidation cannot answer the only question this method asks: an
    ///   author fixes a wrong quantity and a reader whose device holds the old
    ///   copy keeps reading the wrong quantity until they log out. Reachable
    ///   exactly on the cold deep link — which is what an `naddr` share is.
    /// - `ArticleCache` fans out to a hardcoded relay list that is not the
    ///   articles union (it misses `relay.noswhere.com` and adds five relays
    ///   this union does not carry), and its `store()` keeps the
    ///   **first-seen** event when two relays disagree at equal `created_at` —
    ///   the exact nondeterminism the NIP-01 tiebreaker exists to remove.
    ///
    /// Offline resolution is a real thing to want, but it is a *fallback after*
    /// the union comes back empty, not a source consulted before it, and it
    /// needs a tiebreaker of its own. That is a different concern's design.
    func requestRecipe(author: String, dTag: String) async -> NostrEvent? {
        if HiddenRecipes.isHidden(kind: RecipeParser.recipeKind, pubkey: author, dTag: dTag) {
            return nil
        }
        let key = Self.coordinate(kind: RecipeParser.recipeKind, author: author, dTag: dTag)
        if ReportedContent.shared.isHidden(coordinate: key) { return nil }
        if let cached = byCoordinate[key] ?? tagByCoordinate[key] {
            return isReported(cached) ? nil : cached
        }

        let filter = format.coordinateFilter(author: author, dTag: dTag)
        let events = await RelayPool.query(
            relays: relays,
            filter: filter,
            timeout: 12,
            waitForAllRelays: true
        )

        guard let winner = Self.deduped(events).first(where: { Self.coordinate($0) == key }) else {
            return nil
        }
        if isReported(winner) { return nil }
        byCoordinate[key] = winner
        return winner
    }

    /// The cached event for a coordinate, without touching the network.
    /// Checks the main-feed map first, then the active tag session — so a
    /// card opened from a category feed is cache-first without moving the
    /// main feed's paging cursor.
    func cached(author: String, dTag: String) -> NostrEvent? {
        if HiddenRecipes.isHidden(kind: RecipeParser.recipeKind, pubkey: author, dTag: dTag) {
            return nil
        }
        let key = Self.coordinate(kind: RecipeParser.recipeKind, author: author, dTag: dTag)
        if ReportedContent.shared.isHidden(coordinate: key) { return nil }
        guard let cached = byCoordinate[key] ?? tagByCoordinate[key] else { return nil }
        return isReported(cached) ? nil : cached
    }

    // MARK: - Tag feed (Concern 1.7)

    /// Relay filter for one category, from the format seam — `#t` is
    /// `<root>-<tag>` for every recipe root (`zapcooking-italian`,
    /// `nostrcooking-italian`). The per-recipe slug tag collides with that
    /// shape on the wire; ``RecipeParser/matchesCategory(_:_:)`` drops those
    /// after the union answers.
    func tagFeedFilter(tag: String, limit: Int, until: Int? = nil) -> NostrFilter {
        format.tagFeedFilter(tag: tag, limit: limit, until: until)
    }

    /// Oldest event **held** on the tag session, not the oldest shown.
    /// Same mute-cursor reason as ``oldestHeldCreatedAt``.
    var oldestHeldTagCreatedAt: Int? {
        tagByCoordinate.values.map(\.createdAt).min()
    }

    /// Cache-first + union-backed category feed. Clears the previous tag
    /// session (a different chip is a different query) and paints matching
    /// ObjectBox / already-held events before any relay is contacted.
    ///
    /// Own submit path — must not cancel the main-feed job. The Recipes
    /// tab stays mounted while this screen is pushed.
    func loadTagFeed(tag: String, limit: Int = 50) {
        let normalized = RecipeTagCatalog.normalize(tag)
        guard !normalized.isEmpty else { return }

        activeTag = normalized
        tagExhausted = false
        hasTagLoaded = false
        tagByCoordinate = [:]
        tagRecipes = []

        submitTag {
            await self.paintTagFromCache(normalized)
            await self.fetchTagPage(tag: normalized, until: nil, limit: limit, reset: false)
        }
    }

    /// Pull-to-refresh for the active tag. Merges — an empty union must
    /// not blank a cache-painted grid.
    func refreshTagFeed(limit: Int = 50) {
        guard let tag = activeTag else { return }
        tagExhausted = false
        submitTag { await self.fetchTagPage(tag: tag, until: nil, limit: limit, reset: false) }
    }

    /// Page backwards from ``oldestHeldTagCreatedAt``.
    func loadMoreTagFeed(limit: Int = 50) {
        guard !isTagLoading, !tagExhausted, let tag = activeTag,
              let oldest = oldestHeldTagCreatedAt
        else { return }
        submitTag { await self.fetchTagPage(tag: tag, until: oldest, limit: limit, reset: false) }
    }

    /// Local ingest for the active tag. Does not mark the tag feed loaded
    /// and does not open a socket.
    func paintTagFromCache(_ tag: String) async {
        let cached = await seedCache()
        guard !Task.isCancelled, activeTag == tag else { return }
        let held = Array(byCoordinate.values)
        let matches = Self.deduped(cached + held).filter { RecipeParser.matchesCategory($0, tag) }
        guard !matches.isEmpty else { return }
        ingestTag(matches, reset: false)
    }

    /// Fold events into the tag session. Does **not** rewrite ``recipes``
    /// and does **not** move the main feed's paging cursor. Slug-only
    /// matches (`<root>-<dTag>` with no real category) are dropped.
    func ingestTag(_ events: [NostrEvent], reset: Bool = false) {
        guard let tag = activeTag else { return }
        let matching = events.filter { RecipeParser.matchesCategory($0, tag) }
        let held = reset ? [] : Array(tagByCoordinate.values)
        let merged = Self.deduped(held + matching)
        tagByCoordinate = Dictionary(
            merged.map { (Self.coordinate($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        tagRecipes = visible(merged)
    }

    private func submitTag(_ work: @escaping @MainActor () async -> Void) {
        tagInFlight?.cancel()
        tagSubmitGeneration += 1
        let generation = tagSubmitGeneration
        isTagLoading = true
        tagInFlight = Task { @MainActor in
            await work()
            if generation == self.tagSubmitGeneration { self.isTagLoading = false }
        }
    }

    private func fetchTagPage(tag: String, until: Int?, limit: Int, reset: Bool) async {
        let filter = tagFeedFilter(tag: tag, limit: limit, until: until)
        let heldBefore = Set(tagByCoordinate.keys)
        let events = await RelayPool.query(
            relays: relays,
            filter: filter,
            timeout: 12,
            waitForAllRelays: true
        )

        guard !Task.isCancelled, activeTag == tag else { return }

        let matched = events.filter { RecipeParser.matchesCategory($0, tag) }
        ingestTag(matched, reset: reset)
        persist(matched.filter { !HiddenRecipes.isHidden($0) })
        hasTagLoaded = true
        if until != nil {
            let added = tagByCoordinate.keys.contains { !heldBefore.contains($0) }
            if !added { tagExhausted = true }
        }
    }
}
