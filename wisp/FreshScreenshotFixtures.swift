import Foundation

#if DEBUG
/// Invented content for `FreshScreenshotsUITests` (`-FreshScreenshotFixtures`):
/// six made-up cooks, their notes and recipes, served to the real
/// `FreshRelayClient` by an in-app fixture relay. No real user appears, and
/// nothing goes to the network or the event store. Events are signed with
/// keys made at launch, so the client's id and signature checks run as
/// usual. Times are relative to launch, so the shots never go stale.
@MainActor
enum FreshScreenshotFixtures {
    struct Cook {
        let name: String
        let about: String
        let priv: Data
        let pubkey: String
    }

    static let cooks: [Cook] = [
        ("Marisol Vega", "Home cook. Mole, tortillas, too many chiles."),
        ("Theo Brandt", "Sourdough every Saturday. Crumb shots on request."),
        ("Aiko Tanaka", "Ramen nerd. Broth takes as long as it takes."),
        ("June Okafor", "Growing what I cook, cooking what I grow."),
        ("Ravi Menon", "Spice blends and weeknight curries."),
        ("Elena Rossi", "Fresh pasta, slowly."),
    ].map { name, about in
        let priv = Schnorr.randomPrivkey()
        let pubkey = (try? Schnorr.xonlyPubkey(privkey32: priv)).map(Hex.encode) ?? ""
        return Cook(name: name, about: about, priv: priv, pubkey: pubkey)
    }

    static let profiles: [String: ProfileData] = Dictionary(uniqueKeysWithValues: cooks.map {
        ($0.pubkey, ProfileData(pubkey: $0.pubkey, json: ["name": $0.name, "display_name": $0.name, "about": $0.about]))
    })

    private static func sign(_ cook: Int, minutesAgo: Int, kind: Int = 1, tags: [[String]] = [], _ content: String) -> NostrEvent? {
        let c = cooks[cook]
        return try? NostrEvent.sign(
            privkey32: c.priv, pubkey: c.pubkey, kind: kind,
            createdAt: NostrClock.now() - minutesAgo * 60, tags: tags, content: content
        )
    }

    private static func recipe(_ cook: Int, minutesAgo: Int, d: String, title: String, summary: String) -> NostrEvent? {
        sign(cook, minutesAgo: minutesAgo, kind: 30023,
             tags: [["d", d], ["title", title], ["summary", summary], ["t", "zapcooking"], ["t", "recipe"]],
             "## Chef's notes\n\n\(summary)\n\n## Ingredients\n\n- Salt\n- Patience\n\n## Directions\n\n1. Cook it.\n2. Taste it.\n3. Share it.")
    }

    static let longNote = """
    Made the big batch of mole today, the one that takes most of a Sunday. Toasted four kinds of dried chiles \
    (ancho, pasilla, mulato, a couple of chipotles for smoke), soaked them, then fried the paste in lard until it \
    went dark and glossy. Separately toasted sesame, almonds, a handful of raisins, a stale tortilla torn up, cinnamon, \
    cloves, black pepper and a little allspice. Everything went through the blender in batches with stock, then back into \
    the pot with a disc of Mexican chocolate and a spoon of sugar to round the bitterness. Two hours of low simmering and \
    stirring so the bottom never catches. It always tastes flat at the one-hour mark and I always panic, and then the last \
    half hour pulls it together. Most of it is going into the freezer in portions; tonight it's over turkey thighs with \
    rice and warm tortillas. If you've never made it, start a day ahead and invite people who will wash dishes.
    """

