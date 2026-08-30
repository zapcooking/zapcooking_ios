import Foundation
import Observation

/// The Recipes tab — a thin observer over ``RecipeRepository``.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.5 + §7.4 + §4.1):
/// - One-shot ``start()``. SwiftUI re-runs `.task` on state changes; a second
///   call is a no-op so an identical filter never re-hits the same connection
///   (99 events, then 0 twelve seconds later).
/// - Pull-to-refresh is the only re-query path.
/// - The repository paints ObjectBox before any relay is contacted. This type
///   does not query relays, does not dedupe, and does not own an error
///   surface — a silent union is not an error.
@Observable
@MainActor
final class RecipeFeedViewModel {

    /// Prefetch margin (in tiles) for scroll-end pagination — fire the next
    /// page once a visible tile is within this many items of the end.
    /// Matches Android `LOAD_MORE_PREFETCH`.
    static let loadMorePrefetch = 6

    /// Not ignored: the view reads ``events`` / ``isLoading`` / ``hasLoaded``
    /// through this, so Observation must see the repository mutate.
    private let repository: RecipeRepository
    @ObservationIgnored private var started = false

    init(repository: RecipeRepository? = nil) {
        self.repository = repository ?? RecipeRepository.shared
    }

    /// Deduped, mute-filtered events. The card parses title / image from tags.
    var events: [NostrEvent] { repository.recipes }

    var isLoading: Bool { repository.isLoading }

    /// True once a load has completed, whatever the event count.
    var hasLoaded: Bool { repository.hasLoaded }

    /// Still fetching the first window, and nothing is on screen yet.
    /// Distinct from ``isEmpty`` — a slow union must not look like
    /// "no recipes yet."
    var isAwaitingFirstPaint: Bool { events.isEmpty && !hasLoaded }

    /// A completed load that found nothing. Only this state shows
    /// "No recipes yet."
    var isEmpty: Bool { events.isEmpty && hasLoaded }

    /// One-shot. Cache-seed + first query live inside ``RecipeRepository/load()``.
    func start() {
        guard !started else { return }
        started = true
        repository.load()
    }

    func refresh() async {
        repository.refresh()
        await repository.inFlight?.value
    }

    func loadMore() {
        repository.loadMore()
    }

    /// Scroll-end trigger. Safe to call from every visible tile — the
    /// repository is single-flight and no-ops while a job is running.
    func loadMoreIfNeeded(currentIndex: Int, total: Int) {
        guard total > 0, currentIndex >= total - Self.loadMorePrefetch else { return }
        loadMore()
    }
}
