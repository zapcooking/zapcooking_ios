import Foundation
import Testing
@testable import wisp

/// Fresh special cards, the pure decisions (ported from web
/// `specials.test.ts`, `recipeBox.test.ts`, `specialsPrefs.test.ts`; memory,
/// "Show fewer" and "Hide this topic" cases dropped with the features).
@Suite struct FreshSpecialsTests {

    /// mulberry32, as web's tests use, so "random" runs repeat.
    final class Seeded {
        private var a: UInt32
        init(_ seed: UInt32) { a = seed }
        func next() -> Double {
            a = a &+ 0x6d2b79f5
            var t = a
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double(t ^ (t >> 14)) / 4294967296
        }
        var rng: FreshRandom { { self.next() } }
    }

    static func post(_ id: String, pubkey: String? = nil, kind: Int = 1, createdAt: Int = 1,
                     tags: [[String]] = [], content: String? = nil) -> NostrEvent {
        NostrEvent(id: id, pubkey: pubkey ?? "pk-\(id)", kind: kind, createdAt: createdAt,
                   tags: tags, content: content ?? id, sig: "")
    }

    static func withImage(_ id: String, pubkey: String? = nil) -> NostrEvent {
        post(id, pubkey: pubkey, content: "\(id) https://img.example/\(id).jpg")
    }

    /// The relay's catalog shape: 10 groups, 44 topics (feed-relay
    /// `topics.json` at 3d1e5db).
    static let groups: [FreshTopicGroup] = [
        ("baking", ["sourdough", "bread", "pastry", "cakes", "cookies"]),
        ("fermentation-preserving", ["pickles", "kimchi", "sauerkraut", "kombucha", "canning"]),
        ("bbq-grilling", ["bbq", "smoking", "grilling"]),
        ("meat-seafood", ["beef", "pork", "poultry", "seafood", "charcuterie"]),
        ("plant-based", ["vegetables", "salads", "vegan", "legumes"]),
        ("drinks", ["coffee", "tea", "beer", "wine", "cocktails"]),
        ("world-cuisines", ["italian", "mexican", "japanese", "indian", "chinese"]),
        ("meals", ["breakfast", "soups-stews", "pasta", "pizza", "sandwiches"]),
        ("growing-sourcing", ["gardening", "foraging", "homesteading", "cheese-dairy"]),
        ("sweets", ["desserts", "chocolate", "ice-cream"]),
    ].map { slug, topics in
        FreshTopicGroup(slug: slug, name: slug, count14d: 0,
                        topics: topics.map { FreshTopic(slug: $0, name: $0.capitalized, count14d: 0) })
    }

    // MARK: - Flag

    @Test("ships off: freshSpecialsEnabled is false")
    func flagIsOff() {
        #expect(FeatureFlags.freshSpecialsEnabled == false)
    }

    // MARK: - Slots

    @Test("first card at position 6–8, then 7–9 posts apart, never in the first 5")
    func slotSpacing() {
        for seed in UInt32(1)...300 {
            var slots = FreshSlots(rng: Seeded(seed).rng)
            let anchors = slots.upTo(200)
            // A card after the a-th post sits at feed position a + 1.
            #expect(FreshSpecialsConfig.firstPosition.contains(anchors[0] + 1))
            #expect(anchors[0] >= FreshSpecialsConfig.leadPosts)
            for i in 1..<anchors.count {
                #expect(FreshSpecialsConfig.gap.contains(anchors[i] - anchors[i - 1]))
            }
        }
    }

    @Test("jittered, not a fixed interval")
    func slotJitter() {
        var firsts = Set<Int>(), gaps = Set<Int>()
        for seed in UInt32(1)...50 {
            var slots = FreshSlots(rng: Seeded(seed).rng)
            let a = slots.upTo(100)
            firsts.insert(a[0])
            for i in 1..<a.count { gaps.insert(a[i] - a[i - 1]) }
        }
        #expect(firsts.count == 3)
        #expect(gaps.count == 3)
    }