    /// The feed: 16 posts over the last 13 days (one short page, so the
    /// finish line is reached), six of them newer than 16 hours.
    static let feed: [NostrEvent] = [
        sign(0, minutesAgo: 6, "Tomatillo salsa, charred under the broiler first. Bright, smoky, gone in an hour. #foodstr"),
        sign(1, minutesAgo: 35, "Saturday loaf came out of the oven with the best ear I've had all year. Crumb shot later, it's still cooling and I'm being good."),
        recipe(4, minutesAgo: 90, d: "weeknight-chana-masala", title: "Weeknight Chana Masala",
               summary: "Chickpeas in a tomato, ginger and garam masala sauce, on the table in thirty minutes."),
        sign(2, minutesAgo: 180, "Tonkotsu, hour nine. The kitchen smells like a ramen shop and the windows are fogged. Worth it."),
        sign(0, minutesAgo: 420, longNote),
        sign(3, minutesAgo: 600, "First ripe figs off the tree this morning. Some for jam, most for eating standing up in the garden."),
        sign(5, minutesAgo: 1_200, "Pici by hand: just flour, water and a lot of rolling. Tossed with garlic, olive oil and breadcrumbs."),
        sign(4, minutesAgo: 1_800, "Toasting and grinding my own garam masala changed weeknight curry for me. Cardamom, cumin, coriander, clove, cinnamon, pepper."),
        recipe(1, minutesAgo: 2_600, d: "everyday-sourdough", title: "Everyday Sourdough",
               summary: "A forgiving 75% hydration loaf with an overnight cold proof."),
        sign(2, minutesAgo: 4_000, "Ajitama tip: seven minutes, ice bath, then marinate in soy, mirin and a splash of the broth overnight."),
        sign(3, minutesAgo: 5_500, "Garden haul: zucchini (always zucchini), beans, the last of the basil. Pesto tonight."),
        sign(5, minutesAgo: 7_200, "Sunday ragù on the stove since nine. The house smells right."),
        sign(1, minutesAgo: 9_000, "Rye starter is alive and very opinionated."),
        sign(0, minutesAgo: 11_000, "Blue corn tortillas from fresh masa. Soft, a little sweet, perfect for quesadillas."),
        sign(4, minutesAgo: 14_000, "Coconut fish curry with curry leaves and a squeeze of lime. Fifteen minutes, start to finish."),
        sign(2, minutesAgo: 18_000, "Shoyu ramen for a quick lunch: chicken stock, tare, noodles, scallions. Simple and right."),
    ].compactMap { $0 }

    /// The recipe row's pool: the two recipes above (excluded from the row,
    /// since the feed shows them) and eight more, older.
    static let recipes: [NostrEvent] = ([
        recipe(5, minutesAgo: 30_000, d: "cacio-e-pepe", title: "Cacio e Pepe", summary: "Pecorino, black pepper and pasta water, nothing else."),
        recipe(0, minutesAgo: 40_000, d: "mole-negro", title: "Mole Negro", summary: "The Sunday project, in freezer-sized portions."),
        recipe(2, minutesAgo: 50_000, d: "shoyu-tare", title: "Shoyu Tare", summary: "The seasoning that makes a bowl of ramen yours."),
        recipe(3, minutesAgo: 60_000, d: "fig-jam", title: "Fig and Lemon Jam", summary: "Small batch, no pectin, set by patience."),
        recipe(4, minutesAgo: 70_000, d: "garam-masala", title: "House Garam Masala", summary: "Toast, grind, keep in a jar, use everywhere."),
        recipe(1, minutesAgo: 80_000, d: "rye-crackers", title: "Rye Discard Crackers", summary: "What to do with the starter you'd otherwise throw away."),
        recipe(5, minutesAgo: 90_000, d: "basil-pesto", title: "Basil Pesto", summary: "Pounded, not blended."),
        recipe(0, minutesAgo: 100_000, d: "salsa-verde", title: "Tomatillo Salsa Verde", summary: "Charred tomatillos, serrano, cilantro, lime."),
    ].compactMap { $0 }) + feed.filter { $0.kind == 30023 }

    /// Spotlight topics (`-FreshScreenshotSpecials`): two groups, so the
    /// rotation can change group. No NIP-11 request is made.
    static let topicGroups: [FreshTopicGroup] = [
        FreshTopicGroup(slug: "baking", name: "Baking", count14d: 0, topics: [
            FreshTopic(slug: "sourdough", name: "Sourdough", count14d: 0),
        ]),
        FreshTopicGroup(slug: "world-cuisines", name: "World cuisines", count14d: 0, topics: [
            FreshTopic(slug: "japanese", name: "Japanese", count14d: 0),
        ]),
    ]

    /// Each topic's preview: three posts from three cooks, none in the feed.
    static let previews: [String: [NostrEvent]] = [
        "sourdough": [
            sign(1, minutesAgo: 240, "Levain peaked at 6am, mixed by 7. Long autolyse today and the dough already feels silky."),
            sign(3, minutesAgo: 900, "Discard focaccia with garden rosemary and flaky salt. Nobody believes it's leftovers."),
            sign(5, minutesAgo: 2_000, "Semolina sourdough for the first time. Golden crumb, nutty crust, slightly too proud of it."),
        ].compactMap { $0 },
        "japanese": [
            sign(2, minutesAgo: 300, "Dashi from scratch: kombu cold-steeped overnight, katsuobushi for one minute. That's the whole secret."),
            sign(0, minutesAgo: 1_100, "Okonomiyaki night. Cabbage, a little pork belly, too much kewpie. Perfect."),
            sign(4, minutesAgo: 2_400, "Onigiri for the road: umeboshi, salmon, and one with leftover curry nobody asked for."),
        ].compactMap { $0 },
    ]

