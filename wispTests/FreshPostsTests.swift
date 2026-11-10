import Foundation
import Testing
@testable import wisp

/// Port of web `src/lib/freshFeed/posts.test.ts` (filter cases), plus the
/// iOS-only HiddenRecipes ingest rule.
@MainActor
struct FreshPostsTests {
    nonisolated static let now = 2_000_000_000
    nonisolated static let day = 86_400

    static func ev(id: String = String(repeating: "1", count: 64),
                   pubkey: String = String(repeating: "c", count: 64),
                   kind: Int = 1, createdAt: Int = now - 60,
                   tags: [[String]] = [], content: String = "hello") -> NostrEvent {
        NostrEvent(id: id, pubkey: pubkey, kind: kind, createdAt: createdAt, tags: tags, content: content, sig: "s")
    }

    static let muted = String(repeating: "b", count: 64)

    static func rules(blocked: Set<String> = [], words: Set<String> = [], threads: Set<String> = [],
                      hellthread: Bool = false, reportedIds: Set<String> = [],
                      reportedPubkeys: Set<String> = []) -> SafetyFilterSnapshot {
        SafetyFilterSnapshot(mutedWords: words, blockedPubkeys: blocked, mutedThreads: threads,
                             wotEnabled: false, qualifiedNetwork: [], userPubkey: "",
                             hellthreadFilterEnabled: hellthread,
                             reportedEventIds: reportedIds, reportedPubkeys: reportedPubkeys)
    }

    // MARK: post kinds

    @Test func recipes_kind35000_or30023TaggedZapcookingOrNostrcooking_anyCase() {
        #expect(FreshPosts.isRecipe(kind: 35000, tags: []))
        #expect(FreshPosts.isRecipe(kind: 30023, tags: [["t", "ZapCooking"]]))
        #expect(FreshPosts.isRecipe(kind: 30023, tags: [["t", "nostrcooking"]]))
        #expect(!FreshPosts.isRecipe(kind: 30023, tags: [["t", "food"]]))
        #expect(!FreshPosts.isRecipe(kind: 1, tags: [["t", "zapcooking"]]))
    }

    @Test func mapsEveryFeedKind() {
        #expect(FreshPosts.postKind(kind: 1, tags: []) == .note)
        #expect(FreshPosts.postKind(kind: 1068, tags: []) == .poll)
        #expect(FreshPosts.postKind(kind: 35000, tags: []) == .recipe)
        #expect(FreshPosts.postKind(kind: 30023, tags: []) == .article)
    }

    // MARK: old edits stay out of the main feed

    @Test func longFormPublishedBeforeTheWindow_isAnEdit() {
        let old = String(Self.now - 30 * Self.day)
        #expect(FreshPosts.isOldEdit(kind: 30023, tags: [["published_at", old]], now: Self.now))
        #expect(FreshPosts.isOldEdit(kind: 35000, tags: [["published_at", old]], now: Self.now))
    }

    @Test func recentOrMissingPublishedAt_andNotes_areNot() {
        #expect(!FreshPosts.isOldEdit(kind: 30023, tags: [["published_at", String(Self.now - Self.day)]], now: Self.now))
        #expect(!FreshPosts.isOldEdit(kind: 30023, tags: [], now: Self.now))
        #expect(!FreshPosts.isOldEdit(kind: 30023, tags: [["published_at", "garbage"]], now: Self.now))
        #expect(!FreshPosts.isOldEdit(kind: 1, tags: [["published_at", "1"]], now: Self.now))
    }

    // MARK: passesFreshFilters

    @Test func passesAnOrdinaryPost() {
        let r = Self.rules(blocked: [Self.muted], words: ["spam"])
        #expect(FreshPosts.passesFreshFilters(Self.ev(), rules: r, now: Self.now))
        #expect(FreshPosts.passesFreshFilters(Self.ev(), rules: nil, now: Self.now))
    }

    /// Web also mutes by hashtag (`#t nsfw`); iOS has no hashtag mutes, so
    /// that third assertion has no iOS counterpart.
    @Test func appliesMutes_peopleAndWords() {
        let r = Self.rules(blocked: [Self.muted], words: ["spam"])
        #expect(!FreshPosts.passesFreshFilters(Self.ev(pubkey: Self.muted), rules: r, now: Self.now))
        #expect(!FreshPosts.passesFreshFilters(Self.ev(content: "buy SPAM now"), rules: r, now: Self.now))
    }

