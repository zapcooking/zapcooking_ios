import Foundation

// Fresh's special cards (recipe box + topic spotlight) as pure decisions,
// ported from web `src/lib/freshFeed/specials.ts` and `specialsConfig.ts`
// (ZapCooking e4a71d6b). Nothing here touches the network, the clock or
// storage; the view model (a later PR) drives it, behind
// `FeatureFlags.freshSpecialsEnabled`.
//
// - Where: the first card after post 5–7, then one every 7–9 posts
//   (jittered), for as long as the reader scrolls. Posts 1–5 are always
//   posts.
// - Which: recipe → spotlight → recipe → spotlight…, never the same type
//   twice in a row while the other is available. A slot far below the
//   screen waits for its own type; near the screen the next ready type
//   takes it; nothing ready by the time the reader gets there skips it.
// - What: spotlight topics rotate across all topics (never the same parent
//   group twice in a row, no repeat in a session, least recently shown
//   first); posts prefer images, one per author, and nothing this account
//   has been shown before.
//
// ≠ web (free tier only, Seth 2026-11-11): no memory cards, so the pattern
// is web's `recipe, spotlight, recipe, spotlight, memory` with memory never
// available — which is exactly recipe/spotlight alternation, the sequence
// a web reader without membership gets. No "Show fewer like this" and no
// "Hide this topic" (their undo lives in a web settings screen iOS doesn't
// have), so no per-type caps: web's caps are all unlimited without them.

/// Every tunable number, from web `SPECIALS`. Memory and "Keep exploring"
/// numbers are not ported.
nonisolated enum FreshSpecialsConfig {
    /// Posts at the top of the feed that never get a card before them.
    static let leadPosts = 5
    /// The first card's position in the feed (1-based, inclusive).
    static let firstPosition = 6...8
    /// Posts between two cards (inclusive, re-drawn per gap).
    static let gap = 7...9
    /// Posts on a spotlight card.
    static let spotlightPosts = 3
    /// A topic with fewer eligible posts than this is thin and skipped.
    static let spotlightMinPosts = 3
    /// Topics tried before giving up on one spotlight.
    static let maxTopicTries = 4
    /// A refused preview is asked again after this, doubling per refusal
    /// in a row up to `previewRetryMaxSeconds`.
    static let previewRetrySeconds = 60
    static let previewRetryMaxSeconds = 10 * 60
    /// An empty build is retried after this (web `specialsFlow.ts`).
    static let emptyRetrySeconds = 15
    /// "Already shown" memory: entries kept this long, at most `shownMax`.
    static let shownTtlSeconds = 90 * 24 * 60 * 60
    static let shownMax = 1000
    /// Spotlight topics remembered for "favor not shown recently".
    static let topicHistoryMax = 100
}

nonisolated enum FreshSpecialType: String, Equatable, Sendable, CaseIterable {
    case recipe
    case spotlight
}

/// A random number in [0, 1). Injected so tests repeat.
typealias FreshRandom = () -> Double

nonisolated enum FreshSpecials {
    /// Web `between`: an integer in `range`, drawn from `rng`.
    static func between(_ rng: FreshRandom, _ range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound
        return range.lowerBound + min(span, Int((rng() * Double(span + 1)).rounded(.down)))
    }

    /// The rotation pattern, repeating. Web's is `recipe, spotlight, recipe,
    /// spotlight, memory`; with memory never available that walk is this.
    static let rotation: [FreshSpecialType] = [.recipe, .spotlight]
}

// MARK: - Where