    /// A Fresh view model wired to the fixture relay and profiles. With
    /// `-FreshScreenshotSpecials` the special cards are on for this view
    /// model only (the flag stays off): fixture topics and previews, a
    /// fixed random seed so the shots repeat, and a throwaway "already
    /// shown" store.
    static func viewModel(pubkey: String, specials: Bool = FreshScreenshotHarness.usesSpecials) -> FreshFeedViewModel {
        var seed: UInt64 = 0x5eed
        return FreshFeedViewModel(
            pubkey: pubkey,
            // With the cards on, page 1 is held a moment so the recipe download
            // lands first: on a tall screen (iPad portrait) the first slot's
            // anchor is already on screen when page 1 draws, and a slot the
            // reader can see is skipped (as on web).
            client: FreshRelayClient(transport: FreshFixtureTransport(
                events: feed + recipes, feedDelay: specials ? .milliseconds(400) : .zero)),
            ownLocalPosts: { [] },
            persist: { _ in },
            profileSource: FixtureProfiles(),
            specialsEnabled: specials,
            specialsStore: specials
                ? FreshSpecialsStore(pubkey: pubkey, defaults: UserDefaults(suiteName: "fresh-shots-\(UUID().uuidString)") ?? .standard)
                : nil,
            specialsRng: {
                // A small LCG: the same slots and picks every run.
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / Double(1 << 53)
            },
            topicGroups: { specials ? topicGroups : [] },
            topicPreview: { slug in FreshAnswer(events: previews[slug] ?? [], outcome: .answered) }
        )
    }

    struct FixtureProfiles: FreshProfileSource {
        func cached(_ pubkey: String) -> ProfileData? { FreshScreenshotFixtures.profiles[pubkey] }
        func observe(_ events: [NostrEvent]) {}
        func updates() -> AsyncStream<String> { AsyncStream { $0.finish() } }
    }
}

/// A relay in the app: answers `REQ` from a fixed set of events (kinds,
/// `since`, `until` inclusive, `#t`, `limit`, newest first), then `EOSE`.
/// A tail stays open and quiet. Topic searches get nothing.
nonisolated final class FreshFixtureTransport: GroupRelayTransport, @unchecked Sendable {
    let events: [NostrEvent]
    /// Feed pages (not recipes) are answered after this.
    let feedDelay: Duration
    init(events: [NostrEvent], feedDelay: Duration = .zero) {
        self.events = events
        self.feedDelay = feedDelay
    }
    func open(url: URL) -> GroupRelaySocket { FreshFixtureSocket(events: events, feedDelay: feedDelay) }
}

nonisolated final class FreshFixtureSocket: GroupRelaySocket, @unchecked Sendable {
    private let events: [NostrEvent]
    private let feedDelay: Duration
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private var iterator: AsyncStream<String>.AsyncIterator?

    init(events: [NostrEvent], feedDelay: Duration = .zero) {
        self.events = events
        self.feedDelay = feedDelay
        (stream, continuation) = AsyncStream<String>.makeStream()
    }

    func resume() {}

    func send(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [Any],
              frame.first as? String == "REQ", frame.count >= 3,
              let subId = frame[1] as? String,
              let filter = frame[2] as? [String: Any] else { return }
        var frames: [String] = []
        if filter["search"] == nil {
            let kinds = Set(filter["kinds"] as? [Int] ?? [])
            let since = filter["since"] as? Int ?? Int.min
            let until = filter["until"] as? Int ?? Int.max
            let tags = Set(filter["#t"] as? [String] ?? [])
            let limit = filter["limit"] as? Int ?? 100
            let matches = events
                .filter { kinds.isEmpty || kinds.contains($0.kind) }
                .filter { $0.createdAt >= since && $0.createdAt <= until }
                .filter { tags.isEmpty || $0.tags.contains { $0.count >= 2 && $0[0] == "t" && tags.contains($0[1]) } }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
            for event in matches {
                frames.append("[\"EVENT\",\"\(subId)\",\(event.toJSON())]")
            }
        }
        frames.append("[\"EOSE\",\"\(subId)\"]")
        let isFeedPage = filter["search"] == nil && filter["#t"] == nil && filter["limit"] as? Int == FreshRelayClient.pageSize
        guard isFeedPage, feedDelay > .zero else {
            for frame in frames { continuation.yield(frame) }
            return
        }
        let continuation = self.continuation
        let delay = feedDelay
        Task {
            try? await Task.sleep(for: delay)
            for frame in frames { continuation.yield(frame) }
        }
    }

    func receive() async throws -> String {
        if iterator == nil { iterator = stream.makeAsyncIterator() }
        if let next = await iterator?.next() { return next }
        throw URLError(.networkConnectionLost)
    }

    func cancel() { continuation.finish() }
}
#endif