    @Test("stable: the same slots keep their positions as the feed grows")
    func slotStability() {
        var slots = FreshSlots(rng: Seeded(7).rng)
        let early = slots.upTo(30)
        #expect(Array(slots.upTo(90).prefix(early.count)) == early)
    }

    @Test("between: the RNG's edges land on the range's ends")
    func betweenEdges() {
        #expect(FreshSpecials.between({ 0 }, 7...9) == 7)
        #expect(FreshSpecials.between({ 0.9999999 }, 7...9) == 9)
    }

    // MARK: - Rotation

    func run(_ n: Int, ready: (FreshSpecialType) -> Bool = { _ in true },
             available: (FreshSpecialType) -> Bool = { _ in true }) -> [FreshSpecialType] {
        var r = FreshRotation()
        var seq: [FreshSpecialType] = []
        for _ in 0..<n {
            guard let t = r.choose(ready: ready, available: available) else { continue }
            r.record(t)
            seq.append(t)
        }
        return seq
    }

    @Test("recipe → spotlight → recipe → spotlight…: web's pattern without memory cards")
    func rotationAlternates() {
        #expect(run(6) == [.recipe, .spotlight, .recipe, .spotlight, .recipe, .spotlight])
    }

    @Test("no exhaustion: ~150 posts of slots keep both types coming")
    func rotationNoCaps() {
        var slots = FreshSlots(rng: Seeded(11).rng)
        let anchors = slots.upTo(150)
        #expect(anchors.count >= 16)
        let seq = run(anchors.count)
        #expect(seq.count == anchors.count)
        #expect(Set(seq.suffix(4)) == [.recipe, .spotlight])
    }

    @Test("spotlights unavailable (no topic list, previews on hold): recipes may repeat")
    func rotationOnlyRecipes() {
        #expect(run(4, available: { $0 == .recipe }) == [.recipe, .recipe, .recipe, .recipe])
    }

    @Test("the other type not ready: the last type does not repeat, the slot is skipped")
    func rotationSkipsRatherThanRepeats() {
        var r = FreshRotation()
        r.record(.recipe)
        #expect(r.choose(ready: { $0 == .recipe }) == nil)
        #expect(r.choose(ready: { _ in true }) == .spotlight)
    }

    @Test("strict (slot far below the screen): waits for the pattern's own type")
    func rotationStrict() {
        var r = FreshRotation()
        #expect(r.choose(ready: { $0 != .recipe }, strict: true) == nil)
        #expect(r.choose(ready: { $0 != .recipe }, strict: false) == .spotlight)
    }

    // MARK: - Topics