/// The slots' anchors: card k goes after the `anchors[k]`-th post (1-based).
/// Grows lazily so a long feed keeps getting slots; the same value always
/// returns the same positions (web `Slots`).
nonisolated struct FreshSlots {
    private var anchors: [Int] = []
    private let rng: FreshRandom

    init(rng: @escaping FreshRandom = { Double.random(in: 0..<1) }) {
        self.rng = rng
    }

    /// Anchors (post counts) up to and including `postCount`.
    mutating func upTo(_ postCount: Int) -> [Int] {
        if anchors.isEmpty {
            anchors.append(max(FreshSpecialsConfig.leadPosts,
                               FreshSpecials.between(rng, FreshSpecialsConfig.firstPosition) - 1))
        }
        while let last = anchors.last, last <= postCount {
            anchors.append(last + FreshSpecials.between(rng, FreshSpecialsConfig.gap))
        }
        return anchors.filter { $0 <= postCount }
    }
}

// MARK: - Which

/// The session's rotation: what was shown last and what comes next (web
/// `Rotation`, without caps or "fewer").
nonisolated struct FreshRotation: Equatable {
    private(set) var last: FreshSpecialType?
    private(set) var counts: [FreshSpecialType: Int] = [:]
    /// Next position in the (repeating) pattern.
    private var next = 0
    /// Where the last `choose` found its type, for `record`.
    private var chosenAt = -1

    init() {}

    /// The type for the next slot: walking the pattern from where it left
    /// off, the first type that is `available`, has something `ready`, and
    /// isn't the last one shown unless no other type is available.
    /// `available` is false for a type that can't appear at all right now
    /// (out of unshown content, previews on hold). `strict` (the slot is
    /// still far below the screen): only the pattern's own next type counts,
    /// so a card still loading isn't replaced by another. nil = wait
    /// (strict) or skip.
    mutating func choose(
        ready: (FreshSpecialType) -> Bool,
        strict: Bool = false,
        available: (FreshSpecialType) -> Bool = { _ in true }
    ) -> FreshSpecialType? {
        let order = FreshSpecials.rotation
        let repeatOK = !order.contains { $0 != last && available($0) }
        for i in 0..<order.count {
            let at = (next + i) % order.count
            let type = order[at]
            if !available(type) || (type == last && !repeatOK) { continue }
            if ready(type) {
                chosenAt = at
                return type
            }
            if strict { return nil }
        }
        return nil
    }

    mutating func record(_ type: FreshSpecialType) {
        counts[type, default: 0] += 1
        last = type
        let order = FreshSpecials.rotation
        let at = (chosenAt >= 0 && order[chosenAt] == type) ? chosenAt : (order.firstIndex(of: type) ?? 0)
        next = (at + 1) % order.count
        chosenAt = -1
    }
}

// MARK: - What: spotlight topics

nonisolated struct FreshSpotlightTopic: Equatable, Sendable {
    let slug: String
    let name: String
    /// The parent group's slug.
    let parent: String
    let title: String
}

extension FreshSpecials {
    /// Every leaf topic (all of them, not only featured ones), with its
    /// parent group.
    static func allTopics(_ groups: [FreshTopicGroup]) -> [FreshSpotlightTopic] {
        groups.flatMap { group in
            group.topics.map {
                FreshSpotlightTopic(slug: $0.slug, name: $0.name, parent: group.slug,
                                    title: FreshSpotlightTitles.title(slug: $0.slug, name: $0.name))
            }
        }
    }

    /// The next spotlight topic: not used this session (thin and `invalid:`
    /// topics count as used), not tried in this build, not the same parent
    /// group as the last spotlight; the least recently shown for this
    /// account first (never shown = first), ties broken at random.
    static func pickTopic(
        _ groups: [FreshTopicGroup],
        used: Set<String>,
        tried: Set<String> = [],
        lastParent: String?,
        history: [String: Int],
        rng: FreshRandom = { Double.random(in: 0..<1) }
    ) -> FreshSpotlightTopic? {
        let open = allTopics(groups).filter {
            !used.contains($0.slug) && !tried.contains($0.slug) && $0.parent != lastParent
        }
        let keyed = open.map { (topic: $0, last: history[$0.slug] ?? 0, r: rng()) }
        return keyed.min { a, b in a.last != b.last ? a.last < b.last : a.r < b.r }?.topic
    }
}

