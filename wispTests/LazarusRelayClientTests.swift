import Foundation
import Testing
@testable import wisp

/// Lazarus's scan-scoped sockets: every request ends in exactly one outcome
/// (answered / failed / timed out), events that arrived before a failure are
/// kept, NIP-42 `auth-required` gets one signed answer and one bounded
/// replay, and publishes report `OK` per relay. Driven through the
/// `GroupRelayTransport` seam with the fakes from `GroupRelayAuthTests`, so
/// frame ordering is deterministic and nothing touches the network.
struct LazarusRelayClientTests {

    private let relay = "wss://fake.lazarus.test"
    private let filter = LazarusFilter(kinds: [3], authors: [LazarusFixture.pubkey], limit: 50)

    // MARK: - Helpers

    private func eventually<T>(timeout: TimeInterval = 3, _ produce: () async -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = await produce() { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await produce()
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        await eventually(timeout: timeout) { condition() ? true : nil } ?? false
    }

    /// The subscription id of the `index`-th REQ the client sent.
    private func subId(of socket: FakeGroupSocket, index: Int = 0) -> String? {
        let reqs = socket.sent.filter { $0.hasPrefix("[\"REQ\"") }
        guard reqs.count > index,
              let data = reqs[index].data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [Any],
              frame.count >= 3 else { return nil }
        return frame[1] as? String
    }

    private func frames(_ socket: FakeGroupSocket, prefix: String) -> [String] {
        socket.sent.filter { $0.hasPrefix(prefix) }
    }

    private func eventFrame(_ subId: String, _ event: NostrEvent) -> String {
        "[\"EVENT\",\"\(subId)\",\(event.toJSON())]"
    }

    private func signer() throws -> LazarusRelayClient.AuthSigner {
        let keypair = try LazarusFixture.keypair()
        return { url, challenge in try? Nip42.buildAuthEvent(challenge: challenge, relayUrl: url, keypair: keypair) }
    }

    // MARK: - Outcomes

    @Test func answersOnEoseWithTheEventsSentAndClosesTheSubscription() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        let version = LazarusFixture.followList(3, 1000)
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed(eventFrame(sub, version))
        socket.feed("[\"EOSE\",\"\(sub)\"]")
        let result = await answer
        #expect(result.outcome == .answered)
        #expect(result.events.map(\.id) == [version.id])
        #expect(await waitUntil { !frames(socket, prefix: "[\"CLOSE\",\"\(sub)\"]").isEmpty })
    }

