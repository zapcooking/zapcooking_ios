import Foundation
import Testing
@testable import wisp

/// `FreshRelayClient` against the measured contract (build spec §2 "Fresh feed
/// relay — contract as measured"), driven through `FakeGroupTransport`. Each
/// test names the table row or rule it covers. Fixture events are really
/// signed with a throwaway key, since the client verifies every id and
/// signature. No test opens a socket.
@MainActor
@Suite(.serialized)
struct FreshRelayClientTests {

    // MARK: - Fixtures

    nonisolated private static let now = 1_800_000_000
    nonisolated private static let floor = now - FreshRelayClient.freeWindowSeconds

    private struct Author {
        let priv: Data
        let pubkey: String
        init() throws {
            priv = Schnorr.randomPrivkey()
            pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: priv))
        }
        func event(_ createdAt: Int, kind: Int = 1, content: String? = nil, tags: [[String]] = []) throws -> NostrEvent {
            try NostrEvent.sign(
                privkey32: priv, pubkey: pubkey, kind: kind, createdAt: createdAt,
                tags: tags, content: content ?? "post at \(createdAt) \(UUID().uuidString)"
            )
        }
    }

    private func makeClient(
        _ transport: FakeGroupTransport,
        timeout: TimeInterval = 5,
        center: NotificationCenter = NotificationCenter(),
        now: Int = FreshRelayClientTests.now
    ) -> FreshRelayClient {
        FreshRelayClient(
            transport: transport, now: { now }, silenceTimeout: timeout,
            notificationCenter: center, foregroundNotification: Self.foreground
        )
    }

    private static let foreground = Notification.Name("FreshRelayClientTests.foreground")

    private struct Req {
        let subId: String
        let filter: [String: Any]
        var since: Int? { filter["since"] as? Int }
        var until: Int? { filter["until"] as? Int }
        var limit: Int? { filter["limit"] as? Int }
        var kinds: [Int]? { filter["kinds"] as? [Int] }
        var search: String? { filter["search"] as? String }
        var tTags: [String]? { filter["#t"] as? [String] }
    }

    private func reqs(_ socket: FakeGroupSocket?) -> [Req] {
        (socket?.sent ?? []).compactMap { frame in
            guard frame.hasPrefix("[\"REQ\""),
                  let data = frame.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  array.count == 3, let subId = array[1] as? String,
                  let filter = array[2] as? [String: Any] else { return nil }
            return Req(subId: subId, filter: filter)
        }
    }

    private func allSent(_ transport: FakeGroupTransport) -> [String] {
        transport.opened.flatMap(\.sent)
    }

    /// Polls (in-process, no shell sleep) until `condition` holds.
    @discardableResult
    private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Waits for the `n`th REQ (1-based) on the transport's latest socket.
    private func awaitReq(_ transport: FakeGroupTransport, count n: Int = 1) async throws -> Req {
        let ok = await eventually { self.reqs(transport.latest).count >= n }
        try #require(ok, "REQ #\(n) never sent")
        return reqs(transport.latest)[n - 1]
    }

    private func eventFrame(_ subId: String, _ event: NostrEvent) -> String {
        "[\"EVENT\",\"\(subId)\",\(event.toJSON())]"
    }

    private func feed(_ socket: FakeGroupSocket?, _ subId: String, _ events: [NostrEvent], eose: Bool = true) {
        for event in events { socket?.feed(eventFrame(subId, event)) }
        if eose { socket?.feed("[\"EOSE\",\"\(subId)\"]") }
    }

    private func challenge(_ socket: FakeGroupSocket?) {
        socket?.feed("[\"AUTH\",\"challenge-\(UUID().uuidString)\"]")
    }

    /// `count` posts one second apart, newest first, ending at `newest`.
    private func posts(_ author: Author, newest: Int, count: Int) throws -> [NostrEvent] {
        try (0..<count).map { try author.event(newest - $0) }
    }

    // MARK: - Isolation

    @Test("connects only to wss://feed.zap.cooking and reuses one socket across requests")
    func oneSocketToTheFeedRelay() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        async let first = client.feedPage()
        let req1 = try await awaitReq(transport)
        feed(transport.latest, req1.subId, [])
        _ = await first
        async let second = client.topicPreview(slug: "pasta")
        let req2 = try await awaitReq(transport, count: 2)
        feed(transport.latest, req2.subId, [])
        _ = await second
        #expect(transport.opened.count == 1)
        #expect(FeedRelay.url == "wss://feed.zap.cooking")
    }

    @Test("the client source names no signer, keypair or AUTH event")
    func sourceHasNoSigner() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("wisp/FreshRelayClient.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for forbidden in ["Keypair", "Signer", "buildAuthEvent", "22242", "privkey"] {
            #expect(!text.contains(forbidden), "FreshRelayClient.swift mentions \(forbidden)")
        }
        // The only frames it builds.
        #expect(text.contains("[\\\"REQ\\\""))
        #expect(text.contains("[\\\"CLOSE\\\""))
        #expect(!text.contains("[\\\"AUTH\\\""))
    }

    @Test("no outgoing frame is AUTH or EVENT, even with a challenge before every answer and close")
    func neverSendsAuth() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()

        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        challenge(transport.latest)
        feed(transport.latest, req.subId, try posts(author, newest: Self.now - 10, count: 3))
        _ = await page

        async let refused = client.feedPage(until: Self.floor)
        let req2 = try await awaitReq(transport, count: 2)
        challenge(transport.latest)
        transport.latest?.feed("[\"CLOSED\",\"\(req2.subId)\",\"auth-required: posts older than 14 days are for Zap Cooking members; log in with NIP-42\"]")
        _ = await refused

        async let preview = client.topicPreview(slug: "pasta")
        let req3 = try await awaitReq(transport, count: 3)
        challenge(transport.latest)
        transport.latest?.feed("[\"CLOSED\",\"\(req3.subId)\",\"auth-required: topic: search beyond the preview is for Zap Cooking members; log in with NIP-42\"]")
        _ = await preview

        let tail = await client.liveTail(since: Self.now)
        _ = try await awaitReq(transport, count: 4)
        challenge(transport.latest)
        await client.stopTail()
        _ = tail

        let sent = allSent(transport)
        #expect(!sent.isEmpty)
        for frame in sent {
            #expect(!frame.hasPrefix("[\"AUTH\""), "sent \(frame)")
            #expect(frame.hasPrefix("[\"REQ\"") || frame.hasPrefix("[\"CLOSE\""), "sent \(frame)")
        }
    }

    // MARK: - Free window: feed pages

    @Test("row 1: first page asks kinds [1,30023,1068], since now−14d, limit 30; 30 events newest first")
    func firstPage() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        let events = try posts(author, newest: Self.now - 5, count: 30).shuffled()

        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        #expect(req.kinds == [1, 30023, 1068])
        #expect(req.since == Self.floor)
        #expect(req.limit == 30)
        #expect(req.until == nil)
        #expect(req.filter["#t"] == nil)
        feed(transport.latest, req.subId, events)
        let answer = await page

        #expect(answer.outcome == .answered)
        #expect(answer.events.count == 30)
        #expect(answer.events.map(\.createdAt) == answer.events.map(\.createdAt).sorted(by: >))
        #expect(!answer.isShortPage)
        #expect(answer.oldestCreatedAt == Self.now - 34)
        #expect(transport.latest?.sent.last == "[\"CLOSE\",\"\(req.subId)\"]")
    }

    @Test("row 2: next page with inclusive until repeats the boundary post once; it is dropped")
    func inclusiveUntilDropsBoundaryRepeat() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        let all = try posts(author, newest: Self.now - 5, count: 59)
        let first = Array(all[0..<30])
        let second = Array(all[29..<59]) // starts with the boundary post

        async let page1 = client.feedPage()
        let req1 = try await awaitReq(transport)
        feed(transport.latest, req1.subId, first)
        let answer1 = await page1
        let until = try #require(answer1.oldestCreatedAt)

        async let page2 = client.feedPage(until: until)
        let req2 = try await awaitReq(transport, count: 2)
        #expect(req2.until == until)
        #expect(req2.since == Self.floor)
        #expect(req2.kinds == [1, 30023, 1068])
        feed(transport.latest, req2.subId, second)
        let answer2 = await page2

        #expect(answer2.outcome == .answered)
        #expect(answer2.events.count == 29)
        #expect(Set(answer1.events.map(\.id)).isDisjoint(with: answer2.events.map(\.id)))
        #expect(!answer2.isShortPage)
    }

    @Test("row 3: the last page is short; asking again returns only the boundary post, dropped")
    func lastPageIsShort() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        let last = try posts(author, newest: Self.floor + 100, count: 7)

        async let page = client.feedPage(until: Self.floor + 100)
        let req = try await awaitReq(transport)
        feed(transport.latest, req.subId, last)
        let answer = await page
        #expect(answer.outcome == .answered)
        #expect(answer.events.count == 7)
        #expect(answer.isShortPage)

        let boundary = try #require(answer.oldestCreatedAt)
        async let again = client.feedPage(until: boundary)
        let req2 = try await awaitReq(transport, count: 2)
        feed(transport.latest, req2.subId, [try #require(last.last)])
        let answer2 = await again
        #expect(answer2.events.isEmpty)
        #expect(answer2.isShortPage)
    }

    @Test("row 4: until below the floor is .floor and sends nothing; until == floor is sent")
    func untilBelowFloorIsNotSent() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)

        let below = await client.feedPage(until: Self.floor - 1)
        #expect(below.outcome == .floor)
        #expect(below.events.isEmpty)
        #expect(transport.opened.isEmpty)

        async let at = client.feedPage(until: Self.floor)
        let req = try await awaitReq(transport)
        #expect(req.until == Self.floor)
        feed(transport.latest, req.subId, [])
        #expect(await at.outcome == .answered)
    }

    @Test("row 4: CLOSED auth-required on a feed page (relay clock ahead) is .floor, sent once, never AUTH")
    func authRequiredOnAPageIsTheFloor() async throws {
        let transport = FakeGroupTransport()
        // until is inside the device's window, but the relay's clock says the
        // floor has moved past it (a reader sat on the feed, or a slow clock).
        let client = makeClient(transport)
        async let page = client.feedPage(until: Self.floor + 3)
        let req = try await awaitReq(transport)
        challenge(transport.latest)
        transport.latest?.feed("[\"CLOSED\",\"\(req.subId)\",\"auth-required: posts older than 14 days are for Zap Cooking members; log in with NIP-42\"]")
        let answer = await page
        #expect(answer.outcome == .floor)
        // Give a retry, if there were one, time to go out.
        try await Task.sleep(for: .milliseconds(100))
        #expect(reqs(transport.latest).count == 1)
        #expect(!(transport.latest?.sent.contains { $0.hasPrefix("[\"CLOSE\"") } ?? true),
                "nothing to CLOSE after the relay's CLOSED")
    }

    @Test("rows 5–6: every feed request carries since (old long-form can't leak without it)")
    func everyFeedRequestCarriesSince() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        for (index, until) in [nil, Self.now - 100, Self.floor].enumerated() {
            async let page = client.feedPage(until: until)
            let req = try await awaitReq(transport, count: index + 1)
            #expect(req.since == Self.floor)
            feed(transport.latest, req.subId, [])
            _ = await page
        }
    }

    @Test("a full page all already shown asks the boundary second at max, then steps past it")
    func stepsPastAFullBoundarySecond() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport, now: Self.now)
        let author = try Author()
        let second = Self.now - 1000
        let sameSecond = try (0..<3).map { _ in try author.event(second) }

        // Page 1 shows all three.
        async let page1 = client.feedPage(limit: 3)
        let r1 = try await awaitReq(transport)
        feed(transport.latest, r1.subId, sameSecond)
        _ = await page1

        // Page 2 (limit 3, until = that second): all seen → limit 500 → all seen
        // and the relay is pretending 500 → until − 1.
        async let page2 = client.feedPage(until: second, limit: 3)
        let r2 = try await awaitReq(transport, count: 2)
        feed(transport.latest, r2.subId, sameSecond)
        let r3 = try await awaitReq(transport, count: 3)
        #expect(r3.limit == FreshRelayClient.maxLimit)
        #expect(r3.until == second)
        feed(transport.latest, r3.subId, sameSecond)
        let answer = await page2
        // Only 3 < 500 came back: the walk stops at the wide request.
        #expect(answer.events.isEmpty)
        #expect(answer.isShortPage)
        #expect(reqs(transport.latest).count == 3)
    }

    // MARK: - Topic preview

    @Test("preview: search topic:<slug>, since the floor, limit 5, no until")
    func previewRequest() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        async let preview = client.topicPreview(slug: "meat-seafood")
        let req = try await awaitReq(transport)
        #expect(req.search == "topic:meat-seafood")
        #expect(req.since == Self.floor)
        #expect(req.limit == FreshRelayClient.previewLimit)
        #expect(req.until == nil)
        #expect(req.kinds == [1, 30023, 1068])
        feed(transport.latest, req.subId, try posts(author, newest: Self.now - 50, count: 5))
        let answer = await preview
        #expect(answer.outcome == .answered)
        #expect(answer.events.count == 5)
    }

    @Test("preview: a topic with nothing in the window is answered with no events")
    func previewEmpty() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        async let preview = client.topicPreview(slug: "canning")
        let req = try await awaitReq(transport)
        feed(transport.latest, req.subId, [])
        let answer = await preview
        #expect(answer.outcome == .answered)
        #expect(answer.events.isEmpty)
    }

    @Test("preview: unknown slug → CLOSED invalid: is .invalid and is never sent again")
    func previewInvalidIsPermanent() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        async let first = client.topicPreview(slug: "no-such-topic")
        let req = try await awaitReq(transport)
        transport.latest?.feed("[\"CLOSED\",\"\(req.subId)\",\"invalid: unknown topic no-such-topic\"]")
        let answer = await first
        #expect(answer.outcome == .invalid(reason: "invalid: unknown topic no-such-topic"))

        let again = await client.topicPreview(slug: "no-such-topic")
        guard case .invalid = again.outcome else {
            Issue.record("expected .invalid, got \(again.outcome)")
            return
        }
        #expect(reqs(transport.latest).count == 1)

        // Other slugs are unaffected.
        async let other = client.topicPreview(slug: "pasta")
        let req2 = try await awaitReq(transport, count: 2)
        #expect(req2.search == "topic:pasta")
        feed(transport.latest, req2.subId, [])
        #expect(await other.outcome == .answered)
    }

    @Test("preview: CLOSED auth-required (a preview can't page) is .floor")
    func previewAuthRequiredIsFloor() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        async let preview = client.topicPreview(slug: "pasta")
        let req = try await awaitReq(transport)
        challenge(transport.latest)
        transport.latest?.feed("[\"CLOSED\",\"\(req.subId)\",\"auth-required: topic: search beyond the preview is for Zap Cooking members; log in with NIP-42\"]")
        #expect(await preview.outcome == .floor)
    }

    // MARK: - Recipes (long-form at any age)

    @Test("recipes: kind 30023 with #t zapcooking/nostrcooking, no since, limit 500, paged until short")
    func recipesPageAtAnyAge() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        let oldest = 1_694_000_000 // 2023-09, older than the floor
        let firstPage = try (0..<500).map { try author.event(Self.now - 10 - $0 * 1000, kind: 30023) }
        let boundary = try #require(firstPage.last)
        let secondPage = [boundary] + (try (0..<119).map { try author.event(oldest + $0, kind: 30023) })

        async let recipes = client.recipes()
        let r1 = try await awaitReq(transport)
        #expect(r1.kinds == [30023])
        #expect(r1.tTags == ["zapcooking", "nostrcooking"])
        #expect(r1.since == nil)
        #expect(r1.until == nil)
        #expect(r1.limit == 500)
        feed(transport.latest, r1.subId, firstPage)
        let r2 = try await awaitReq(transport, count: 2)
        #expect(r2.until == boundary.createdAt)
        #expect(r2.since == nil)
        #expect(r2.tTags == ["zapcooking", "nostrcooking"])
        feed(transport.latest, r2.subId, secondPage)
        let answer = await recipes

        #expect(answer.outcome == .answered)
        #expect(answer.events.count == 619)
        #expect(answer.events.last?.createdAt == oldest)
        #expect(reqs(transport.latest).count == 2)
    }

    // MARK: - Outcomes

    @Test("silence: .timedOut keeps the events that arrived")
    func timeoutKeepsPartialEvents() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport, timeout: 0.3)
        let author = try Author()
        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        feed(transport.latest, req.subId, try posts(author, newest: Self.now - 5, count: 12), eose: false)
        let answer = await page
        #expect(answer.outcome == .timedOut)
        #expect(answer.events.count == 12)
        #expect(answer.oldestCreatedAt == Self.now - 16)
        #expect(transport.latest?.sent.last == "[\"CLOSE\",\"\(req.subId)\"]")
    }

    @Test("silence: the timeout restarts with every event")
    func timeoutRestartsPerEvent() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport, timeout: 0.4)
        let author = try Author()
        let events = try posts(author, newest: Self.now - 5, count: 4)
        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        for event in events {
            try await Task.sleep(for: .milliseconds(250))
            transport.latest?.feed(eventFrame(req.subId, event))
        }
        transport.latest?.feed("[\"EOSE\",\"\(req.subId)\"]")
        let answer = await page
        #expect(answer.outcome == .answered)
        #expect(answer.events.count == 4)
    }

    @Test("a dropped connection mid-page is .failed and keeps the events that arrived; the next request reconnects")
    func dropKeepsPartialEvents() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        feed(transport.latest, req.subId, try posts(author, newest: Self.now - 5, count: 4), eose: false)
        try await Task.sleep(for: .milliseconds(50))
        transport.latest?.dropConnection()
        let answer = await page
        #expect(answer.outcome == .failed(reason: "connection lost"))
        #expect(answer.events.count == 4)

        let resumeAt = try #require(answer.oldestCreatedAt)
        async let next = client.feedPage(until: resumeAt)
        let ok = await eventually { transport.opened.count == 2 && !self.reqs(transport.latest).isEmpty }
        try #require(ok)
        feed(transport.latest, reqs(transport.latest)[0].subId, [])
        #expect(await next.outcome == .answered)
    }

    @Test("CLOSED with any other reason is .failed with the reason")
    func otherClosedIsFailed() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        transport.latest?.feed("[\"CLOSED\",\"\(req.subId)\",\"error: shutting down\"]")
        #expect(await page.outcome == .failed(reason: "error: shutting down"))
    }

    @Test("a bad id is dropped and counted")
    func badIdDropped() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        let good = try author.event(Self.now - 5)
        let signed = try author.event(Self.now - 6)
        // Valid signature over the original id, content changed after signing.
        let tampered = NostrEvent(id: signed.id, pubkey: signed.pubkey, kind: signed.kind,
                                  createdAt: signed.createdAt, tags: signed.tags,
                                  content: signed.content + " (edited)", sig: signed.sig)
        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        feed(transport.latest, req.subId, [good, tampered])
        let answer = await page
        #expect(answer.events.map(\.id) == [good.id])
        #expect(answer.received == 2)
        #expect(answer.rejected == 1)
    }

    @Test("a bad signature is dropped and counted")
    func badSigDropped() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        let other = try Author()
        let good = try author.event(Self.now - 5)
        let signed = try author.event(Self.now - 6)
        // The other key's signature over the same id: right id, wrong signer.
        let foreign = try other.event(Self.now - 6)
        let forged = NostrEvent(id: signed.id, pubkey: signed.pubkey, kind: signed.kind,
                                createdAt: signed.createdAt, tags: signed.tags,
                                content: signed.content, sig: foreign.sig)
        var flipped = Array(signed.sig)
        flipped[10] = flipped[10] == "0" ? "1" : "0"
        let corrupt = NostrEvent(id: signed.id, pubkey: signed.pubkey, kind: signed.kind,
                                 createdAt: signed.createdAt, tags: signed.tags,
                                 content: signed.content, sig: String(flipped))
        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        feed(transport.latest, req.subId, [good, forged, corrupt])
        let answer = await page
        #expect(answer.events.map(\.id) == [good.id])
        #expect(answer.rejected == 2)
    }

    @Test("verifier: a real signed event with escapes and tags verifies")
    func verifierAcceptsRealEvent() throws {
        let author = try Author()
        let event = try author.event(Self.now, kind: 30023, content: "line\n\"quoted\"\t\\ é 🍝",
                                     tags: [["d", "pasta"], ["t", "zapcooking"]])
        #expect(FreshEventVerifier.isValid(event))
        let roundTrip = try #require(NostrEvent.fromJSON(event.toJSON()))
        #expect(FreshEventVerifier.isValid(roundTrip))
    }

    // MARK: - Live tail

    @Test("tail: subscribes from since with the feed kinds; delivers new posts once, skipping ones on a page")
    func tailDeliversOnce() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        let onPage = try author.event(Self.now - 5)

        async let page = client.feedPage()
        let r1 = try await awaitReq(transport)
        feed(transport.latest, r1.subId, [onPage])
        _ = await page

        let box = TailBox()
        let recorder = box.record(await client.liveTail(since: Self.now))
        let tailReq = try await awaitReq(transport, count: 2)
        #expect(tailReq.since == Self.now)
        #expect(tailReq.kinds == [1, 30023, 1068])
        #expect(tailReq.until == nil)
        transport.latest?.feed("[\"EOSE\",\"\(tailReq.subId)\"]")
        let fresh = try author.event(Self.now + 2)
        feed(transport.latest, tailReq.subId, [onPage, fresh, fresh], eose: false)

        #expect(await eventually { box.eventIds == [fresh.id] })
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.eventIds == [fresh.id])
        await client.stopTail()
        await recorder.value
        #expect(transport.latest?.sent.last == "[\"CLOSE\",\"\(tailReq.subId)\"]")
    }

    @Test("tail: lost on a dropped socket, revived from the foreground hook with an overlap, de-duplicated by id")
    func tailLostAndRevivedWithOverlap() async throws {
        let transport = FakeGroupTransport()
        let center = NotificationCenter()
        let client = makeClient(transport, center: center)
        let author = try Author()

        let box = TailBox()
        let recorder = box.record(await client.liveTail(since: Self.now - 1200))
        let req = try await awaitReq(transport)
        transport.latest?.feed("[\"EOSE\",\"\(req.subId)\"]")
        let newest = try author.event(Self.now - 600)
        feed(transport.latest, req.subId, [newest], eose: false)
        #expect(await eventually { box.eventIds == [newest.id] })

        transport.latest?.dropConnection()
        #expect(await eventually { box.lostCount == 1 })
        #expect(await client.tailIsLost)

        center.post(name: Self.foreground, object: nil)
        let reopened = await eventually { transport.opened.count == 2 && !self.reqs(transport.latest).isEmpty }
        try #require(reopened)
        let resumed = reqs(transport.latest)[0]
        let expectedSince = Self.now - 600 - FreshRelayClient.tailResumeOverlapSeconds
        #expect(resumed.since == expectedSince)
        #expect(box.revivedSince == [expectedSince])
        #expect(await client.tailIsLost == false)

        // The relay re-sends what was already shown, plus a post admitted late:
        // created 827 s before the newest one seen (probe 2026-11-10).
        let late = try author.event(Self.now - 600 - 827)
        feed(transport.latest, resumed.subId, [newest, late])
        #expect(await eventually { box.eventIds == [newest.id, late.id] })

        await client.stopTail()
        await recorder.value
    }

    @Test("tail: a drop right after coming to the foreground revives at once, once")
    func tailDropJustAfterForegroundRevives() async throws {
        let transport = FakeGroupTransport()
        let center = NotificationCenter()
        let client = makeClient(transport, center: center)

        let box = TailBox()
        let recorder = box.record(await client.liveTail(since: Self.now))
        _ = try await awaitReq(transport)
        // Foreground while the tail still looks healthy: nothing to revive yet.
        await client.foregrounded()
        #expect(transport.opened.count == 1)
        // iOS reports the background socket's death after resume.
        transport.latest?.dropConnection()
        #expect(await eventually { transport.opened.count == 2 && !self.reqs(transport.latest).isEmpty })
        #expect(box.lostCount == 1)
        #expect(box.revivedSince.count == 1)
        // A second drop is not auto-revived (no loop on a relay that can't open).
        transport.latest?.dropConnection()
        #expect(await eventually { box.lostCount == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.opened.count == 2)
        await client.stopTail()
        await recorder.value
    }

    @Test("tail: revive does nothing while healthy or after stop; the foreground hook is inert then")
    func reviveIsInertWhenHealthyOrStopped() async throws {
        let transport = FakeGroupTransport()
        let center = NotificationCenter()
        let client = makeClient(transport, center: center)
        let box = TailBox()
        let recorder = box.record(await client.liveTail(since: Self.now))
        _ = try await awaitReq(transport)
        #expect(await client.reviveTail() == false)
        await client.stopTail()
        await recorder.value
        transport.latest?.dropConnection()
        center.post(name: Self.foreground, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await client.reviveTail() == false)
        #expect(reqs(transport.latest).count == 1)
        #expect(transport.opened.count == 1)
    }

    @Test("tail: since older than the floor is clamped to it")
    func tailSinceClampedToFloor() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let box = TailBox()
        let recorder = box.record(await client.liveTail(since: Self.floor - 5000))
        let req = try await awaitReq(transport)
        #expect(req.since == Self.floor)
        await client.stopTail()
        await recorder.value
    }

    @Test("tail: CLOSED auth-required ends it as .floor, with no retry and no AUTH")
    func tailRefusedIsEnded() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let box = TailBox()
        let recorder = box.record(await client.liveTail(since: Self.now))
        let req = try await awaitReq(transport)
        challenge(transport.latest)
        transport.latest?.feed("[\"CLOSED\",\"\(req.subId)\",\"auth-required: log in\"]")
        await recorder.value
        #expect(box.ended == [.floor])
        #expect(await client.reviveTail() == false)
        #expect(reqs(transport.latest).count == 1)
        #expect(!(transport.latest?.sent.contains { $0.hasPrefix("[\"AUTH\"") } ?? true))
    }

    // MARK: - Review rulings (2026-11-10)

    private func invalid(_ socket: FakeGroupSocket?, _ subId: String) {
        socket?.feed("[\"CLOSED\",\"\(subId)\",\"invalid: bad filter\"]")
    }

    @Test("invalid: on a feed page is reported, and the next feed page is sent again")
    func feedPageInvalidIsRetryable() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        async let first = client.feedPage()
        let req = try await awaitReq(transport)
        invalid(transport.latest, req.subId)
        #expect(await first.outcome == .invalid(reason: "invalid: bad filter"))

        async let second = client.feedPage()
        let req2 = try await awaitReq(transport, count: 2)
        #expect(req2.subId != req.subId)
        #expect(req2.since == Self.floor)
        let page = try posts(author, newest: Self.now - 10, count: 3)
        feed(transport.latest, req2.subId, page)
        let answer = await second
        #expect(answer.outcome == .answered)
        #expect(answer.events.map(\.id) == page.map(\.id))
    }

    @Test("invalid: on a recipes page is reported, and recipes are asked again")
    func recipesInvalidIsRetryable() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        async let first = client.recipes()
        let req = try await awaitReq(transport)
        invalid(transport.latest, req.subId)
        guard case .invalid = await first.outcome else {
            Issue.record("expected .invalid")
            return
        }
        async let second = client.recipes()
        let req2 = try await awaitReq(transport, count: 2)
        #expect(req2.tTags == FreshRelayClient.recipeTags)
        feed(transport.latest, req2.subId, [])
        #expect(await second.outcome == .answered)
    }

    @Test("invalid: on the tail ends it, and a new tail is sent again")
    func tailInvalidIsRetryable() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let box = TailBox()
        let recorder = box.record(await client.liveTail(since: Self.now))
        let req = try await awaitReq(transport)
        invalid(transport.latest, req.subId)
        await recorder.value
        #expect(box.ended == [.invalid(reason: "invalid: bad filter")])

        let box2 = TailBox()
        let recorder2 = box2.record(await client.liveTail(since: Self.now))
        let req2 = try await awaitReq(transport, count: 2)
        #expect(req2.since == Self.now)
        #expect(box2.ended.isEmpty)
        await client.stopTail()
        await recorder2.value
    }

    @Test("tail: a future-dated post can't move the resume point past now + 30 s")
    func tailNewestIsClampedToSkew() async throws {
        let transport = FakeGroupTransport()
        let center = NotificationCenter()
        let client = makeClient(transport, center: center)
        let author = try Author()
        let box = TailBox()
        let recorder = box.record(await client.liveTail(since: Self.now - 1200))
        let req = try await awaitReq(transport)
        let future = try author.event(Self.now + 86_400)
        let normal = try author.event(Self.now - 100)
        feed(transport.latest, req.subId, [future, normal], eose: false)
        #expect(await eventually { box.eventIds.count == 2 })

        transport.latest?.dropConnection()
        #expect(await eventually { box.lostCount == 1 })
        center.post(name: Self.foreground, object: nil)
        let reopened = await eventually { transport.opened.count == 2 && !self.reqs(transport.latest).isEmpty }
        try #require(reopened)
        let expected = Self.now + FreshRelayClient.futureSkewSeconds - FreshRelayClient.tailResumeOverlapSeconds
        #expect(reqs(transport.latest)[0].since == expected)
        #expect(box.revivedSince == [expected])
        await client.stopTail()
        await recorder.value
    }

    @Test("numbers too large for Int in an event from the relay drop the event; nothing traps")
    func outOfRangeNumbersAreDropped() async throws {
        let transport = FakeGroupTransport()
        let client = makeClient(transport)
        let author = try Author()
        async let page = client.feedPage()
        let req = try await awaitReq(transport)
        let good = try author.event(Self.now - 5)
        let base = good.toJSON()
        let hugeTime = base.replacingOccurrences(of: "\"created_at\":\(good.createdAt)", with: "\"created_at\":1e100")
        let hugeKind = base.replacingOccurrences(of: "\"kind\":1", with: "\"kind\":1e100")
        let fraction = base.replacingOccurrences(of: "\"created_at\":\(good.createdAt)", with: "\"created_at\":\(good.createdAt).5")
        #expect(hugeTime != base && hugeKind != base && fraction != base)
        for json in [hugeTime, hugeKind, fraction] {
            transport.latest?.feed("[\"EVENT\",\"\(req.subId)\",\(json)]")
        }
        feed(transport.latest, req.subId, [good])
        let answer = await page
        #expect(answer.outcome == .answered)
        #expect(answer.events.map(\.id) == [good.id])
        #expect(answer.rejected == 3)
    }
}

/// Records one tail stream.
nonisolated final class TailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _eventIds: [String] = []
    private var _lost = 0
    private var _revived: [Int] = []
    private var _ended: [FreshOutcome] = []

    func record(_ stream: AsyncStream<FreshTailUpdate>) -> Task<Void, Never> {
        Task {
            for await update in stream { self.append(update) }
        }
    }

    private func append(_ update: FreshTailUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update {
        case .event(let event): _eventIds.append(event.id)
        case .lost: _lost += 1
        case .revived(let since): _revived.append(since)
        case .ended(let outcome): _ended.append(outcome)
        }
    }

    var eventIds: [String] { lock.lock(); defer { lock.unlock() }; return _eventIds }
    var lostCount: Int { lock.lock(); defer { lock.unlock() }; return _lost }
    var revivedSince: [Int] { lock.lock(); defer { lock.unlock() }; return _revived }
    var ended: [FreshOutcome] { lock.lock(); defer { lock.unlock() }; return _ended }
}
