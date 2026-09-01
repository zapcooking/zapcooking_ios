import Foundation
import Testing
@testable import wisp

/// Issue #6 — hermetic NIP-42 state-machine tests for `GroupRelayPool`, driven
/// through the `GroupRelayTransport` seam so frame ordering (REQ / AUTH / OK /
/// CLOSED) is deterministic. Each test states the pre-fix behavior it fails on.
///
/// Pre-fix reference points (old `GroupRelayPool.swift`, main @ 2be233f):
///  - `:336` set `isAuthenticated = true` the moment the AUTH frame was sent;
///  - `:305-318` replayed on every CLOSED — after a fixed 2s for
///    `auth-required`, immediately (an unbounded hot loop) for everything else;
///  - `:196-198` replayed all filters on reconnect before the reader existed;
///  - the relay's `OK` for the kind-22242 event was never parsed;
///  - watch-only subs stayed open and silently empty forever.

// MARK: - Fakes

nonisolated final class FakeGroupSocket: GroupRelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private let stream: AsyncStream<String>
    private let feedCont: AsyncStream<String>.Continuation
    private var iterator: AsyncStream<String>.AsyncIterator?

    init() {
        var c: AsyncStream<String>.Continuation!
        stream = AsyncStream { c = $0 }
        feedCont = c
    }

    func resume() {}

    func send(_ text: String) {
        lock.lock(); _sent.append(text); lock.unlock()
    }

    func receive() async throws -> String {
        if iterator == nil { iterator = stream.makeAsyncIterator() }
        if let next = await iterator?.next() { return next }
        throw URLError(.networkConnectionLost)
    }

    func cancel() { feedCont.finish() }

    // Test controls
    func feed(_ frame: String) { feedCont.yield(frame) }
    /// Simulate the transport dropping (receive() will throw).
    func dropConnection() { feedCont.finish() }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    func reqCount(subId: String) -> Int {
        sent.filter { $0.hasPrefix("[\"REQ\",\"\(subId)\"") }.count
    }
    var sentAuthEventId: String? {
        for frame in sent where frame.hasPrefix("[\"AUTH\"") {
            if let data = frame.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
               arr.count >= 2, let obj = arr[1] as? [String: Any] {
                return obj["id"] as? String
            }
        }
        return nil
    }
}

nonisolated final class FakeGroupTransport: GroupRelayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [FakeGroupSocket] = []

    func open(url: URL) -> GroupRelaySocket {
        let socket = FakeGroupSocket()
        lock.lock(); _opened.append(socket); lock.unlock()
        return socket
    }

    var opened: [FakeGroupSocket] { lock.lock(); defer { lock.unlock() }; return _opened }
    var latest: FakeGroupSocket? { opened.last }
}

/// Thread-safe recorder for one subscription stream.
nonisolated final class SubEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [GroupSubEvent] = []
    private var _finished = false

    func record(_ stream: AsyncStream<GroupSubEvent>) -> Task<Void, Never> {
        Task {
            for await item in stream { self.append(item) }
            self.markFinished()
        }
    }

    private func append(_ item: GroupSubEvent) {
        lock.lock(); _items.append(item); lock.unlock()
    }

    private func markFinished() {
        lock.lock(); _finished = true; lock.unlock()
    }

    var items: [GroupSubEvent] { lock.lock(); defer { lock.unlock() }; return _items }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
}

// MARK: - Helpers

private let fakeRelayURL = "wss://fake.relay.test"

private func makeKeypair() throws -> Keypair {
    let priv = Schnorr.randomPrivkey()
    let pub = try Schnorr.xonlyPubkey(privkey32: priv)
    return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
}

private func watchOnlyKeypair() throws -> Keypair {
    // The pool classifies watch-only by the empty privkey sentinel
    // (`NostrKey.saveWatchOnly` shape) — no UserDefaults involved.
    let priv = Schnorr.randomPrivkey()
    let pub = try Schnorr.xonlyPubkey(privkey32: priv)
    return Keypair(privkey: "", pubkey: Hex.encode(pub))
}

