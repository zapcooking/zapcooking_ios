import Foundation
import Observation

/// Category feed — a thin observer over ``RecipeRepository``'s tag session.
///
/// Contract (`ZAPCOOKING_IOS_BUILD.md` §Phase 1 / 1.7):
/// - Queries go through the repository's category filter. This type does
///   not open sockets, does not dedupe, and does not own an error surface.
/// - ``start()`` is a no-op while the shared tag session is already
///   this slug, so `.task` cannot re-issue the filter (§7.4). If a
///   deeper tag feed stole the session, ``activeTag`` has moved and
///   we reload — otherwise pop-back paints the wrong category.
/// - Pull-to-refresh is the only deliberate re-query path.
@Observable
@MainActor
final class RecipeTagFeedViewModel {

    static let loadMorePrefetch = 6

    private let repository: RecipeRepository

    let tag: String
    let tagInfo: RecipeTag

    init(tag: String, repository: RecipeRepository? = nil) {
        let normalized = RecipeTagCatalog.normalize(tag)
        self.tag = normalized
        self.tagInfo = RecipeTagCatalog.display(for: normalized)
        self.repository = repository ?? RecipeRepository.shared
    }

    var events: [NostrEvent] { repository.tagRecipes }

    var isLoading: Bool { repository.isTagLoading }

    var hasLoaded: Bool { repository.hasTagLoaded }

    var isAwaitingFirstPaint: Bool { events.isEmpty && !hasLoaded }

    var isEmpty: Bool { events.isEmpty && hasLoaded }

    func start() {
        guard !tag.isEmpty, repository.activeTag != tag else { return }
        repository.loadTagFeed(tag: tag)
    }

    func refresh() async {
        repository.refreshTagFeed()
        await repository.tagInFlight?.value
    }

    func loadMore() {
        repository.loadMoreTagFeed()
    }

    func loadMoreIfNeeded(currentIndex: Int, total: Int) {
        guard total > 0, currentIndex >= total - Self.loadMorePrefetch else { return }
        loadMore()
    }
}
