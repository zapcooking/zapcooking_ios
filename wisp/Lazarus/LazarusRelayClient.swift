import Foundation

// Scan-scoped relay sockets for Lazarus.
//
// `RelayPool` can't answer the question every Lazarus step asks: did this
// relay answer, fail, or time out? Its persistent connections retry a dead
// socket silently, so a failed relay and a slow one look the same to the
// caller, and a `CLOSED auth-required` is swallowed. The spec requires
// telling them apart in the scan, the relay list lookup and the pre-sign
// re-read ("Relay outcomes"), so this helper opens its own sockets through
// the `GroupRelayTransport` seam, reports one outcome per request, reuses
// one connection per relay across pages while they're fresh, and releases
// everything when idle or when the recovery screen goes away.

/// The filter a Lazarus request sends. `NostrFilter` is main-actor isolated
/// (the project's default isolation) and these sockets run off the main
/// actor, so the REQ JSON is built here from the four fields Lazarus uses.
nonisolated struct LazarusFilter: Sendable, Equatable {
    var kinds: [Int]
    var authors: [String]
    var limit: Int
    var until: Int? = nil

    var json: String {
        var object: [String: Any] = ["kinds": kinds, "authors": authors, "limit": limit]
        if let until { object["until"] = until }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

/// What a relay sent in answer to a request, and how the request ended.
/// Events that arrived before a failure or timeout are kept: they're real
/// versions, even though that relay's history is incomplete. They are not
/// validated here; the scan engine checks every one.
nonisolated struct LazarusRelayAnswer: Sendable {
    var events: [NostrEvent]
    var outcome: LazarusRelayOutcome
}

nonisolated enum LazarusPublishOutcome: Sendable, Equatable {
    /// `OK true`, including `duplicate:`.
    case accepted
    /// `OK false`, with the relay's reason.
    case rejected(reason: String)
    /// The connection failed or closed before an `OK`.
    case failed
    case timedOut
}

/// The relay I/O Lazarus needs. Production is `LazarusRelayClient`; tests
/// inject a scripted fake.
nonisolated protocol LazarusRelayIO: Sendable {
    func query(relay: String, filter: LazarusFilter, timeout: TimeInterval) async -> LazarusRelayAnswer
    func publish(event: NostrEvent, relay: String, timeout: TimeInterval) async -> LazarusPublishOutcome
    /// Close every socket, ending pending requests as failed.
    func closeAll() async
}

actor LazarusRelayClient: LazarusRelayIO {
    typealias AuthSigner = @Sendable (_ relayUrl: String, _ challenge: String) -> NostrEvent?

    private let transport: GroupRelayTransport
    private let authSigner: AuthSigner?
    /// A connection with nothing pending for this long is closed, and not
    /// reused: a relay may already have dropped it.
    private let idleTimeout: TimeInterval
    private var connections: [String: LazarusRelayConnection] = [:]
    private var reaper: Task<Void, Never>?

    init(
        transport: GroupRelayTransport = URLSessionGroupRelayTransport(),
        authSigner: AuthSigner?,
        idleTimeout: TimeInterval = 30
    ) {
        self.transport = transport
        self.authSigner = authSigner
        self.idleTimeout = idleTimeout
    }

    /// NIP-42 the way `RelayPool` answers it: sign the relay's challenge only
    /// when the user lets the app sign in to relays automatically (the
    /// default) or approved this relay. Only a request the relay refused with
    /// `auth-required` triggers it, so scanning an open relay reveals nothing.
    nonisolated static func authSigner(for keypair: Keypair) -> AuthSigner {
        { relayUrl, challenge in
            let autoApprove = UserDefaults.standard.object(forKey: "wisp_settings_auto_approve_relay_auth") as? Bool ?? true
            guard autoApprove || RelaySettingsRepository.isAuthApproved(relayUrl, pubkey: keypair.pubkey) else {
                return nil
            }
            return try? Nip42.buildAuthEvent(challenge: challenge, relayUrl: relayUrl, keypair: keypair)
        }
    }

    func query(relay: String, filter: LazarusFilter, timeout: TimeInterval) async -> LazarusRelayAnswer {
        guard let connection = connection(for: relay) else {
            return LazarusRelayAnswer(events: [], outcome: .failed)
        }
        return await connection.query(filter: filter, timeout: timeout)
    }

    func publish(event: NostrEvent, relay: String, timeout: TimeInterval) async -> LazarusPublishOutcome {
        guard let connection = connection(for: relay) else { return .failed }
        return await connection.publish(event: event, timeout: timeout)
    }

    func closeAll() async {
        reaper?.cancel()
        reaper = nil
        let open = Array(connections.values)
        connections = [:]
        for connection in open { await connection.close() }
    }

    private func connection(for relay: String) -> LazarusRelayConnection? {
        if let existing = connections[relay] {
            startReaperIfNeeded()
            return existing
        }
        guard let url = URL(string: relay),
              let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              url.host?.isEmpty == false else { return nil }
        let connection = LazarusRelayConnection(
            url: url, transport: transport, authSigner: authSigner, staleAfter: idleTimeout
        )
        connections[relay] = connection
        startReaperIfNeeded()
        return connection
    }

    private func startReaperIfNeeded() {
        guard reaper == nil else { return }
        let interval = max(1, idleTimeout / 3)
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, await self.releaseIdleSockets() else { return }
            }
        }
    }

    /// Close the sockets of idle connections. The connections themselves stay
    /// and reconnect on their next request, so a request racing the reaper
    /// never lands on a closed one. Returns false once no socket is left
    /// open, ending the reaper (the next request starts it again).
    private func releaseIdleSockets() async -> Bool {
        var anyOpen = false
        for connection in Array(connections.values) {
            let released = await connection.releaseIfIdle(for: idleTimeout)
            if !released { anyOpen = true }
        }
        if !anyOpen { reaper = nil }
        return anyOpen
    }
}