    @Test("rotates across all 44 topics, every one with a title")
    func allTopicsHaveTitles() {
        let topics = FreshSpecials.allTopics(Self.groups)
        #expect(topics.count == 44)
        for t in topics { #expect(FreshSpotlightTitles.titles[t.slug] != nil, "\(t.slug)") }
        #expect(FreshSpotlightTitles.titles.count == 44)
        #expect(FreshSpotlightTitles.title(slug: "unknown-slug", name: "Unknown") == "Unknown")
    }

    @Test("never the same parent group twice in a row, never a topic twice in a session")
    func topicVariety() throws {
        var used = Set<String>()
        var lastParent: String?
        let rng = Seeded(3).rng
        for _ in 0..<30 {
            let t = try #require(FreshSpecials.pickTopic(Self.groups, used: used, lastParent: lastParent, history: [:], rng: rng))
            #expect(t.parent != lastParent)
            #expect(!used.contains(t.slug))
            used.insert(t.slug)
            lastParent = t.parent
        }
    }

    @Test("favors topics not shown recently to this account")
    func topicHistory() {
        var history = Dictionary(uniqueKeysWithValues: FreshSpecials.allTopics(Self.groups).map { ($0.slug, 1000) })
        history["kimchi"] = nil
        history["pizza"] = 5
        #expect(FreshSpecials.pickTopic(Self.groups, used: [], lastParent: nil, history: history)?.slug == "kimchi")
        history["kimchi"] = 2000
        #expect(FreshSpecials.pickTopic(Self.groups, used: [], lastParent: nil, history: history)?.slug == "pizza")
    }

    @Test("a used topic (thin, or answered invalid:) and one tried in this build are never picked")
    func topicUsedAndTried() {
        let all = FreshSpecials.allTopics(Self.groups).map(\.slug)
        let used = Set(all.filter { $0 != "tea" && $0 != "beer" })
        #expect(FreshSpecials.pickTopic(Self.groups, used: used, tried: ["beer"], lastParent: nil, history: [:])?.slug == "tea")
        #expect(FreshSpecials.pickTopic(Self.groups, used: used.union(["tea"]), tried: ["beer"], lastParent: nil, history: [:]) == nil)
    }

    // MARK: - Spotlight posts

    @Test("thin: fewer than 3 eligible posts is no spotlight")
    func thinTopic() {
        #expect(FreshSpecials.spotlightPosts([Self.withImage("a"), Self.withImage("b")], shown: [], exclude: []) == nil)
    }

    @Test("prefer images, one post per author")
    func choosePostsOrder() {
        let events = [
            Self.post("t1", pubkey: "x"),
            Self.withImage("i1", pubkey: "x"),
            Self.withImage("i2", pubkey: "x"),
            Self.withImage("i3", pubkey: "y"),
            Self.post("t2", pubkey: "z"),
        ]
        #expect(FreshSpecials.choosePosts(events, shown: [], exclude: [], max: 3).map(\.id) == ["i1", "i3", "t2"])
    }

    @Test("never a post this account was shown, or one already on screen")
    func spotlightExclusions() throws {
        let events = ["a", "b", "c", "d", "e"].map { Self.withImage($0) }
        let picked = try #require(FreshSpecials.spotlightPosts(events, shown: ["a"], exclude: ["b"]))
        #expect(picked.map(\.id) == ["c", "d", "e"])
    }

    @Test("hasImage: an image tag, or an image URL in the content; video and plain links are not")
    func hasImage() {
        #expect(FreshSpecials.hasImage(content: "x", tags: [["image", "https://a/b"]]))
        #expect(!FreshSpecials.hasImage(content: "x", tags: [["image", ""]]))
        #expect(FreshSpecials.hasImage(content: "look https://cdn.example/a.JPG?w=2", tags: []))
        #expect(FreshSpecials.hasImage(content: "https://x/p.webp", tags: []))
        #expect(!FreshSpecials.hasImage(content: "https://x/clip.mp4 https://x/page", tags: []))
        #expect(!FreshSpecials.hasImage(content: "photo.jpg without a link", tags: []))
    }

    // MARK: - Placing cards

    static let recipeCard = FreshSpecial.recipe(post("r", kind: 30023))

    func shape(_ ids: [String], _ slots: [FreshPlacedSlot]) -> [String] {
        FreshSpecials.place(ids, id: { $0 }, slots: slots).map {
            switch $0 {
            case .item(let id): return id
            case .card(let key, _): return key
            }
        }
    }

    @Test("each card follows its anchor; posts prepended later (the pill) leave it there")
    func placeAfterAnchor() {
        let feed = ["p1", "p2", "p3", "p4", "p5", "p6", "p7"]
        let slots = [FreshPlacedSlot(key: "sp:0", anchorId: "p6", special: Self.recipeCard)]
        #expect(shape(feed, slots) == ["p1", "p2", "p3", "p4", "p5", "p6", "sp:0", "p7"])
        #expect(shape(["new1", "new2"] + feed, slots) == ["new1", "new2", "p1", "p2", "p3", "p4", "p5", "p6", "sp:0", "p7"])
    }

    @Test("a skipped slot places nothing")
    func skippedSlot() {
        #expect(shape(["p1", "p2"], [FreshPlacedSlot(key: "sp:0", anchorId: "p1", special: nil)]) == ["p1", "p2"])
    }

    @Test("anchor hidden: the card moves up one post; past other hidden posts if needed; dropped with none left above")
    func reanchor() {
        let feed = ["p1", "p2", "p3", "p4", "p5", "p6", "p7"]
        let slot = FreshPlacedSlot(key: "sp:0", anchorId: "p6", special: Self.recipeCard)

        let up1 = FreshSpecials.reanchor([slot], order: feed, removed: ["p6"])
        #expect(up1.map(\.anchorId) == ["p5"])
        #expect(shape(feed.filter { $0 != "p6" }, up1) == ["p1", "p2", "p3", "p4", "p5", "sp:0", "p7"])

        // The post above the anchor is hidden too.
        #expect(FreshSpecials.reanchor([slot], order: feed, removed: ["p5", "p6"]).map(\.anchorId) == ["p4"])
        // A hidden post elsewhere leaves the card alone.
        #expect(FreshSpecials.reanchor([slot], order: feed, removed: ["p2", "p7"]) == [slot])
        // Nothing left above.
        #expect(FreshSpecials.reanchor([slot], order: feed, removed: ["p1", "p2", "p3", "p4", "p5", "p6"]).isEmpty)
        // A decided-empty slot moves the same way, so it is not offered again.
        let empty = FreshPlacedSlot(key: "sp:1", anchorId: "p6", special: nil)
        #expect(FreshSpecials.reanchor([empty], order: feed, removed: ["p6"]).map(\.anchorId) == ["p5"])
    }

    @Test("two cards meeting on one post keep their order")
    func reanchorCollision() {
        let feed = ["p1", "p2", "p3"]
        let a = FreshPlacedSlot(key: "sp:0", anchorId: "p2", special: Self.recipeCard)
        let b = FreshPlacedSlot(key: "sp:1", anchorId: "p3", special: Self.recipeCard)
        let moved = FreshSpecials.reanchor([a, b], order: feed, removed: ["p2", "p3"])
        #expect(shape(["p1"], moved) == ["p1", "sp:0", "sp:1"])
    }

    // MARK: - Paging position

    @Test("a row's position among posts ignores the divider; the divider itself has none")
    func postPosition() {
        let rows: [FreshDividedRow<FreshRow>] = [
            .row(FreshRow(event: Self.post("a"))), .divider(newCount: 1),
            .row(FreshRow(event: Self.post("b"))), .row(FreshRow(event: Self.post("c"))),
        ]
        #expect(FreshFeedViewModel.postPosition(ofRow: 0, in: rows) == 0)
        #expect(FreshFeedViewModel.postPosition(ofRow: 1, in: rows) == nil)
        #expect(FreshFeedViewModel.postPosition(ofRow: 2, in: rows) == 1)
        #expect(FreshFeedViewModel.postPosition(ofRow: 3, in: rows) == 2)
        #expect(FreshFeedViewModel.postPosition(ofRow: 4, in: rows) == nil)
    }
}

/// The recipe box (web `recipeBox.test.ts`) and the box / finish-line row
/// exclusion.
@Suite struct FreshRecipeBoxTests {
    static let now = 1_800_000_000
    static let day = 86_400