// MARK: - What: posts

extension FreshSpecials {
    private static let imageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg"]
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://\S+"#)

    /// Web `hasImage`: an `image` tag, or an image URL in the content (web
    /// `mediaUrls` + `isImageUrl`: the extension anywhere in the URL).
    static func hasImage(content: String, tags: [[String]]) -> Bool {
        if tags.contains(where: { $0.count >= 2 && $0[0] == "image" && !$0[1].isEmpty }) { return true }
        let range = NSRange(content.startIndex..., in: content)
        for match in urlRegex.matches(in: content, range: range) {
            guard let r = Range(match.range, in: content) else { continue }
            let lower = content[r].lowercased()
            if imageExtensions.contains(where: { lower.contains($0) }) { return true }
        }
        return false
    }

    static func hasImage(_ e: NostrEvent) -> Bool { hasImage(content: e.content, tags: e.tags) }

    /// Up to `max` posts: not shown to this account, not excluded (already
    /// in the feed or another card), one per author, posts with images first
    /// (otherwise in the given order).
    static func choosePosts(_ events: [NostrEvent], shown: Set<String>, exclude: Set<String>, max: Int) -> [NostrEvent] {
        let fresh = events.filter { !shown.contains($0.id) && !exclude.contains($0.id) }
        let ordered = fresh.filter(hasImage) + fresh.filter { !hasImage($0) }
        var authors = Set<String>()
        var out: [NostrEvent] = []
        for e in ordered {
            if out.count >= max { break }
            guard authors.insert(e.pubkey).inserted else { continue }
            out.append(e)
        }
        return out
    }

    /// A spotlight's posts, or nil when the topic is too thin.
    static func spotlightPosts(_ events: [NostrEvent], shown: Set<String>, exclude: Set<String>) -> [NostrEvent]? {
        let posts = choosePosts(events, shown: shown, exclude: exclude, max: FreshSpecialsConfig.spotlightPosts)
        return posts.count >= FreshSpecialsConfig.spotlightMinPosts ? posts : nil
    }
}

// MARK: - The feed with its cards

/// A card in the feed.
nonisolated enum FreshSpecial: Equatable {
    /// "From the recipe box": one older recipe.
    case recipe(NostrEvent)
    /// A topic spotlight: a few posts from the relay's topic preview.
    case spotlight(FreshSpotlightTopic, posts: [NostrEvent])

    var type: FreshSpecialType {
        switch self {
        case .recipe: return .recipe
        case .spotlight: return .spotlight
        }
    }

    static func == (a: FreshSpecial, b: FreshSpecial) -> Bool {
        switch (a, b) {
        case let (.recipe(x), .recipe(y)): return x.id == y.id
        case let (.spotlight(t1, p1), .spotlight(t2, p2)): return t1 == t2 && p1.map(\.id) == p2.map(\.id)
        default: return false
        }
    }
}

/// A decided slot: after the post `anchorId`, this card, or nothing (a
/// skipped slot stays decided so it is not offered again).
nonisolated struct FreshPlacedSlot: Equatable {
    /// Stable list identity (`sp:<n>`).
    let key: String
    var anchorId: String
    let special: FreshSpecial?
}

nonisolated enum FreshPlacedRow<Item> {
    case item(Item)
    case card(key: String, special: FreshSpecial)
}

extension FreshSpecials {
    /// Posts with each placed card right after its anchor post, in slot
    /// order. A slot whose anchor is not in `items` places nothing (call
    /// `reanchor` when posts are removed, so that doesn't happen).
    static func place<Item>(_ items: [Item], id: (Item) -> String, slots: [FreshPlacedSlot]) -> [FreshPlacedRow<Item>] {
        var byAnchor: [String: [FreshPlacedSlot]] = [:]
        for slot in slots { byAnchor[slot.anchorId, default: []].append(slot) }
        var out: [FreshPlacedRow<Item>] = []
        for item in items {
            out.append(.item(item))
            for slot in byAnchor[id(item)] ?? [] {
                if let special = slot.special { out.append(.card(key: slot.key, special: special)) }
            }
        }
        return out
    }

