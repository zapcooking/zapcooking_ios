import Foundation

/// What the Fresh feed (`wss://feed.zap.cooking`, build spec §2 "Fresh feed
/// relay") shows. A port of web `src/lib/freshFeed/posts.ts`: the post kinds,
/// `isOldEdit` (unchanged) and the one question asked before showing a post.
/// Pure: the reader's rules come in as a `SafetyFilterSnapshot` value, so
/// nothing here reads a singleton.
///
/// Differences from web, all deliberate:
/// - Mutes are the iOS mute list (`SafetyFilterSnapshot`): blocked and
///   reported pubkeys, reported event ids, muted words, muted threads. iOS
///   has no hashtag mutes, so web's `#t` mute has nothing to read here.
/// - The hellthread rule is the iOS setting (`hellthreadFilterEnabled` +
///   threshold), read from the same snapshot.
/// - `HiddenRecipes` (dev / e2e recipes) is applied at ingest to every kind
///   30023, recipe-tagged or not; web applies its copy of the list elsewhere.
/// - Web's render helpers in the same file (time-ago, media URLs, quotes,
///   note links) are not ported: iOS renders through `ContentParser`.
nonisolated enum FreshPosts {

    /// The relay's free window: 14 days (web `FREE_WINDOW_SECONDS`).
    static let freeWindowSeconds = 14 * 24 * 60 * 60

    /// The kinds a Fresh feed request asks for (no 35000: build spec §2).
    static let feedKinds = [1, 30023, 1068]

    /// Lowercase recipe hashtags (web `RECIPE_TAGS`).
    static let recipeTags: Set<String> = ["zapcooking", "nostrcooking"]

    enum PostKind: Equatable, Sendable {
        case note, poll, recipe, article
    }

    /// Kind 35000, or a long-form post tagged as a Zap Cooking recipe (any case).
    static func isRecipe(kind: Int, tags: [[String]]) -> Bool {
        if kind == 35000 { return true }
        if kind != 30023 { return false }
        return tags.contains { $0.first == "t" && $0.count >= 2 && recipeTags.contains($0[1].lowercased()) }
    }

    static func postKind(kind: Int, tags: [[String]]) -> PostKind {
        if kind == 1068 { return .poll }
        if isRecipe(kind: kind, tags: tags) { return .recipe }
        if kind == 30023 { return .article }
        return .note
    }

    /// `published_at`, when the post has a sane one (finite, > 0 and within
    /// `Int`). Like web's `Number(v)`, a decimal value counts; it is
    /// truncated to seconds. ≠ web: a value too large for `Int` (`"1e100"`)
    /// is nil here; web keeps it, and either way it is not an old edit.
    static func publishedAt(tags: [[String]]) -> Int? {
        guard let tag = tags.first(where: { $0.first == "published_at" }), tag.count >= 2 else { return nil }
        let raw = tag[1].trimmingCharacters(in: .whitespaces)
        guard let n = Double(raw), n.isFinite, n > 0 else { return nil }
        return Int(exactly: n.rounded(.towardZero))
    }

    /// A long-form post first published before the free window and edited
    /// since: an edit, not a new post. Kept out of the newest-first feed (the
    /// recipe row shows old recipes). `now` in seconds. Ported unchanged.
    static func isOldEdit(kind: Int, tags: [[String]], now: Int) -> Bool {
        if kind != 30023 && kind != 35000 { return false }
        guard let p = publishedAt(tags: tags) else { return false }
        return p < now - freeWindowSeconds
    }

    static func isOldEdit(_ e: NostrEvent, now: Int) -> Bool {
        isOldEdit(kind: e.kind, tags: e.tags, now: now)
    }

    /// Dropped at ingest whatever the reader's rules: a dev / e2e long-form
    /// post on the shared `HiddenRecipes` list.
    static func isHiddenAtIngest(_ e: NostrEvent) -> Bool {
        e.kind == 30023 && HiddenRecipes.isHidden(e)
    }

    /// The one question before showing a Fresh post in the newest-first feed.
    /// Mutes, reports and the hellthread rule always apply; OnlyFood's food
    /// test and hashtag cap don't (the relay is curated). `rules` nil means
    /// no mute list is loaded: nothing is muted.
    static func passesFreshFilters(_ e: NostrEvent, rules: SafetyFilterSnapshot?, now: Int) -> Bool {
        if !passesReaderFilters(e, rules: rules) { return false }
        if isOldEdit(e, now: now) { return false }
        return true
    }

    /// The reader's own rules only, plus `HiddenRecipes`: for recipe-row
    /// picks, which keep old edits.
    static func passesReaderFilters(_ e: NostrEvent, rules: SafetyFilterSnapshot?) -> Bool {
        if isHiddenAtIngest(e) { return false }
        guard let rules else { return true }
        if isMuted(e, by: rules) { return false }
        if rules.hellthreadFilterEnabled && e.isHellthread(threshold: rules.hellthreadThreshold) {
            return false
        }
        return true
    }

    /// Web `isEventMutedBy`, on the iOS mute list. A muted thread id hides the
    /// event itself and anything whose `e` tags name it (iOS `SafetyFilter`
    /// checks the `e` tags; web also checks the event's own id).
    static func isMuted(_ e: NostrEvent, by rules: SafetyFilterSnapshot) -> Bool {
        let author = e.pubkey.lowercased()
        if rules.blockedPubkeys.contains(author) || rules.blockedPubkeys.contains(e.pubkey) { return true }
        if rules.reportedPubkeys.contains(e.pubkey) { return true }
        if rules.reportedEventIds.contains(e.id) { return true }
        if !rules.mutedWords.isEmpty, !e.content.isEmpty {
            let lower = e.content.lowercased()
            if rules.mutedWords.contains(where: { !$0.isEmpty && lower.contains($0) }) { return true }
        }
        if !rules.mutedThreads.isEmpty {
            if rules.mutedThreads.contains(e.id) { return true }
            for tag in e.tags where tag.count >= 2 && tag[0] == "e" {
                if rules.mutedThreads.contains(tag[1]) { return true }
            }
        }
        return false
    }
}