    static func recipe(_ id: String, d: String, author: String = "a", createdAt: Int,
                       publishedAt: Int? = nil, tagged: Bool = true, template: Bool = true) -> NostrEvent {
        var tags: [[String]] = [["d", d]]
        if tagged { tags.append(["t", "zapcooking"]) }
        if let publishedAt { tags.append(["published_at", String(publishedAt)]) }
        let content = template
            ? "## Chef's notes\n\n\(id)\n\n## Ingredients\n\n- flour\n- water\n\n## Directions\n\n1. Mix.\n2. Bake."
            : "\(id): an article, not a recipe."
        return NostrEvent(id: id, pubkey: author, kind: 30023, createdAt: createdAt, tags: tags, content: content, sig: "")
    }

    @Test("candidates: recipes (tag and recipe template) first published more than 14 days ago; a tagged article is not one")
    func candidates() {
        let old = Self.recipe("old", d: "a", createdAt: Self.now - 30 * Self.day)
        let new = Self.recipe("new", d: "b", createdAt: Self.now - 2 * Self.day)
        let oldEdit = Self.recipe("edit", d: "c", createdAt: Self.now - Self.day, publishedAt: Self.now - 100 * Self.day)
        let untagged = Self.recipe("plain", d: "d", createdAt: Self.now - 30 * Self.day, tagged: false)
        let note = NostrEvent(id: "n", pubkey: "a", kind: 1, createdAt: Self.now - 30 * Self.day, tags: [], content: "", sig: "")
        // Seth's device pass: an announcement tagged zapcooking (badge ARTICLE).
        let taggedArticle = Self.recipe("branta", d: "branta", createdAt: Self.now - 30 * Self.day, template: false)
        #expect(FreshRecipeBox.isCandidate(old, now: Self.now))
        #expect(!FreshRecipeBox.isCandidate(taggedArticle, now: Self.now))
        #expect(FreshRecipeBox.buildPool([taggedArticle, old], now: Self.now).map(\.id) == ["old"])
        #expect(!FreshRecipeBox.isCandidate(new, now: Self.now))
        #expect(FreshRecipeBox.isCandidate(oldEdit, now: Self.now))
        #expect(!FreshRecipeBox.isCandidate(untagged, now: Self.now))
        #expect(!FreshRecipeBox.isCandidate(note, now: Self.now))
    }