    /// Posts in `order` (the list before the removal) are being removed
    /// (reported, blocked, deleted). A slot anchored on a removed post moves
    /// up to the post directly above it, or further up past other removed
    /// posts; with no post left above, the slot is dropped.
    ///
    /// ≠ web: `placeSpecials` drops a card whose anchor is gone, so hiding
    /// one author would take an unrelated card with it (Seth, 2026-11-11).
    static func reanchor(_ slots: [FreshPlacedSlot], order: [String], removed: Set<String>) -> [FreshPlacedSlot] {
        guard !removed.isEmpty else { return slots }
        var replacement: [String: String?] = [:]
        var lastSurvivor: String?
        for id in order {
            if removed.contains(id) {
                replacement[id] = .some(lastSurvivor)
            } else {
                lastSurvivor = id
            }
        }
        return slots.compactMap { slot in
            guard let moved = replacement[slot.anchorId] else { return slot }
            guard let anchor = moved else { return nil }
            var out = slot
            out.anchorId = anchor
            return out
        }
    }
}

// MARK: - Titles

/// Spotlight titles, keyed by the relay's topic slugs (web
/// `spotlightTitles.ts`, verbatim). A slug without an entry falls back to
/// the topic's own name.
nonisolated enum FreshSpotlightTitles {
    static let titles: [String: String] = [
        "sourdough": "🍞 The Sourdough Society",
        "bread": "🥖 Daily Bread",
        "pastry": "🥐 Flaky Business",
        "cakes": "🎂 Let Them Eat Cake",
        "cookies": "🍪 The Cookie Jar",
        "pickles": "🥒 From the Pickle Jar",
        "kimchi": "🌶️ Kimchi Corner",
        "sauerkraut": "🥬 Sauerkraut Station",
        "kombucha": "🫧 Kombucha Club",
        "canning": "🫙 Put Up & Preserved",
        "bbq": "🔥 Low & Slow",
        "smoking": "💨 Where There's Smoke",
        "grilling": "🍢 Fire It Up",
        "beef": "🥩 Where's the Beef",
        "pork": "🐖 Pork Party",
        "poultry": "🍗 Winner Winner Chicken Dinner",
        "seafood": "🦐 Catch of the Day",
        "charcuterie": "🧀 The Board Meeting",
        "vegetables": "🥕 Eat Your Veggies",
        "salads": "🥗 Toss It Up",
        "vegan": "🌱 Plant Power",
        "legumes": "🫘 Full of Beans",
        "coffee": "☕ GM Coffee Club",
        "tea": "🍵 Spill the Tea",
        "beer": "🍺 Hop Talk",
        "wine": "🍷 Uncorked",
        "cocktails": "🍸 Shaken, Not Stirred",
        "italian": "🍝 Mangia!",
        "mexican": "🌮 Taco 'Bout It",
        "japanese": "🍜 Itadakimasu",
        "indian": "🍛 Spice Route",
        "chinese": "🥟 Dumpling Dynasty",
        "breakfast": "🍳 Rise & Dine",
        "soups-stews": "🍲 Soup's On",
        "pasta": "🍝 Oodles of Noodles",
        "pizza": "🍕 Slice of Life",
        "sandwiches": "🥪 Stacked",
        "gardening": "🌻 Garden to Table",
        "foraging": "🍄 Into the Woods",
        "homesteading": "🏡 Homestead Corner",
        "cheese-dairy": "🧀 Say Cheese",
        "desserts": "🍰 Just Desserts",
        "chocolate": "🍫 Cocoa Loco",
        "ice-cream": "🍦 Brain Freeze",
    ]

    static func title(slug: String, name: String) -> String {
        titles[slug] ?? name
    }
}