    @Test func appliesTheHellthreadRule() {
        let crowd = (0..<NostrEvent.hellthreadThreshold).map { ["p", String(format: "%064d", $0)] }
        let e = Self.ev(tags: crowd)
        #expect(!FreshPosts.passesFreshFilters(e, rules: Self.rules(hellthread: true), now: Self.now))
        // The iOS rule is a setting: off, the same post passes.
        #expect(FreshPosts.passesFreshFilters(e, rules: Self.rules(hellthread: false), now: Self.now))
    }

    @Test func dropsOldEdits() {
        let e = Self.ev(kind: 30023, tags: [["published_at", String(Self.now - 90 * Self.day)]])
        #expect(!FreshPosts.passesFreshFilters(e, rules: nil, now: Self.now))
    }

    @Test func appliesNoFoodTestOrHashtagCap_theRelayIsCurated() {
        let many = (0..<12).map { ["t", "tag\($0)"] }
        let e = Self.ev(tags: many, content: "a note about my bike")
        #expect(FreshPosts.passesFreshFilters(e, rules: nil, now: Self.now))
    }

    // MARK: passesReaderFilters (recipe-row picks)

    @Test func readerFilters_applyMutesAndHellthread_butKeepOldEdits() {
        let old = Self.ev(kind: 30023, tags: [["published_at", String(Self.now - 90 * Self.day)]])
        #expect(FreshPosts.passesReaderFilters(old, rules: nil))
        let crowded = Self.ev(kind: 30023, tags: [["published_at", String(Self.now - 90 * Self.day)]]
                               + (0..<30).map { ["p", String(format: "%064d", $0)] })
        #expect(!FreshPosts.passesReaderFilters(crowded, rules: Self.rules(hellthread: true)))
        #expect(!FreshPosts.passesReaderFilters(old, rules: Self.rules(blocked: [old.pubkey])))
    }

    // MARK: iOS-only

    @Test func mutedThreads_hideTheNoteItselfAndRepliesNamingIt() {
        let root = String(repeating: "a", count: 64)
        let r = Self.rules(threads: [root])
        #expect(!FreshPosts.passesFreshFilters(Self.ev(id: root), rules: r, now: Self.now))
        #expect(!FreshPosts.passesFreshFilters(Self.ev(tags: [["e", root, "", "root"]]), rules: r, now: Self.now))
        #expect(FreshPosts.passesFreshFilters(Self.ev(), rules: r, now: Self.now))
    }

    @Test func reportedPostsAndAuthors_areHidden() {
        let e = Self.ev()
        #expect(!FreshPosts.passesFreshFilters(e, rules: Self.rules(reportedIds: [e.id]), now: Self.now))
        #expect(!FreshPosts.passesFreshFilters(e, rules: Self.rules(reportedPubkeys: [e.pubkey]), now: Self.now))
    }

    @Test func hiddenRecipes_droppedAtIngest_forKind30023Only() throws {
        let coordinate = try #require(HiddenRecipes.coordinates.first)
        let parts = coordinate.split(separator: ":", maxSplits: 2).map(String.init)
        let hidden = Self.ev(pubkey: parts[1], kind: 30023, tags: [["d", parts[2]], ["t", "zapcooking"]])
        #expect(FreshPosts.isHiddenAtIngest(hidden))
        #expect(!FreshPosts.passesReaderFilters(hidden, rules: nil))
        #expect(!FreshPosts.passesFreshFilters(hidden, rules: nil, now: Self.now))
        // Untagged long-form on the list is hidden too: the rule is by coordinate.
        let untagged = Self.ev(pubkey: parts[1], kind: 30023, tags: [["d", parts[2]]])
        #expect(FreshPosts.isHiddenAtIngest(untagged))
        // A d-tag prefix hides under any key.
        let probe = Self.ev(kind: 30023, tags: [["d", "ios-2.3-live-publish-1700000000"]])
        #expect(FreshPosts.isHiddenAtIngest(probe))
        // A note by the same author with the same d tag is not a recipe coordinate.
        let note = Self.ev(pubkey: parts[1], kind: 1, tags: [["d", parts[2]]])
        #expect(!FreshPosts.isHiddenAtIngest(note))
        #expect(FreshPosts.passesFreshFilters(note, rules: nil, now: Self.now))
    }

    @Test func feedKindsAreTheContractKinds_no35000() {
        #expect(FreshPosts.feedKinds == [1, 30023, 1068])
        #expect(FreshPosts.freeWindowSeconds == 14 * 86_400)
    }
}