    @Test("pool: one per coordinate, the newest version")
    func pool() {
        let v1 = Self.recipe("v1", d: "soup", createdAt: Self.now - 40 * Self.day)
        let v2 = Self.recipe("v2", d: "soup", createdAt: Self.now - 30 * Self.day)
        let other = Self.recipe("o", d: "bread", createdAt: Self.now - 50 * Self.day)
        #expect(FreshRecipeBox.buildPool([v1, v2, other], now: Self.now).map(\.id) == ["v2", "o"])
    }

    @Test("pickRandom: never a seen, taken or excluded recipe; nil when used up")
    func pickRandom() {
        let a = Self.recipe("a", d: "a", createdAt: 1), b = Self.recipe("b", d: "b", createdAt: 2)
        let c = Self.recipe("c", d: "c", createdAt: 3)
        let pool = [a, b, c]
        let addr = FreshRecipeBox.address
        #expect(FreshRecipeBox.pickRandom(pool, seen: [addr(a)], taken: [addr(b)], random: { 0 })?.id == "c")
        #expect(FreshRecipeBox.pickRandom(pool, seen: [], taken: [], excluding: [addr(a), addr(b)], random: { 0.99 })?.id == "c")
        #expect(FreshRecipeBox.pickRandom(pool, seen: [], taken: [], random: { 0.99 })?.id == "c")
        #expect(FreshRecipeBox.pickRandom(pool, seen: [addr(a), addr(b), addr(c)], taken: []) == nil)
    }

    @Test("box cards and the finish-line row never show the same recipe")
    func boxAndRowExcludeEachOther() {
        let pool = (0..<6).map { Self.recipe("r\($0)", d: "d\($0)", createdAt: 100 - $0) }
        let addr = FreshRecipeBox.address
        // The box took r0 and r2 while scrolling: the row leaves them out.
        let taken: Set<String> = [addr(pool[0]), addr(pool[2])]
        let row = FreshRecipeBox.rowPicks(pool: pool, feed: [], boxTaken: taken, limit: 3)
        #expect(row.map(\.id) == ["r1", "r3", "r4"])
        // A box pick after the row was shown leaves the row's recipes out.
        let rowShown = Set(row.map(addr))
        for r in stride(from: 0.0, to: 1.0, by: 0.1) {
            let pick = FreshRecipeBox.pickRandom(pool, seen: [], taken: taken, excluding: rowShown, random: { r })
            #expect(pick?.id == "r5")
        }
    }