@discardableResult
private func eventually(timeout: TimeInterval = 3,
                        _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

private func groupFilter() -> NostrFilter {
    var filter = NostrFilter()
    filter.kinds = [9]
    filter.hTags = ["test-group"]
    return filter
}

private func closedFrame(_ subId: String, _ reason: String) -> String {
    "[\"CLOSED\",\"\(subId)\",\"\(reason)\"]"
}

// MARK: - Tests

@Suite @MainActor struct GroupRelayAuthTests {

    /// Defect 3: sending the AUTH event must not authenticate the connection.
    /// Pre-fix failure: `isAuthenticated` flipped true at send (`:336`), before
    /// any relay verdict.
    @Test func authSent_withoutOK_staysPending() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(fakeRelayURL, keypair: try makeKeypair())
        let socket = try #require(transport.latest)

        socket.feed("[\"AUTH\",\"challenge-1\"]")
        #expect(await eventually { socket.sentAuthEventId != nil })

        let authId = try #require(socket.sentAuthEventId)
        #expect(await pool.authState(relayUrl: fakeRelayURL) == .pending(authEventId: authId))
    }

    /// The relay's `OK true` for the retained AUTH event id — and nothing else
    /// — authenticates. Pre-fix failure: the OK for the kind-22242 event was
    /// never parsed at all.
    @Test func authOKTrue_marksAuthenticated() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(fakeRelayURL, keypair: try makeKeypair())
        let socket = try #require(transport.latest)

        socket.feed("[\"AUTH\",\"challenge-1\"]")
        #expect(await eventually { socket.sentAuthEventId != nil })
        let authId = try #require(socket.sentAuthEventId)

        socket.feed("[\"OK\",\"\(authId)\",true,\"\"]")
        #expect(await eventually { await pool.authState(relayUrl: fakeRelayURL) == .authenticated })
    }

    /// `OK false` is a terminal auth failure for the connection: the parked
    /// subscription ends with `.authFailed(reason)` and no replay is sent.
    /// Pre-fix failure: the rejection was invisible (flag already true) and
    /// the CLOSED handler kept replaying every 2s forever.
    @Test func authOKFalse_terminalAuthFailed_noReplay() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(fakeRelayURL, keypair: try makeKeypair())
        let socket = try #require(transport.latest)

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: fakeRelayURL, filter: groupFilter(), subId: "s1")
        let recorder = box.record(stream)
        defer { recorder.cancel() }
        #expect(await eventually { socket.reqCount(subId: "s1") == 1 })

        socket.feed("[\"AUTH\",\"challenge-1\"]")
        #expect(await eventually { socket.sentAuthEventId != nil })
        let authId = try #require(socket.sentAuthEventId)
        socket.feed(closedFrame("s1", "auth-required: please authenticate"))
        socket.feed("[\"OK\",\"\(authId)\",false,\"error: failed to authenticate\"]")

        #expect(await eventually { box.finished })
        guard case .authFailed(let reason)? = box.items.last else {
            Issue.record("expected terminal .authFailed, got \(box.items)")
            return
        }
        #expect(reason == "error: failed to authenticate")
        #expect(await pool.authState(relayUrl: fakeRelayURL) == .failed(reason: "error: failed to authenticate"))
        #expect(socket.reqCount(subId: "s1") == 1)
    }

    /// Defect 2: `CLOSED auth-required` parks the sub until AUTH is *accepted*,
    /// then replays — no wall-clock timer. Pre-fix failure: the replay fired
    /// after a fixed 2s sleep regardless of auth progress, so this test's
    /// 2.5s quiet window would see a premature REQ.
    @Test func closedAuthRequired_replaysOnlyAfterAcceptance() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(fakeRelayURL, keypair: try makeKeypair())
        let socket = try #require(transport.latest)

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: fakeRelayURL, filter: groupFilter(), subId: "s1")
        let recorder = box.record(stream)
        defer { recorder.cancel() }
        #expect(await eventually { socket.reqCount(subId: "s1") == 1 })

        socket.feed("[\"AUTH\",\"challenge-1\"]")
        socket.feed(closedFrame("s1", "auth-required: please authenticate"))
        #expect(await eventually { socket.sentAuthEventId != nil })

        // Pre-fix, the 2s timer replay lands inside this window.
        try? await Task.sleep(for: .seconds(2.5))
        #expect(socket.reqCount(subId: "s1") == 1, "no replay may fire before the relay accepts AUTH")

        let authId = try #require(socket.sentAuthEventId)
        socket.feed("[\"OK\",\"\(authId)\",true,\"\"]")
        #expect(await eventually { socket.reqCount(subId: "s1") == 2 })
        #expect(!box.finished)
    }

    /// F-6: `CLOSED restricted:` gets exactly one replay, then the terminal
    /// `.notMember` state. Pre-fix failure: every non-auth CLOSED replayed
    /// immediately and unboundedly — a hot loop at network RTT rate.
    @Test func closedRestricted_exactlyOneReplay_thenNotMember() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(fakeRelayURL, keypair: try makeKeypair())
        let socket = try #require(transport.latest)

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: fakeRelayURL, filter: groupFilter(), subId: "s1")
        let recorder = box.record(stream)
        defer { recorder.cancel() }
        #expect(await eventually { socket.reqCount(subId: "s1") == 1 })

        socket.feed(closedFrame("s1", "restricted: membership required to access group content"))
        #expect(await eventually { socket.reqCount(subId: "s1") == 2 })
        #expect(!box.finished)

        socket.feed(closedFrame("s1", "restricted: membership required to access group content"))
        #expect(await eventually { box.finished })
        guard case .notMember(let reason)? = box.items.last else {
            Issue.record("expected terminal .notMember, got \(box.items)")
            return
        }
        #expect(reason.hasPrefix("restricted"))

        // No further REQs after the terminal state.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(socket.reqCount(subId: "s1") == 2)
    }

    /// Defect 4: on reconnect the reader consumes frames from the start, auth
    /// state is fresh, and the post-auth replay is ordered after the `OK` —
    /// not after a timer. Pre-fix failure: filters were replayed before the
    /// reader task existed, and the only recovery replay was the 2s CLOSED
    /// timer (so the sub-500ms post-OK replay asserted here never happened).
    @Test func reconnect_freshAuth_replayFollowsAcceptance() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(fakeRelayURL, keypair: try makeKeypair())
        let socket1 = try #require(transport.latest)

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: fakeRelayURL, filter: groupFilter(), subId: "s1")
        let recorder = box.record(stream)
        defer { recorder.cancel() }
        #expect(await eventually { socket1.reqCount(subId: "s1") == 1 })

        // Drop the transport; the pool reconnects after ~1s backoff.
        socket1.dropConnection()
        #expect(await eventually { transport.opened.count == 2 })
        let socket2 = try #require(transport.latest)

        // Fresh connection: auth reset, optimistic REQ goes out to provoke.
        #expect(await eventually { socket2.reqCount(subId: "s1") == 1 })
        #expect(await pool.authState(relayUrl: fakeRelayURL) == .idle)

        socket2.feed("[\"AUTH\",\"challenge-2\"]")
        socket2.feed(closedFrame("s1", "auth-required: please authenticate"))
        #expect(await eventually { socket2.sentAuthEventId != nil })
        let authId = try #require(socket2.sentAuthEventId)

        socket2.feed("[\"OK\",\"\(authId)\",true,\"\"]")
        #expect(await eventually(timeout: 0.5) { socket2.reqCount(subId: "s1") == 2 },
                "replay must follow the AUTH OK promptly, not a timer")
        #expect(await pool.authState(relayUrl: fakeRelayURL) == .authenticated)
        #expect(!box.finished)
    }

    /// Watch-only + an actual challenge → terminal `.authUnavailable`, and no
    /// AUTH frame is ever sent. Pre-fix failure: the stream stayed open and
    /// silently empty forever.
    @Test func watchOnly_authRequired_terminalAuthUnavailable() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(fakeRelayURL, keypair: try watchOnlyKeypair())
        let socket = try #require(transport.latest)

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: fakeRelayURL, filter: groupFilter(), subId: "s1")
        let recorder = box.record(stream)
        defer { recorder.cancel() }
        #expect(await eventually { socket.reqCount(subId: "s1") == 1 })

        socket.feed("[\"AUTH\",\"challenge-1\"]")
        #expect(await eventually { await pool.authState(relayUrl: fakeRelayURL) == .unavailable })
        #expect(socket.sentAuthEventId == nil)

        socket.feed(closedFrame("s1", "auth-required: please authenticate"))
        #expect(await eventually { box.finished })
        guard case .authUnavailable? = box.items.last else {
            Issue.record("expected terminal .authUnavailable, got \(box.items)")
            return
        }
    }

    /// Guards against the wrong fix: watch-only must NOT be refused
    /// pre-emptively by account type. Public data on the same relay flows.
    /// (Passes pre-fix too; must keep passing.)
    @Test func watchOnly_publicData_stillDelivers() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(fakeRelayURL, keypair: try watchOnlyKeypair())
        let socket = try #require(transport.latest)

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: fakeRelayURL, filter: groupFilter(), subId: "s1")
        let recorder = box.record(stream)
        defer { recorder.cancel() }
        #expect(await eventually { socket.reqCount(subId: "s1") == 1 })

        let author = try makeKeypair()
        let priv = try #require(Hex.decode(author.privkey))
        let event = try NostrEvent.sign(privkey32: priv, pubkey: author.pubkey, kind: 9,
                                        createdAt: NostrClock.now(),
                                        tags: [["h", "test-group"]], content: "hello")
        socket.feed("[\"EVENT\",\"s1\",\(event.toJSON())]")

        #expect(await eventually {
            box.items.contains { if case .event(let e) = $0 { return e.id == event.id } else { return false } }
        })
        #expect(!box.finished)
    }

    /// The AUTH OK and publish OK share the wire but not the bookkeeping:
    /// each resolves its own path by event id.
    @Test func okRouting_authAndPublishAreIndependent() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        let keypair = try makeKeypair()
        await pool.ensureRelay(fakeRelayURL, keypair: keypair)
        let socket = try #require(transport.latest)

        socket.feed("[\"AUTH\",\"challenge-1\"]")
        #expect(await eventually { socket.sentAuthEventId != nil })
        let authId = try #require(socket.sentAuthEventId)

        let priv = try #require(Hex.decode(keypair.privkey))
        let note = try NostrEvent.sign(privkey32: priv, pubkey: keypair.pubkey, kind: 9,
                                       createdAt: NostrClock.now(),
                                       tags: [["h", "test-group"]], content: "hi")
        let publishTask = Task { await pool.publish(note, to: fakeRelayURL, timeout: 5) }

        #expect(await eventually { socket.sent.contains { $0.hasPrefix("[\"EVENT\"") } })
        socket.feed("[\"OK\",\"\(note.id)\",true,\"\"]")
        socket.feed("[\"OK\",\"\(authId)\",true,\"\"]")

        #expect(await publishTask.value == .ok)
        #expect(await eventually { await pool.authState(relayUrl: fakeRelayURL) == .authenticated })
    }
}
