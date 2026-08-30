import SwiftUI

/// Concern 1.6 — one gate for every kind-30023 tap.
///
/// `RecipeParser.isRecipe` chooses the recipe reader; anything else (including
/// a missing event) opens the article reader. The cache-miss guard is
/// deliberate: an empty `RecipeDetailView` is worse than a plain article, so
/// `event == nil` never pushes `RecipeRoute`.
///
/// Tap-site inventory (rewired through this type):
/// - `ArticleFeedPreview` — top-level kind-30023 card (home, search, profile,
///   hashtag / trending / list feeds, thread focal)
/// - `ArticleCardView` — `nostr:naddr1…` embed (`RichContentView`, article body)
/// - `QuotedNoteView` — `nevent`/`note1` quote whose resolved event is 30023
/// - Outer card wrappers that used to always push `ThreadRoute`: home-feed
///   `onTapGesture`, `SearchView`, `ProfileTabs` (notes / replies / conversation),
///   `HashtagFeedView`, `NoteListFeedView`, `PeopleListFeedView`, `TrendingFeedView`
/// - Notifications choke point: `MainView` `onNoteTap` looks the event up
///   before choosing a route
///
/// Not tap sites (left alone):
/// - `RecipeCardView` — already `RecipeRoute` (Recipes tab / tag feed)
/// - Profile gallery / media — kinds 20 / 21 / 22 only
/// - `wispApp.onOpenURL` — share-extension only; no article/recipe URL handler
/// - Search `naddr1` paste — NIP-50 text, not a dedicated open
enum ArticleTapRouting {
    /// Cache-miss guard: a missing event is never a recipe.
    static func opensAsRecipe(_ event: NostrEvent?) -> Bool {
        guard let event else { return false }
        return RecipeParser.isRecipe(event)
    }

    /// Push the long-form reader. Nil / evicted event → article fallback.
    static func appendLongForm(
        to path: inout NavigationPath,
        event: NostrEvent?,
        author: String,
        dTag: String,
        relayHints: [String] = []
    ) {
        if opensAsRecipe(event) {
            path.append(RecipeRoute(author: author, dTag: dTag))
        } else {
            path.append(ArticleRoute(author: author, dTag: dTag, relayHints: relayHints))
        }
    }

    /// Card-row tap: kind 30023 → recipe or article; everything else → thread.
    static func appendCardTap(to path: inout NavigationPath, event: NostrEvent) {
        if event.kind == RecipeParser.recipeKind {
            appendLongForm(
                to: &path,
                event: event,
                author: event.pubkey,
                dTag: RecipeParser.dTag(event)
            )
        } else {
            path.append(ThreadRoute(eventId: event.id, authorPubkey: event.pubkey))
        }
    }
}

/// Kind-30023 preview / embed: recipe when `isRecipe`, else article.
/// Passing `event: nil` is the cache-miss path and always uses `ArticleRoute`.
struct ArticleTapLink<Label: View>: View {
    let event: NostrEvent?
    let author: String
    let dTag: String
    var relayHints: [String] = []
    let label: Label

    init(
        event: NostrEvent?,
        author: String,
        dTag: String,
        relayHints: [String] = [],
        @ViewBuilder label: () -> Label
    ) {
        self.event = event
        self.author = author
        self.dTag = dTag
        self.relayHints = relayHints
        self.label = label()
    }

    var body: some View {
        if ArticleTapRouting.opensAsRecipe(event) {
            NavigationLink(value: RecipeRoute(author: author, dTag: dTag)) {
                label
            }
        } else {
            NavigationLink(value: ArticleRoute(author: author, dTag: dTag, relayHints: relayHints)) {
                label
            }
        }
    }
}

/// Outer feed/search/profile card: 30023 → recipe or article, else thread.
struct FeedEventNavigationLink<Label: View>: View {
    let event: NostrEvent
    let label: Label

    init(event: NostrEvent, @ViewBuilder label: () -> Label) {
        self.event = event
        self.label = label()
    }

    var body: some View {
        if event.kind == RecipeParser.recipeKind {
            ArticleTapLink(
                event: event,
                author: event.pubkey,
                dTag: RecipeParser.dTag(event)
            ) {
                label
            }
        } else {
            NavigationLink(value: ThreadRoute(eventId: event.id, authorPubkey: event.pubkey)) {
                label
            }
        }
    }
}