    @Test("the row still leaves out recipes already in the feed, by id and by coordinate")
    func rowSkipsFeed() {
        let pool = [Self.recipe("x2", d: "x", createdAt: 9), Self.recipe("y", d: "y", createdAt: 8),
                    Self.recipe("z", d: "z", createdAt: 7)]
        let feed = [Self.recipe("x1", d: "x", createdAt: 1), Self.recipe("y", d: "y", createdAt: 8)]
        #expect(FreshRecipeBox.rowPicks(pool: pool, feed: feed, boxTaken: [], limit: 5).map(\.id) == ["z"])
    }
}

/// What the cards have shown: per account, pruned, wiped with the account.
@Suite(.serialized) struct FreshSpecialsStoreTests {
    static let now = 1_800_000_000

    func freshDefaults() -> UserDefaults {
        let name = "FreshSpecialsStoreTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("per account: one account's shown posts never steer another's")
    func perAccount() {
        let d = freshDefaults()
        let a = FreshSpecialsStore(pubkey: "a", defaults: d), b = FreshSpecialsStore(pubkey: "b", defaults: d)
        a.markShown(["p1", "p2"], now: Self.now)
        a.markRecipeBoxSeen("30023:x:soup", now: Self.now)
        a.markTopicShown("tea", now: Self.now)
        #expect(Set(a.loadShown(now: Self.now).keys) == ["p1", "p2"])
        #expect(b.loadShown(now: Self.now).isEmpty)
        #expect(b.loadRecipeBoxSeen(now: Self.now).isEmpty)
        #expect(b.loadTopicHistory().isEmpty)
        #expect(a.loadTopicHistory() == ["tea": Self.now])
    }

    @Test("kept 90 days, at most the 1,000 newest")
    func pruning() {
        let ttl = FreshSpecialsConfig.shownTtlSeconds
        let pruned = FreshSpecialsStore.prune(["old": Self.now - ttl, "young": Self.now - ttl + 1], now: Self.now)
        #expect(Array(pruned.keys) == ["young"])
        var many: [String: Int] = [:]
        for i in 0..<1200 { many["p\(i)"] = Self.now - i }
        let capped = FreshSpecialsStore.prune(many, now: Self.now)
        #expect(capped.count == FreshSpecialsConfig.shownMax)
        #expect(capped["p0"] != nil && capped["p999"] != nil && capped["p1000"] == nil)
    }

    @Test("topic history keeps the 100 most recent, without a TTL")
    func topicHistoryCap() {
        let s = FreshSpecialsStore(pubkey: "a", defaults: freshDefaults())
        for i in 0..<120 { s.markTopicShown("t\(i)", now: Self.now - 400 * 86_400 + i) }
        let h = s.loadTopicHistory()
        #expect(h.count == FreshSpecialsConfig.topicHistoryMax)
        #expect(h["t119"] != nil && h["t19"] == nil)
    }

    @Test("a stored value of the wrong shape reads as empty")
    func badShapes() {
        let d = freshDefaults()
        d.set("nope", forKey: FreshSpecialsStore.shownKey("a"))
        d.set(["x": "y", "ok": 5], forKey: FreshSpecialsStore.topicHistoryKey("a"))
        let s = FreshSpecialsStore(pubkey: "a", defaults: d)
        #expect(s.loadShown(now: Self.now).isEmpty)
        #expect(s.loadTopicHistory() == ["ok": 5])
    }

    @Test("account wipe removes every special-card key")
    func wipe() {
        let pk = String(repeating: "0", count: 62) + "5c"
        for key in FreshSpecialsStore.allKeys(pk) { UserDefaults.standard.set(["x": 1], forKey: key) }
        NostrKey.deleteAccount(pubkey: pk)
        for key in FreshSpecialsStore.allKeys(pk) {
            #expect(UserDefaults.standard.object(forKey: key) == nil, "\(key)")
        }
    }
}