    @Test func anEoseWithNoEventsIsStillAnAnswer() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed("[\"EOSE\",\"\(sub)\"]")
        let result = await answer
        #expect(result.outcome == .answered)
        #expect(result.events.isEmpty)
    }

    @Test func failsWhenTheRelayClosesTheRequestKeepingEventsSentBefore() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        let version = LazarusFixture.followList(3, 1000)
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed(eventFrame(sub, version))
        socket.feed("[\"CLOSED\",\"\(sub)\",\"error: shutting down\"]")
        let result = await answer
        #expect(result.outcome == .failed)
        #expect(result.events.map(\.id) == [version.id])
    }

    @Test func failsWhenTheConnectionDropsKeepingEventsSentBefore() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        let version = LazarusFixture.followList(3, 1000)
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed(eventFrame(sub, version))
        // Let the event land before the socket goes.
        try await Task.sleep(for: .milliseconds(100))
        socket.dropConnection()
        let result = await answer
        #expect(result.outcome == .failed)
        #expect(result.events.map(\.id) == [version.id])
    }

    @Test func timesOutWithoutAnEoseAndClosesTheSubscription() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        let result = await client.query(relay: relay, filter: filter, timeout: 0.3)
        #expect(result.outcome == .timedOut)
        let socket = try #require(transport.latest)
        let sub = try #require(subId(of: socket))
        #expect(await waitUntil { !frames(socket, prefix: "[\"CLOSE\",\"\(sub)\"]").isEmpty })
    }

    @Test func aClientThatCantParseTheRelayUrlReportsAFailure() async {
        let client = LazarusRelayClient(transport: FakeGroupTransport(), authSigner: nil)
        #expect(await client.query(relay: "https://not-a-relay.example", filter: filter, timeout: 1).outcome == .failed)
    }

    @Test func reusesOneConnectionForSequentialRequests() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        for index in 0..<2 {
            async let answer = client.query(relay: relay, filter: filter, timeout: 5)
            let socket = try #require(await eventually { transport.latest })
            let sub = try #require(await eventually { subId(of: socket, index: index) })
            socket.feed("[\"EOSE\",\"\(sub)\"]")
            #expect(await answer.outcome == .answered)
        }
        #expect(transport.opened.count == 1)
    }

    /// Connection budget: an idle socket is released, and the next request
    /// opens a fresh one instead of failing on a socket the relay may have
    /// dropped.
    @Test func releasesAnIdleSocketAndReconnectsForTheNextRequest() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil, idleTimeout: 0.2)
        async let first = client.query(relay: relay, filter: filter, timeout: 5)
        let firstSocket = try #require(await eventually { transport.latest })
        let firstSub = try #require(await eventually { subId(of: firstSocket) })
        firstSocket.feed("[\"EOSE\",\"\(firstSub)\"]")
        #expect(await first.outcome == .answered)

        try await Task.sleep(for: .milliseconds(1300))
        async let second = client.query(relay: relay, filter: filter, timeout: 5)
        try #require(await waitUntil { transport.opened.count == 2 })
        let secondSocket = try #require(transport.latest)
        let secondSub = try #require(await eventually { subId(of: secondSocket) })
        secondSocket.feed("[\"EOSE\",\"\(secondSub)\"]")
        #expect(await second.outcome == .answered)
    }

    @Test func closingEndsPendingRequestsAsFailed() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        _ = try #require(await eventually { subId(of: socket) })
        await client.closeAll()
        #expect(await answer.outcome == .failed)
    }

    // MARK: - NIP-42

    /// `CLOSED auth-required` is not an answer: the client signs the relay's
    /// challenge once and sends the request once more.
    @Test func answersAuthRequiredWithOneSignedChallengeAndOneReplay() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: try signer())
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed("[\"AUTH\",\"challenge-1\"]")
        socket.feed("[\"CLOSED\",\"\(sub)\",\"auth-required: sign in first\"]")
        try #require(await waitUntil { socket.reqCount(subId: sub) == 2 })
        #expect(socket.sentAuthEventId != nil)
        socket.feed("[\"EOSE\",\"\(sub)\"]")
        #expect(await answer.outcome == .answered)
        #expect(frames(socket, prefix: "[\"AUTH\"").count == 1)
    }

    @Test func waitsForTheChallengeThatFollowsAnAuthRequiredRefusal() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: try signer())
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed("[\"CLOSED\",\"\(sub)\",\"auth-required: sign in first\"]")
        socket.feed("[\"AUTH\",\"challenge-2\"]")
        try #require(await waitUntil { socket.reqCount(subId: sub) == 2 })
        socket.feed("[\"EOSE\",\"\(sub)\"]")
        #expect(await answer.outcome == .answered)
    }

    /// Bounded: a refusal after the replay ends the request.
    @Test func failsARequestRefusedAgainAfterItsReplay() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: try signer())
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed("[\"AUTH\",\"challenge-3\"]")
        socket.feed("[\"CLOSED\",\"\(sub)\",\"auth-required: sign in first\"]")
        try #require(await waitUntil { socket.reqCount(subId: sub) == 2 })
        socket.feed("[\"CLOSED\",\"\(sub)\",\"auth-required: still no\"]")
        #expect(await answer.outcome == .failed)
        #expect(socket.reqCount(subId: sub) == 2)
    }

    @Test func failsAnAuthRequiredRefusalWhenTheAccountCantSign() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        async let answer = client.query(relay: relay, filter: filter, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed("[\"AUTH\",\"challenge-4\"]")
        socket.feed("[\"CLOSED\",\"\(sub)\",\"auth-required: sign in first\"]")
        #expect(await answer.outcome == .failed)
        #expect(frames(socket, prefix: "[\"AUTH\"").isEmpty)
    }

    @Test func failsAnAuthRequiredRefusalThatNoChallengeFollows() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: try signer())
        async let answer = client.query(relay: relay, filter: filter, timeout: 10)
        let socket = try #require(await eventually { transport.latest })
        let sub = try #require(await eventually { subId(of: socket) })
        socket.feed("[\"CLOSED\",\"\(sub)\",\"auth-required: sign in first\"]")
        let started = Date()
        #expect(await answer.outcome == .failed)
        // After the grace, well before the request's own timeout.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    // MARK: - Publish

    @Test func reportsWhetherTheRelayAcceptedOrRejectedAPublish() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: nil)
        let keypair = try LazarusFixture.keypair()
        let accepted = try LazarusFixture.signed(keypair, kind: 3, createdAt: 1000, tags: [["p", "a"]])
        let rejected = try LazarusFixture.signed(keypair, kind: 3, createdAt: 1001, tags: [["p", "b"]])

        async let first = client.publish(event: accepted, relay: relay, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        try #require(await waitUntil { frames(socket, prefix: "[\"EVENT\"").count == 1 })
        socket.feed("[\"OK\",\"\(accepted.id)\",true,\"\"]")
        #expect(await first == .accepted)

        async let second = client.publish(event: rejected, relay: relay, timeout: 5)
        try #require(await waitUntil { frames(socket, prefix: "[\"EVENT\"").count == 2 })
        socket.feed("[\"OK\",\"\(rejected.id)\",false,\"blocked: not on the allow list\"]")
        #expect(await second == .rejected(reason: "blocked: not on the allow list"))
    }

    @Test func signsInAndResendsAPublishRefusedWithAuthRequired() async throws {
        let transport = FakeGroupTransport()
        let client = LazarusRelayClient(transport: transport, authSigner: try signer())
        let keypair = try LazarusFixture.keypair()
        let event = try LazarusFixture.signed(keypair, kind: 3, createdAt: 1000, tags: [["p", "a"]])
        async let outcome = client.publish(event: event, relay: relay, timeout: 5)
        let socket = try #require(await eventually { transport.latest })
        try #require(await waitUntil { frames(socket, prefix: "[\"EVENT\"").count == 1 })
        socket.feed("[\"AUTH\",\"challenge-5\"]")
        socket.feed("[\"OK\",\"\(event.id)\",false,\"auth-required: members only\"]")
        try #require(await waitUntil { frames(socket, prefix: "[\"EVENT\"").count == 2 })
        socket.feed("[\"OK\",\"\(event.id)\",true,\"\"]")
        #expect(await outcome == .accepted)
    }

    @Test func aPublishWithNoAnswerTimesOut() async throws {
        let client = LazarusRelayClient(transport: FakeGroupTransport(), authSigner: nil)
        let keypair = try LazarusFixture.keypair()
        let event = try LazarusFixture.signed(keypair, kind: 3, createdAt: 1000)
        #expect(await client.publish(event: event, relay: relay, timeout: 0.3) == .timedOut)
    }

    // MARK: - Filter

    @Test func theFilterCarriesUntilOnlyWhenPaging() throws {
        func object(_ filter: LazarusFilter) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(filter.json.utf8)) as? [String: Any])
        }
        let first = try object(LazarusFilter(kinds: [3], authors: ["abc"], limit: 50))
        #expect(first["until"] == nil)
        #expect(first["limit"] as? Int == 50)
        #expect(first["kinds"] as? [Int] == [3])
        #expect(first["authors"] as? [String] == ["abc"])
        let paging = try object(LazarusFilter(kinds: [3], authors: ["abc"], limit: 50, until: 1020))
        #expect(paging["until"] as? Int == 1020)
    }
}
