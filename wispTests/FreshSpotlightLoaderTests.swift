import Foundation
import Testing
@testable import wisp

/// `FreshSpotlightLoader` on fakes (ported from web `specialsLoader.test.ts`
/// and `specialsFlow.test.ts`, spotlight cases): a scripted preview per
/// slug, a hand-driven clock and timers. The last suite runs the loader
/// over the real `FreshRelayClient` on `FakeGroupTransport` and checks
/// every frame sent. Nothing opens a socket.
@MainActor
@Suite(.serialized)
struct FreshSpotlightLoaderTests {

    // MARK: - Fakes

    final class Clock {
        var now: TimeInterval = 1_000
    }

    /// Timers the test fires by hand.
    final class Timers {
        var pending: [(delay: TimeInterval, work: @MainActor () -> Void, cancelled: Bool)] = []
        var delays: [TimeInterval] { pending.filter { !$0.cancelled }.map(\.delay) }

        func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            pending.append((delay, work, false))
            let index = pending.count - 1
            return { [weak self] in self?.pending[index].cancelled = true }
        }

        /// Runs every live timer once.
        @MainActor func fireAll() {
            let live = pending.enumerated().filter { !$0.element.cancelled }
            for (i, timer) in live {
                pending[i].cancelled = true
                timer.work()
            }
        }
    }

    /// The relay's preview answers, by slug; anything not scripted is an
    /// empty answer.
    final class Previews {
        var answers: [String: FreshAnswer] = [:]
        var asked: [String] = []

        func answer(_ slug: String) -> FreshAnswer {
            asked.append(slug)
            return answers[slug] ?? FreshAnswer(events: [], outcome: .answered)
        }

        func posts(_ slug: String, _ n: Int = 5, images: Bool = false) {
            answers[slug] = FreshAnswer(events: (0..<n).map {
                FreshSpecialsTests.post("\(slug)-\($0)", pubkey: "\(slug)-author-\($0)",
                                        content: images ? "\(slug) https://img.example/\($0).jpg" : nil)
            }, outcome: .answered)
        }
    }

    struct Rig {
        let loader: FreshSpotlightLoader
        let previews: Previews
        let clock: Clock
        let timers: Timers
    }

    nonisolated static let twoGroups: [FreshTopicGroup] = [
        FreshTopicGroup(slug: "baking", name: "Baking", count14d: 0, topics: [
            FreshTopic(slug: "sourdough", name: "Sourdough", count14d: 0),
            FreshTopic(slug: "bread", name: "Bread", count14d: 0),
        ]),
        FreshTopicGroup(slug: "drinks", name: "Drinks", count14d: 0, topics: [
            FreshTopic(slug: "coffee", name: "Coffee", count14d: 0),
            FreshTopic(slug: "tea", name: "Tea", count14d: 0),
        ]),
    ]

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static func rig(
        groups: [FreshTopicGroup] = twoGroups,
        topics: (() async -> [FreshTopicGroup])? = nil,
        accept: @escaping (NostrEvent) -> Bool = { _ in true },
        shown: Box<Set<String>> = Box([]),
        exclude: Box<Set<String>> = Box([]),
        history: [String: Int] = [:],
        enabled: Box<Bool> = Box(true),
        onChange: @escaping () -> Void = {}
    ) -> Rig {
        let previews = Previews()
        let clock = Clock()
        let timers = Timers()
        let seeded = FreshSpecialsTests.Seeded(7)
        let loader = FreshSpotlightLoader(.init(
            preview: { previews.answer($0) },
            topics: topics ?? { groups },
            accept: accept,
            shown: { shown.value },
            exclude: { exclude.value },
            topicHistory: { history },
            rng: seeded.rng,
            clock: { clock.now },
            schedule: { timers.schedule($0, $1) },
            onChange: onChange,
            enabled: { enabled.value }
        ))
        return Rig(loader: loader, previews: previews, clock: clock, timers: timers)
    }

    static func topicSlug(_ card: FreshSpecial?) -> String? {
        if case .spotlight(let topic, _) = card { return topic.slug }
        return nil
    }

    static func postIds(_ card: FreshSpecial?) -> [String] {
        if case .spotlight(_, let posts) = card { return posts.map(\.id) }
        return []
    }

    // MARK: - Keeping one ready

    @Test("prepare keeps one spotlight ready: 3 posts from one topic, its topic used")
    func preparesOne() async {
        let rig = Self.rig()
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        await rig.loader.prepare()
        let slug = Self.topicSlug(rig.loader.ready)
        #expect(slug != nil)
        #expect(Self.postIds(rig.loader.ready).count == FreshSpecialsConfig.spotlightPosts)
        #expect(rig.previews.asked.count == 1)
        #expect(rig.loader.usedTopics == [slug ?? "-"])
        #expect(rig.timers.delays.isEmpty, "nothing to retry while one is ready")
        // A second prepare with one ready asks nothing.
        await rig.loader.prepare()
        #expect(rig.previews.asked.count == 1)
    }

    @Test("take hands over the card and starts the next build, from another parent group")
    func takeStartsTheNext() async {
        let rig = Self.rig()
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        await rig.loader.prepare()
        let first = rig.loader.take()
        #expect(first != nil)
        #expect(rig.loader.ready == nil)
        await Self.eventually { rig.loader.ready != nil }  // take's own kick
        let firstGroup = ["sourdough", "bread"].contains(Self.topicSlug(first) ?? "") ? "baking" : "drinks"
        let second = Self.topicSlug(rig.loader.ready) ?? ""
        let secondGroup = ["sourdough", "bread"].contains(second) ? "baking" : "drinks"
        #expect(firstGroup != secondGroup)
    }

    @Test("take drops a ready card whose post reached the feed since it was built")
    func takeRechecksExclusions() async {
        let exclude = Box<Set<String>>([])
        let rig = Self.rig(exclude: exclude)
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        await rig.loader.prepare()
        exclude.value = [Self.postIds(rig.loader.ready)[0]]
        #expect(rig.loader.take() == nil)
        #expect(rig.loader.ready == nil)
    }

    // MARK: - What each answer does

    @Test("an invalid: topic is added to the used set and the next topic is tried in the same build")
    func invalidTopicIsUsed() async {
        let rig = Self.rig(groups: [Self.twoGroups[0]])
        rig.previews.answers["sourdough"] = FreshAnswer(events: [], outcome: .invalid(reason: "invalid: unknown topic"))
        rig.previews.answers["bread"] = FreshAnswer(events: [], outcome: .invalid(reason: "invalid: unknown topic"))
        await rig.loader.prepare()
        #expect(rig.loader.ready == nil)
        #expect(Set(rig.previews.asked) == ["sourdough", "bread"])
        #expect(rig.loader.usedTopics == ["sourdough", "bread"])
        // Both used: the type is out for the session, and nothing is retried.
        await rig.loader.prepare()
        #expect(rig.loader.isOut)
        #expect(rig.previews.asked.count == 2)
        #expect(rig.timers.delays.isEmpty)
    }

    @Test("a thin topic (under 3 eligible posts) is used for the session and the next is tried")
    func thinTopicIsSkipped() async {
        let rig = Self.rig(groups: [Self.twoGroups[0]])
        rig.previews.posts("sourdough", 2)
        rig.previews.posts("bread", 2)
        await rig.loader.prepare()
        #expect(rig.loader.ready == nil)
        #expect(rig.loader.usedTopics == ["sourdough", "bread"])
    }

    @Test("posts the reader hides, was shown before, or already sees don't count toward a topic")
    func eligibilityFilters() async {
        let shown = Box<Set<String>>(["sourdough-0"])
        let exclude = Box<Set<String>>(["sourdough-1"])
        let onlySourdough = [FreshTopicGroup(slug: "baking", name: "Baking", count14d: 0, topics: [
            FreshTopic(slug: "sourdough", name: "Sourdough", count14d: 0),
        ])]
        let rig = Self.rig(groups: onlySourdough, accept: { $0.id != "sourdough-2" },
                           shown: shown, exclude: exclude)
        rig.previews.posts("sourdough", 5)  // 0 shown, 1 on screen, 2 hidden → 2 left: thin
        await rig.loader.prepare()
        #expect(rig.loader.ready == nil)
        #expect(rig.loader.usedTopics == ["sourdough"])

        // The control: nothing filtered, the same answer fills the card.
        let open = Self.rig(groups: onlySourdough)
        open.previews.posts("sourdough", 5)
        await open.loader.prepare()
        #expect(Self.postIds(open.loader.ready).count == 3)
    }

    @Test("a refused preview (auth-required:) starts the hold, marks nothing, and retries when it ends")
    func refusedPreviewHolds() async {
        let rig = Self.rig()
        for slug in ["sourdough", "bread", "coffee", "tea"] {
            rig.previews.answers[slug] = FreshAnswer(events: [], outcome: .floor)
        }
        await rig.loader.prepare()
        #expect(rig.loader.ready == nil)
        #expect(rig.previews.asked.count == 1, "the build stops at the refusal")
        #expect(rig.loader.usedTopics.isEmpty)
        #expect(rig.loader.previewHoldLeft() == 60)
        #expect(rig.timers.delays == [60.05])
        // During the hold nothing is asked, and nothing may take the slot.
        await rig.loader.prepare()
        #expect(rig.previews.asked.count == 1)
        #expect(!rig.loader.isAvailable(strict: true))
    }

    @Test("restricted: is a refusal too")
    func restrictedIsRefusal() {
        #expect(FreshSpotlightLoader.isRefusal(.floor))
        #expect(FreshSpotlightLoader.isRefusal(.failed(reason: "restricted: held")))
        #expect(!FreshSpotlightLoader.isRefusal(.failed(reason: "error: boom")))
        #expect(!FreshSpotlightLoader.isRefusal(.invalid(reason: "invalid: x")))
        #expect(!FreshSpotlightLoader.isRefusal(.timedOut))
        #expect(!FreshSpotlightLoader.isRefusal(.answered))
    }

    @Test("refusals in a row back off 60 s, 120, 240, 480, then 600 s; an answer ends the hold")
    func holdBacksOff() async {
        let rig = Self.rig()
        for slug in ["sourdough", "bread", "coffee", "tea"] {
            rig.previews.answers[slug] = FreshAnswer(events: [], outcome: .floor)
        }
        var holds: [TimeInterval] = []
        for _ in 0..<6 {
            await rig.loader.prepare()
            let hold = rig.loader.previewHoldLeft()
            holds.append(hold)
            rig.clock.now += hold
        }
        #expect(holds == [60, 120, 240, 480, 600, 600])
        // Served: the backoff starts over.
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        await rig.loader.prepare()
        #expect(rig.loader.ready != nil)
        #expect(rig.loader.previewHoldLeft() == 0)
        _ = rig.loader.take()
        for slug in ["sourdough", "bread", "coffee", "tea"] {
            rig.previews.answers[slug] = FreshAnswer(events: [], outcome: .floor)
        }
        await rig.loader.prepare()
        #expect(rig.loader.previewHoldLeft() == 60)
    }

    @Test("a failed or timed-out preview stops the build, marks nothing, and retries in 15 s")
    func failedPreviewRetries() async {
        let rig = Self.rig()
        for slug in ["sourdough", "bread", "coffee", "tea"] {
            rig.previews.answers[slug] = FreshAnswer(events: [], outcome: .timedOut)
        }
        await rig.loader.prepare()
        #expect(rig.previews.asked.count == 1)
        #expect(rig.loader.usedTopics.isEmpty)
        #expect(rig.loader.previewHoldLeft() == 0)
        #expect(rig.timers.delays == [15])
        // The timer fires: another build (answered this time).
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        rig.timers.fireAll()
        await Self.eventually { rig.loader.ready != nil }
        #expect(rig.loader.ready != nil)
    }

    @Test("one build tries at most 4 topics")
    func maxTopicTries() async {
        var groups: [FreshTopicGroup] = []
        for g in 0..<6 {
            groups.append(FreshTopicGroup(slug: "g\(g)", name: "G\(g)", count14d: 0, topics: [
                FreshTopic(slug: "t\(g)", name: "T\(g)", count14d: 0),
            ]))
        }
        let rig = Self.rig(groups: groups)  // every topic empty: thin
        await rig.loader.prepare()
        #expect(rig.previews.asked.count == FreshSpecialsConfig.maxTopicTries)
        #expect(rig.timers.delays == [15])
    }

    // MARK: - No topic list

    @Test("no topic list (a failed NIP-11 fetch): no preview asked, no spotlight, nothing thrown")
    func noTopicListNoSpotlights() async {
        let rig = Self.rig(groups: [])
        await rig.loader.prepare()
        #expect(rig.loader.ready == nil)
        #expect(rig.previews.asked.isEmpty)
        #expect(!rig.loader.isAvailable(strict: true))
        #expect(!rig.loader.isAvailable(strict: false))
    }

    // MARK: - The rotation

    @Test("when no spotlight can be filled, the rotation gives that turn to a recipe-box card")
    func recipeTakesTheTurn() async {
        let rig = Self.rig(groups: [])
        await rig.loader.prepare()
        for strict in [false, true] {
            var rotation = FreshRotation()
            var picked: [FreshSpecialType?] = []
            for _ in 0..<4 {
                let t = rotation.choose(ready: { $0 == .recipe || rig.loader.ready != nil },
                                        strict: strict,
                                        available: { $0 == .recipe || rig.loader.isAvailable(strict: strict) })
                if let t { rotation.record(t) }
                picked.append(t)
            }
            #expect(picked == [.recipe, .recipe, .recipe, .recipe], "strict: \(strict)")
        }
    }

    @Test("with a spotlight ready the rotation alternates recipe, spotlight")
    func alternatesWhenReady() async {
        let rig = Self.rig()
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        await rig.loader.prepare()
        var rotation = FreshRotation()
        var picked: [FreshSpecialType] = []
        for _ in 0..<4 {
            await Self.eventually { !rig.loader.isBuilding && rig.loader.ready != nil }
            let t = rotation.choose(ready: { $0 == .recipe || rig.loader.ready != nil },
                                    available: { $0 == .recipe || rig.loader.isAvailable(strict: false) })
            guard let t else { break }
            rotation.record(t)
            picked.append(t)
            if t == .spotlight { _ = rig.loader.take() }
        }
        #expect(picked == [.recipe, .spotlight, .recipe, .spotlight])
    }

    @Test("a slot far below waits for a spotlight that is still building; near the screen it doesn't")
    func strictWaitsForABuild() async {
        let gate = Box<CheckedContinuation<Void, Never>?>(nil)
        let rig = Self.rig(topics: {
            await withCheckedContinuation { gate.value = $0 }
            return Self.twoGroups
        })
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        let build = Task { await rig.loader.prepare() }
        await Self.eventually { gate.value != nil }
        #expect(rig.loader.isBuilding)
        #expect(rig.loader.isAvailable(strict: true))
        #expect(!rig.loader.isAvailable(strict: false))
        gate.value?.resume()
        await build.value
        #expect(rig.loader.isAvailable(strict: false))
    }

    @Test("a build kicked but not yet started already holds a far slot (no race with the first slot decision)")
    func kickedBuildCountsAsBuilding() async {
        let rig = Self.rig()
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        rig.loader.kick()
        // Nothing has run yet: same turn of the main actor.
        #expect(rig.loader.isAvailable(strict: true))
        #expect(!rig.loader.isAvailable(strict: false))
        await Self.eventually { rig.loader.ready != nil }
        #expect(rig.loader.isAvailable(strict: false))
    }

    // MARK: - Flag and lifetime

    @Test("disabled (the flag): no topic list asked, no preview, no timer")
    func disabledAsksNothing() async {
        let topicsAsked = Box(0)
        let rig = Self.rig(topics: { topicsAsked.value += 1; return Self.twoGroups }, enabled: Box(false))
        await rig.loader.prepare()
        #expect(topicsAsked.value == 0)
        #expect(rig.previews.asked.isEmpty)
        #expect(rig.timers.pending.isEmpty)
        #expect(!rig.loader.isAvailable(strict: true))
    }

    @Test("dispose cancels the pending retry and stops later builds")
    func disposeStops() async {
        let rig = Self.rig()
        await rig.loader.prepare()  // all empty → thin… retry in 15 s
        #expect(rig.timers.delays == [15])
        rig.loader.dispose()
        #expect(rig.timers.delays.isEmpty)
        let asked = rig.previews.asked.count
        await rig.loader.prepare()
        #expect(rig.previews.asked.count == asked)
    }

    @Test("onChange fires after each build, ready or not")
    func onChangeFires() async {
        let changes = Box(0)
        let rig = Self.rig(onChange: { changes.value += 1 })
        await rig.loader.prepare()
        #expect(changes.value == 1)
        for slug in ["sourdough", "bread", "coffee", "tea"] { rig.previews.posts(slug) }
        rig.timers.fireAll()
        await Self.eventually { changes.value == 2 }
        #expect(changes.value == 2)
    }

    @Test("the loader's source names no signer, keypair, AUTH frame or HTTP auth")
    func sourceHasNoSigner() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["wisp/FreshSpotlightLoader.swift", "wisp/FreshTopicList.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["Keypair", "Signer", "buildAuthEvent", "22242", "privkey", "Nip98",
                              "[\\\"AUTH\\\"", "Authorization", "Cookie\""] {
                #expect(!text.contains(forbidden), "\(file) mentions \(forbidden)")
            }
        }
    }

    static func eventually(_ seconds: Double = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The loader over the real `FreshRelayClient` on a fake socket: the relay
/// challenges on connect and before every refusal, as measured. Every frame
/// the app sends must be a REQ or a CLOSE.
@MainActor
@Suite(.serialized)
struct FreshSpotlightLoaderRelayTests {
    nonisolated private static let now = 1_800_000_000

    private struct Author {
        let priv: Data
        let pubkey: String
        init() throws {
            priv = Schnorr.randomPrivkey()
            pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: priv))
        }
        func event(_ createdAt: Int) throws -> NostrEvent {
            try NostrEvent.sign(privkey32: priv, pubkey: pubkey, kind: 1, createdAt: createdAt,
                                tags: [], content: "post \(UUID().uuidString)")
        }
    }

    private func reqs(_ socket: FakeGroupSocket?) -> [(subId: String, search: String?)] {
        (socket?.sent ?? []).compactMap { frame in
            guard frame.hasPrefix("[\"REQ\""),
                  let data = frame.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  array.count == 3, let subId = array[1] as? String,
                  let filter = array[2] as? [String: Any] else { return nil }
            return (subId, filter["search"] as? String)
        }
    }

    private func awaitReq(_ transport: FakeGroupTransport, count n: Int) async throws -> (subId: String, search: String?) {
        await FreshSpotlightLoaderTests.eventually(3) { self.reqs(transport.latest).count >= n }
        let all = reqs(transport.latest)
        try #require(all.count >= n, "REQ #\(n) never sent")
        return all[n - 1]
    }

    @Test("no frame starts with [\"AUTH\": challenges and auth-required: refusals are answered with nothing but REQ and CLOSE")
    func neverSendsAuth() async throws {
        let transport = FakeGroupTransport()
        let client = FreshRelayClient(
            transport: transport, now: { Self.now }, silenceTimeout: 5,
            notificationCenter: NotificationCenter(), foregroundNotification: Notification.Name("FreshSpotlightLoaderRelayTests")
        )
        let clock = FreshSpotlightLoaderTests.Clock()
        let timers = FreshSpotlightLoaderTests.Timers()
        let loader = FreshSpotlightLoader(.init(
            preview: { await client.topicPreview(slug: $0) },
            topics: { FreshSpotlightLoaderTests.twoGroups },
            accept: { _ in true },
            shown: { [] },
            exclude: { [] },
            topicHistory: { [:] },
            rng: FreshSpecialsTests.Seeded(3).rng,
            clock: { clock.now },
            schedule: { timers.schedule($0, $1) },
            enabled: { true }
        ))

        // 1. Connect: the relay challenges, then refuses the preview with
        //    another challenge first (the measured order).
        let build1 = Task { await loader.prepare() }
        let req1 = try await awaitReq(transport, count: 1)
        #expect(req1.search?.hasPrefix("topic:") == true)
        let socket = transport.latest
        socket?.feed("[\"AUTH\",\"challenge-1\"]")
        socket?.feed("[\"AUTH\",\"challenge-2\"]")
        socket?.feed("[\"CLOSED\",\"\(req1.subId)\",\"auth-required: members only\"]")
        await build1.value
        #expect(loader.ready == nil)
        #expect(loader.previewHoldLeft() == 60)
        #expect(loader.usedTopics.isEmpty)

        // 2. The hold ends; the retry asks again and the relay answers.
        clock.now += 61
        let build2 = Task { await loader.prepare() }
        let req2 = try await awaitReq(transport, count: 2)
        socket?.feed("[\"AUTH\",\"challenge-3\"]")
        let authors = try (0..<3).map { _ in try Author() }
        for (i, author) in authors.enumerated() {
            let e = try author.event(Self.now - 100 - i)
            socket?.feed("[\"EVENT\",\"\(req2.subId)\",\(e.toJSON())]")
        }
        socket?.feed("[\"EOSE\",\"\(req2.subId)\"]")
        await build2.value
        #expect(loader.ready != nil)

        let sent = transport.opened.flatMap(\.sent)
        #expect(!sent.isEmpty)
        for frame in sent {
            #expect(!frame.hasPrefix("[\"AUTH\""), "sent \(frame)")
            #expect(frame.hasPrefix("[\"REQ\"") || frame.hasPrefix("[\"CLOSE\""), "unexpected frame \(frame)")
        }
        await client.close()
    }
}