/// One relay socket. Requests are keyed by subscription id (REQ) or event
/// id (EVENT); a single reader demultiplexes frames back to them. Every
/// request ends exactly once: EOSE, CLOSED or a dropped connection, the
/// timeout, or `close()`.
actor LazarusRelayConnection {
    /// Beyond this, a relay ignoring `limit` can't grow a request without bound.
    nonisolated static let maxEventsPerQuery = 1000
    /// How long a request refused with `auth-required` waits for the relay's
    /// challenge before it counts as failed (the refusal is a CLOSED).
    nonisolated static let authChallengeGrace: TimeInterval = 1.5

    private let url: URL
    private let urlString: String
    private let transport: GroupRelayTransport
    private let authSigner: LazarusRelayClient.AuthSigner?
    private let staleAfter: TimeInterval

    private var socket: GroupRelaySocket?
    private var reader: Task<Void, Never>?
    /// Set by `close()`: the client dropped this connection, so a late
    /// request must not reopen a socket nothing would close.
    private var isClosed = false
    /// Bumped per socket so a finished reader's late callbacks are ignored.
    private var generation = 0
    private var lastActivity = Date()

    private var queries: [String: PendingQuery] = [:]
    private var publishes: [String: PendingPublish] = [:]

    private enum AuthState {
        case idle
        case sent(eventId: String)
        case authenticated
        case failed
        case unavailable
    }
    private var challenge: String?
    private var auth: AuthState = .idle

    private struct PendingQuery {
        let frame: String
        let continuation: CheckedContinuation<LazarusRelayAnswer, Never>
        var events: [NostrEvent] = []
        var timeout: Task<Void, Never>?
        /// Refused with `auth-required`, waiting for AUTH to go out.
        var awaitingAuth = false
        /// Already sent again after AUTH: a second refusal ends it.
        var replayed = false
    }

    private struct PendingPublish {
        let frame: String
        let continuation: CheckedContinuation<LazarusPublishOutcome, Never>
        var timeout: Task<Void, Never>?
        var awaitingAuth = false
        var resent = false
    }

    init(
        url: URL,
        transport: GroupRelayTransport,
        authSigner: LazarusRelayClient.AuthSigner?,
        staleAfter: TimeInterval
    ) {
        self.url = url
        self.urlString = url.absoluteString
        self.transport = transport
        self.authSigner = authSigner
        self.staleAfter = staleAfter
    }

    /// Process-wide unique: a reused id could let one request's CLOSE end another's.
    nonisolated private static func subscriptionId() -> String {
        "lz-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }

    func query(filter: LazarusFilter, timeout: TimeInterval) async -> LazarusRelayAnswer {
        guard !isClosed else { return LazarusRelayAnswer(events: [], outcome: .failed) }
        refreshIfStale()
        let subId = Self.subscriptionId()
        let frame = "[\"REQ\",\"\(subId)\",\(filter.json)]"
        return await withCheckedContinuation { continuation in
            queries[subId] = PendingQuery(frame: frame, continuation: continuation)
            queries[subId]?.timeout = Task { [weak self] in
                // A request that settled first cancels this; it must settle nothing.
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                await self?.finishQuery(subId, .timedOut)
            }
            send(frame)
        }
    }

    func publish(event: NostrEvent, timeout: TimeInterval) async -> LazarusPublishOutcome {
        guard !isClosed, publishes[event.id] == nil else { return .failed }
        refreshIfStale()
        let frame = "[\"EVENT\",\(event.toJSON())]"
        let eventId = event.id
        return await withCheckedContinuation { continuation in
            publishes[eventId] = PendingPublish(frame: frame, continuation: continuation)
            publishes[eventId]?.timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                await self?.finishPublish(eventId, .timedOut)
            }
            send(frame)
        }
    }

    /// Close the socket when nothing is pending and nothing happened for
    /// `interval`. Returns true when no socket is left open.
    func releaseIfIdle(for interval: TimeInterval) -> Bool {
        guard socket != nil else { return true }
        guard queries.isEmpty, publishes.isEmpty,
              Date().timeIntervalSince(lastActivity) >= interval else { return false }
        generation += 1
        tearDownSocket()
        return true
    }

    func close() {
        isClosed = true
        generation += 1
        tearDownSocket()
        for subId in Array(queries.keys) { finishQuery(subId, .failed) }
        for eventId in Array(publishes.keys) { finishPublish(eventId, .failed) }
    }

    // MARK: - Socket

    private func send(_ frame: String) {
        ensureConnected()
        socket?.send(frame)
    }

    /// A connection nobody used for a while may already be dead on the relay's
    /// side; a fresh one beats a request that fails on a stale socket.
    private func refreshIfStale() {
        guard socket != nil, queries.isEmpty, publishes.isEmpty,
              Date().timeIntervalSince(lastActivity) >= staleAfter else { return }
        generation += 1
        tearDownSocket()
    }

    private func ensureConnected() {
        guard socket == nil else { return }
        generation += 1
        let current = generation
        let opened = transport.open(url: url)
        socket = opened
        lastActivity = Date()
        opened.resume()
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await opened.receive()
                    guard let connection = self else {
                        opened.cancel()
                        return
                    }
                    await connection.handle(text, generation: current)
                } catch {
                    await self?.connectionLost(generation: current)
                    return
                }
            }
        }
    }

    private func tearDownSocket() {
        reader?.cancel()
        reader = nil
        socket?.cancel()
        socket = nil
        challenge = nil
        auth = .idle
    }

    /// The socket dropped (or never opened): every pending request failed.
    private func connectionLost(generation lost: Int) {
        guard lost == generation else { return }
        generation += 1
        tearDownSocket()
        for subId in Array(queries.keys) { finishQuery(subId, .failed) }
        for eventId in Array(publishes.keys) { finishPublish(eventId, .failed) }
    }

    // MARK: - Frames

    private func handle(_ text: String, generation frameGeneration: Int) {
        guard frameGeneration == generation else { return }
        lastActivity = Date()
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = frame.first as? String else { return }
        switch type {
        case "EVENT":
            guard frame.count >= 3, let subId = frame[1] as? String,
                  let received = queries[subId]?.events.count, received < Self.maxEventsPerQuery,
                  let object = frame[2] as? [String: Any],
                  let event = NostrEvent(json: object) else { return }
            queries[subId]?.events.append(event)
        case "EOSE":
            guard frame.count >= 2, let subId = frame[1] as? String else { return }
            finishQuery(subId, .answered)
        case "CLOSED":
            guard frame.count >= 2, let subId = frame[1] as? String, var pending = queries[subId] else { return }
            let reason = frame.count >= 3 ? (frame[2] as? String ?? "") : ""
            if Self.isAuthRequired(reason), !pending.replayed, canAttemptAuth {
                pending.awaitingAuth = true
                queries[subId] = pending
                proceedWithAuth()
            } else {
                finishQuery(subId, .failed)
            }
        case "OK":
            guard frame.count >= 3, let eventId = frame[1] as? String else { return }
            let accepted = frame[2] as? Bool ?? false
            let reason = frame.count >= 4 ? (frame[3] as? String ?? "") : ""
            if case .sent(let authId) = auth, authId == eventId {
                auth = accepted ? .authenticated : .failed
                return
            }
            guard var pending = publishes[eventId] else { return }
            if accepted {
                finishPublish(eventId, .accepted)
            } else if Self.isAuthRequired(reason), !pending.resent, canAttemptAuth {
                pending.awaitingAuth = true
                publishes[eventId] = pending
                proceedWithAuth()
            } else {
                finishPublish(eventId, .rejected(reason: reason))
            }
        case "AUTH":
            guard frame.count >= 2, let value = frame[1] as? String else { return }
            challenge = value
            if queries.values.contains(where: \.awaitingAuth) || publishes.values.contains(where: \.awaitingAuth) {
                proceedWithAuth()
            }
        default:
            // NOTICE and anything unknown: nothing to settle.
            break
        }
    }

    nonisolated private static func isAuthRequired(_ reason: String) -> Bool {
        reason.lowercased().hasPrefix("auth-required")
    }

    private var canAttemptAuth: Bool {
        guard authSigner != nil else { return false }
        switch auth {
        case .failed, .unavailable: return false
        case .idle, .sent, .authenticated: return true
        }
    }

    /// Answer the relay's challenge once per connection, then send each
    /// refused request once more. Bounded on every path: a request refused
    /// again after its replay fails, and the request's own timeout still
    /// runs while the challenge is awaited.
    private func proceedWithAuth() {
        switch auth {
        case .sent, .authenticated:
            replayAwaitingAuth()
        case .idle:
            // Khatru-family relays send the challenge with (or right after)
            // the refusal; until it arrives there is nothing to sign. A relay
            // that never sends one has refused the request: it fails after a
            // short grace instead of reading as a timeout.
            guard let challenge else {
                let current = generation
                Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(Self.authChallengeGrace)) } catch { return }
                    await self?.challengeGraceExpired(generation: current)
                }
                return
            }
            guard let event = authSigner?(urlString, challenge) else {
                auth = .unavailable
                failAwaitingAuth()
                return
            }
            auth = .sent(eventId: event.id)
            socket?.send("[\"AUTH\",\(event.toJSON())]")
            replayAwaitingAuth()
        case .failed, .unavailable:
            failAwaitingAuth()
        }
    }

    private func challengeGraceExpired(generation expired: Int) {
        guard expired == generation, challenge == nil else { return }
        failAwaitingAuth()
    }

    private func replayAwaitingAuth() {
        for (subId, var pending) in queries where pending.awaitingAuth {
            pending.awaitingAuth = false
            pending.replayed = true
            queries[subId] = pending
            socket?.send(pending.frame)
        }
        for (eventId, var pending) in publishes where pending.awaitingAuth {
            pending.awaitingAuth = false
            pending.resent = true
            publishes[eventId] = pending
            socket?.send(pending.frame)
        }
    }

    private func failAwaitingAuth() {
        for (subId, pending) in queries where pending.awaitingAuth { finishQuery(subId, .failed) }
        for (eventId, pending) in publishes where pending.awaitingAuth {
            finishPublish(eventId, .rejected(reason: "auth-required: this account can't sign in to the relay"))
        }
    }

    // MARK: - Settling

    private func finishQuery(_ subId: String, _ outcome: LazarusRelayOutcome) {
        guard let pending = queries.removeValue(forKey: subId) else { return }
        pending.timeout?.cancel()
        lastActivity = Date()
        // End the subscription on the relay too. After a CLOSED or a dropped
        // socket there is nothing left to close.
        if outcome != .failed { socket?.send("[\"CLOSE\",\"\(subId)\"]") }
        pending.continuation.resume(returning: LazarusRelayAnswer(events: pending.events, outcome: outcome))
    }

    private func finishPublish(_ eventId: String, _ outcome: LazarusPublishOutcome) {
        guard let pending = publishes.removeValue(forKey: eventId) else { return }
        pending.timeout?.cancel()
        lastActivity = Date()
        pending.continuation.resume(returning: outcome)
    }
}
