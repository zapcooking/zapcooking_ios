import Foundation
import Observation

/// The recipe read path — the one place recipes are fetched, deduped and
/// cached. `RecipeFeedView`, `RecipeDetailView` and `RecipeTagFeedView` all
/// consume this; none of them queries relays or dedupes on its own.
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

    static let shared = RecipeRepository()

    /// Deduped recipe events, newest first. The feed renders this directly.
    private(set) var recipes: [NostrEvent] = []

    private(set) var isLoading = false

    /// True once a load has completed, whatever the event count. A
    /// legitimately empty result must not look like "never loaded" or the feed
    /// re-queries and gets throttled (§7.4).
    private(set) var hasLoaded = false

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

    /// The recipe read union. Coverage is deliberately uneven — `nostr.wine`
    /// has probed at zero — and that is not a failure.
    @ObservationIgnored private let relays: [String]

    @ObservationIgnored private let format: any RecipeFormat

    /// `format` defaults to `RecipeFormats.primary`, resolved in the body rather
    /// than as a default argument: default arguments are evaluated in the
    /// caller's context, and this module defaults to `MainActor` isolation, so
    /// naming an isolated static there is an error under Swift 6.
    init(relays: [String] = RelayDefaults.articles, format: (any RecipeFormat)? = nil) {
        self.relays = relays
        self.format = format ?? RecipeFormats.primary
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
    /// - **Nothing else.** Muting is applied separately and deliberately not
    ///   here; see ``visible(_:)``.
    ///
    /// Note this also *filters*: `dedupeAcrossFormats` drops any event no
    /// active format claims, and `Nip23RecipeFormat.matches` is
    /// `RecipeParser.isRecipe`, which requires the recipe markdown template as
    /// well as the kind and `#t`. A plain article carrying `#t zapcooking` is
    /// dropped here rather than in the view.
    static func deduped(_ events: [NostrEvent]) -> [NostrEvent] {
        dedupeAcrossFormats(events) { RecipeFormats.rankOf($0) }
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
        let mutes = MuteRepository.shared
        return events.filter { !mutes.isBlocked($0.pubkey) }
    }

    // MARK: - Feed

    /// First load. No-op once loaded or while a job is already running — use
    /// ``refresh()`` to re-query, which is the only re-query path (§7.4).
    ///
    /// The `isLoading` half of the guard is load-bearing, not defensive: SwiftUI
    /// re-runs `.task` / `.onAppear` on state changes, and without it each
    /// re-run would cancel the in-flight job and issue an **identical filter on
    /// the same connection** — precisely the sequence that returned 99 events
    /// and then 0 twelve seconds later on Android.
    func load(limit: Int = 50) {
        guard !hasLoaded, !isLoading else { return }
        submit { await self.fetchPage(until: nil, limit: limit, reset: true) }
    }

    /// Pull-to-refresh: the one deliberate re-query.
    func refresh(limit: Int = 50) {
        submit { await self.fetchPage(until: nil, limit: limit, reset: true) }
    }

    /// Page backwards in time from the oldest event held. Scroll fires this
    /// repeatedly, so it yields to a job already in flight for the same reason
    /// ``load(limit:)`` does.
    func loadMore(limit: Int = 50) {
        guard !isLoading, let oldest = recipes.last?.createdAt else { return }
        submit { await self.fetchPage(until: oldest, limit: limit, reset: false) }
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
    /// Deliberately **not** `ArticleCache`: that path fans out to a hardcoded
    /// relay list that is not the articles union (it misses
    /// `relay.noswhere.com` and adds five relays this union does not carry),
    /// and its `store()` keeps the **first-seen** event when two relays
    /// disagree at equal `created_at` — the exact nondeterminism the NIP-01
    /// lower-id tiebreaker exists to remove.
    func requestRecipe(author: String, dTag: String) async -> NostrEvent? {
        let key = Self.coordinate(kind: RecipeParser.recipeKind, author: author, dTag: dTag)
        if let cached = byCoordinate[key] { return cached }

        if let stored = await EventStore.shared.loadAddressable(
            kind: RecipeParser.recipeKind, author: author, dTag: dTag
        ), RecipeParser.isRecipe(stored) {
            byCoordinate[key] = stored
            return stored
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
        byCoordinate[key] = winner
        return winner
    }

    /// The cached event for a coordinate, without touching the network.
    func cached(author: String, dTag: String) -> NostrEvent? {
        byCoordinate[Self.coordinate(kind: RecipeParser.recipeKind, author: author, dTag: dTag)]
    }
}
