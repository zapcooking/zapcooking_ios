import Foundation

// MARK: - Transport seam

/// Minimal WebSocket surface `GroupRelayPool` needs. Production uses
/// `URLSessionGroupRelayTransport`; hermetic tests inject a fake so NIP-42
/// frame ordering (REQ / AUTH / OK / CLOSED) can be driven deterministically.
nonisolated protocol GroupRelaySocket: AnyObject, Sendable {
    func resume()
    /// Fire-and-forget; the reader detects drops.
    func send(_ text: String)
    /// Next text frame. Throws when the connection is gone.
    func receive() async throws -> String
    func cancel()
}

nonisolated protocol GroupRelayTransport: Sendable {
    func open(url: URL) -> GroupRelaySocket
}

nonisolated final class URLSessionGroupRelaySocket: GroupRelaySocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        session = URLSession(configuration: .default)
        task = session.webSocketTask(with: url)
    }

    func resume() { task.resume() }

    func send(_ text: String) {
        task.send(.string(text)) { _ in /* fire and forget; reader will detect drops */ }
    }

    func receive() async throws -> String {
        while true {
            let msg = try await task.receive()
            if case .string(let text) = msg { return text }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        // The old per-connect URLSession was never invalidated and leaked one
        // session per reconnect; the socket owns its session now.
        session.finishTasksAndInvalidate()
    }
}

nonisolated struct URLSessionGroupRelayTransport: GroupRelayTransport {
    func open(url: URL) -> GroupRelaySocket { URLSessionGroupRelaySocket(url: url) }
}

// MARK: - Public surface types

/// One element of a `GroupRelayPool.subscribe` stream. The terminal cases are
/// issue #6's explicit surface: a relay refusing a subscription is reported to
/// the caller instead of leaving a silently empty stream. The stream finishes
/// immediately after yielding a terminal element. Mapping a terminal to UI is
/// the feature layer's job (same classification family as
/// `RecipeSaveGate.needsKey`).
nonisolated enum GroupSubEvent: Sendable {
    case event(NostrEvent)
    /// Relay demands NIP-42 AUTH and this account cannot sign (watch-only, or
    /// signing failed). Emitted only after the relay actually challenged —
    /// never pre-emptively by account type: public data on the same relay
    /// still flows for watch-only accounts.
    case authUnavailable
    /// We sent AUTH and the relay rejected it (`OK false`), or AUTH never
    /// settled in time. Terminal for this connection; a reconnect retries.
    case authFailed(reason: String)
    /// Authenticated, but the relay refuses the filter for this pubkey
    /// (`CLOSED restricted:` — e.g. pantry membership required).
    case notMember(reason: String)
    /// Any other CLOSED that survived the bounded replay.
    case closed(reason: String)
}

/// NIP-42 progress for one relay connection. `.pending` means the AUTH event
/// was *sent*; only the relay's `OK` for that event id moves it to
/// `.authenticated` (issue #6 defect 3: send is not acceptance).
nonisolated enum GroupRelayAuthState: Equatable, Sendable {
    case idle
    case pending(authEventId: String)
    case authenticated
    case failed(reason: String)
    case unavailable

    /// The machine reached an outcome for this connection — no further AUTH
    /// progress will happen without a reconnect.
    var isSettled: Bool {
        switch self {
        case .authenticated, .failed, .unavailable: return true
        case .idle, .pending: return false
        }
    }
}

/// Persistent, AUTH-aware connection manager for NIP-29 group relays.
///
/// Unlike `RelayPool` (a separate stack on `RelayConnectionPool`),
/// `GroupRelayPool` keeps one socket open per relay URL with auto-reconnect,
/// runs a per-connection NIP-42 state machine (`GroupRelayAuthState`), and
/// demultiplexes incoming `EVENT` frames to per-subscription `AsyncStream`s.
///
/// NIP-42 shape (issue #6): khatru-family relays never volunteer the AUTH
/// challenge — the first REQ provokes it. So REQs always go out optimistically;
/// recovery is event-driven: `CLOSED auth-required` parks the subscription on
/// the auth state machine, and the machine settles only on the relay's `OK`
/// for our kind-22242 event (never on send). Replays are bounded on every
/// path — nothing loops at RTT rate.
actor GroupRelayPool {

    static let shared = GroupRelayPool()

    enum PublishResult: Equatable {
        case ok
        case duplicate
        case authRequired(challenge: String?)
        case rejected(message: String)
        case timeout
        case network
    }

    /// Replays granted per subscription per connection after AUTH settles
    /// authenticated (matches Android `AuthedRelayReader.maxAttempts`).
    static let maxAuthReplays = 3
    /// Replays granted per subscription per connection for non-auth CLOSED
    /// reasons (`restricted:` and everything else): exactly one, then terminal.
    static let maxNonAuthReplays = 1
    /// How long a subscription parked on `CLOSED auth-required` waits for the
    /// auth machine to settle before the connection is marked failed.
    static let authSettleTimeout: TimeInterval = 10

    // MARK: - Private state

    private final class RelayState {
        let url: String
        var socket: GroupRelaySocket?
        var listenerTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        var authTimeoutTask: Task<Void, Never>?
        var subscriptions: [String: SubscriptionState] = [:]
        /// `subId` -> filter JSON; replayed verbatim on reconnect.
        var subscriptionFilters: [String: String] = [:]
        /// id -> continuation, for in-flight `publish` calls awaiting an `OK` frame.
        var pendingPublishes: [String: AsyncStream<PublishResult>.Continuation] = [:]
        var isConnecting: Bool = false
        var auth: GroupRelayAuthState = .idle
        var lastChallenge: String?
        var keypair: Keypair?
        /// Tracks listeners awaiting AUTH settle (any outcome, not just success).
        var authCompletionContinuations: [CheckedContinuation<Void, Never>] = []
        var reconnectAttempt: Int = 0
        #if DEBUG
        /// Wire-frame ring log (oldest first), for live-gate observability.
        var frameLog: [String] = []
        #endif

        init(url: String) { self.url = url }
    }

    private final class SubscriptionState {
        let subId: String
        let continuation: AsyncStream<GroupSubEvent>.Continuation
        /// Parked on `CLOSED auth-required`; acted on when the auth machine settles.
        var awaitingAuth = false
        var authReplays = 0
        var nonAuthReplays = 0

        init(subId: String, continuation: AsyncStream<GroupSubEvent>.Continuation) {
            self.subId = subId
            self.continuation = continuation
        }

        func resetForNewConnection() {
            awaitingAuth = false
            authReplays = 0
            nonAuthReplays = 0
        }
    }

    private let transport: GroupRelayTransport
    private var relays: [String: RelayState] = [:]
    /// Reference counts per (relay, group) so we know when a relay can be torn down.
    private var groupCountByRelay: [String: Int] = [:]

    init(transport: GroupRelayTransport = URLSessionGroupRelayTransport()) {
        self.transport = transport
    }

    // MARK: - Public API

    /// Open (or refresh keypair on) a persistent connection to `url`. Idempotent.
    func ensureRelay(_ url: String, keypair: Keypair) {
        let state = relays[url] ?? RelayState(url: url)
        state.keypair = keypair
        relays[url] = state
        groupCountByRelay[url, default: 0] += 1
        if state.socket == nil && !state.isConnecting {
            connect(state)
        }
    }

    /// Decrement the refcount for `url`; if it reaches zero, close the socket and forget it.
    func releaseRelay(_ url: String) {
        guard let state = relays[url] else { return }
        let count = (groupCountByRelay[url] ?? 1) - 1
        if count <= 0 {
            groupCountByRelay.removeValue(forKey: url)
            tearDown(state)
            relays.removeValue(forKey: url)
        } else {
            groupCountByRelay[url] = count
        }
    }

    /// Force-close every persistent connection. Call on logout.
    func shutdownAll() {
        for state in relays.values { tearDown(state) }
        relays.removeAll()
        groupCountByRelay.removeAll()
    }

    /// Open a long-lived subscription on `relayUrl`. Caller must `cancel()` the
    /// returned subscription when done. The REQ goes out immediately (against
    /// khatru it is what provokes the AUTH challenge); a relay-side refusal
    /// arrives as one terminal `GroupSubEvent` before the stream finishes.
    func subscribe(relayUrl: String, filter: NostrFilter, subId: String) -> AsyncStream<GroupSubEvent> {
        guard let state = relays[relayUrl] else {
            return AsyncStream { $0.finish() }
        }
        let stream = AsyncStream<GroupSubEvent> { continuation in
            let sub = SubscriptionState(subId: subId, continuation: continuation)
            state.subscriptions[subId] = sub
            let filterJSON = filter.toJSON()
            state.subscriptionFilters[subId] = filterJSON
            sendREQ(state: state, subId: subId, filterJSON: filterJSON)
            continuation.onTermination = { [weak self, weak state] _ in
                guard let self, let state else { return }
                Task { await self.cancelSubscription(state: state, subId: subId) }
            }
        }
        return stream
    }

    /// Cancel a single subscription.
    func cancelSubscription(relayUrl: String, subId: String) {
        guard let state = relays[relayUrl] else { return }
        cancelSubscription(state: state, subId: subId)
    }

    /// Publish an event to a single relay. Awaits the OK reply (or AUTH challenge / timeout).
    func publish(_ event: NostrEvent, to relayUrl: String,
                 timeout: TimeInterval = 10) async -> PublishResult {
        guard let state = relays[relayUrl] else { return .network }
        let stream = AsyncStream<PublishResult> { continuation in
            state.pendingPublishes[event.id] = continuation
        }
        send(state: state, payload: "[\"EVENT\",\(event.toJSON())]")
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if let cont = state.pendingPublishes.removeValue(forKey: event.id) {
                cont.yield(.timeout)
                cont.finish()
            }
        }
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next() ?? .timeout
        timeoutTask.cancel()
        return result
    }

    /// Publish then, on `auth-required:` rejection, wait for AUTH and retry once.
    /// Mirrors Android's `publishAdminEvent` retry semantics.
    func publishWithAuthRetry(_ event: NostrEvent, to relayUrl: String,
                              authWaitSeconds: TimeInterval = 5,
                              publishTimeout: TimeInterval = 10) async -> PublishResult {
        await waitForAuthIfNeeded(relayUrl: relayUrl, timeout: authWaitSeconds)
        let first = await publish(event, to: relayUrl, timeout: publishTimeout)
        switch first {
        case .authRequired:
            await waitForAuthIfNeeded(relayUrl: relayUrl, timeout: authWaitSeconds)
            return await publish(event, to: relayUrl, timeout: publishTimeout)
        default:
            return first
        }
    }

    /// Block (up to `timeout`) until the relay's auth machine settles —
    /// accepted, rejected, or unavailable. Returns immediately if already
    /// settled or if no challenge has arrived (khatru only challenges after a
    /// rejected REQ/EVENT, so there is nothing to wait for pre-challenge).
    func waitForAuthIfNeeded(relayUrl: String, timeout: TimeInterval = 5) async {
        guard let state = relays[relayUrl] else { return }
        if state.auth.isSettled { return }
        if state.lastChallenge == nil { return } // No challenge yet; nothing to wait for.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await self.awaitAuthSettle(state: state)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func awaitAuthSettle(state: RelayState) async {
        if state.auth.isSettled { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            state.authCompletionContinuations.append(cont)
        }
    }

    // MARK: - Test / gate observability

    /// Current NIP-42 state for a relay. Observability for tests and live
    /// gates only — production callers use `subscribe`'s terminal events.
    func authState(relayUrl: String) -> GroupRelayAuthState? {
        relays[relayUrl]?.auth
    }

    #if DEBUG
    /// Simulate a transport drop (live gate: reconnect ordering).
    func dropConnectionForTesting(relayUrl: String) {
        relays[relayUrl]?.socket?.cancel()
    }

    /// Wire-frame log for a relay (oldest first) — live-gate observability.
    func frameLogForTesting(relayUrl: String) -> [String] {
        relays[relayUrl]?.frameLog ?? []
    }

    private func logFrame(state: RelayState, _ direction: String, _ text: String) {
        if state.frameLog.count >= 256 { state.frameLog.removeFirst() }
        state.frameLog.append("\(direction) \(text.prefix(160))")
    }
    #endif

    // MARK: - Connection lifecycle

    private func connect(_ state: RelayState) {
        guard let url = URL(string: state.url) else { return }
        state.isConnecting = true
        state.auth = .idle
        state.lastChallenge = nil
        state.authTimeoutTask?.cancel()
        state.authTimeoutTask = nil
        for sub in state.subscriptions.values { sub.resetForNewConnection() }

        let socket = transport.open(url: url)
        state.socket = socket
        socket.resume()

        // Reader first: AUTH/OK/CLOSED frames need a consumer before any REQ
        // can provoke them (issue #6 defect 4 — the old code replayed every
        // filter before the reader task existed).
        let task = Task { [weak self, weak state] in
            guard let self, let state else { return }
            await self.runReader(state: state, socket: socket)
        }
        state.listenerTask = task

        // Optimistic replay: against khatru the first REQ is what provokes the
        // AUTH challenge, so filters go out unauthenticated once. Recovery —
        // replay after the auth machine settles — is driven by the CLOSED/OK
        // handlers, never by a timer.
        for (subId, filterJSON) in state.subscriptionFilters {
            sendREQ(state: state, subId: subId, filterJSON: filterJSON)
        }

        state.isConnecting = false
        state.reconnectAttempt = 0
    }

    private func tearDown(_ state: RelayState) {
        state.listenerTask?.cancel()
        state.reconnectTask?.cancel()
        state.authTimeoutTask?.cancel()
        state.authTimeoutTask = nil
        state.socket?.cancel()
        state.socket = nil
        state.auth = .idle
        state.lastChallenge = nil
        for sub in state.subscriptions.values { sub.continuation.finish() }
        state.subscriptions.removeAll()
        state.subscriptionFilters.removeAll()
        for (_, cont) in state.pendingPublishes {
            cont.yield(.network); cont.finish()
        }
        state.pendingPublishes.removeAll()
        for cont in state.authCompletionContinuations { cont.resume() }
        state.authCompletionContinuations.removeAll()
    }

    private func scheduleReconnect(_ state: RelayState) {
        guard relays[state.url] != nil else { return } // released
        state.reconnectAttempt += 1
        let delay = min(30, pow(2.0, Double(state.reconnectAttempt - 1)))
        state.socket?.cancel()
        state.socket = nil
        state.auth = .idle
        state.lastChallenge = nil
        state.authTimeoutTask?.cancel()
        state.authTimeoutTask = nil
        state.reconnectTask?.cancel()
        state.reconnectTask = Task { [weak self, weak state] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let state else { return }
            await self.connect(state)
        }
    }

    private func runReader(state: RelayState, socket: GroupRelaySocket) async {
        while !Task.isCancelled {
            do {
                let text = try await socket.receive()
                handleFrame(state: state, text: text)
            } catch {
                // Connection dropped — schedule reconnect, but only if this
                // reader's socket is still the live one (a stale reader must
                // not kill a healthy replacement connection).
                if relays[state.url] != nil, state.socket === socket {
                    scheduleReconnect(state)
                }
                return
            }
        }
    }

    // MARK: - Frame handling

    private func handleFrame(state: RelayState, text: String) {
        #if DEBUG
        logFrame(state: state, "<-", text)
        #endif
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = arr.first as? String else { return }

        switch type {
        case "EVENT":
            guard arr.count >= 3,
                  let subId = arr[1] as? String,
                  let obj = arr[2] as? [String: Any],
                  let event = NostrEvent(json: obj) else { return }
            state.subscriptions[subId]?.continuation.yield(.event(event))

        case "EOSE":
            // Persistent stream stays open; nothing to do.
            break

        case "OK":
            guard arr.count >= 3,
                  let eventId = arr[1] as? String,
                  let ok = arr[2] as? Bool else { return }
            let message = arr.count >= 4 ? (arr[3] as? String ?? "") : ""
            // The relay's verdict on our kind-22242 AUTH event, correlated by
            // the retained event id. This — not the act of sending — is what
            // authenticates the connection (issue #6 defect 3).
            if case .pending(let authEventId) = state.auth, eventId == authEventId {
                if ok {
                    settleAuth(state: state, outcome: .authenticated)
                } else {
                    let reason = message.isEmpty ? "auth rejected" : message
                    settleAuth(state: state, outcome: .failed(reason: reason))
                }
                return
            }
            if let cont = state.pendingPublishes.removeValue(forKey: eventId) {
                let result: PublishResult
                if ok {
                    result = .ok
                } else if message.lowercased().hasPrefix("duplicate:") {
                    result = .duplicate
                } else if message.lowercased().hasPrefix("auth-required:") {
                    result = .authRequired(challenge: state.lastChallenge)
                } else {
                    result = .rejected(message: message)
                }
                cont.yield(result)
                cont.finish()
            }

        case "AUTH":
            guard arr.count >= 2, let challenge = arr[1] as? String else { return }
            state.lastChallenge = challenge
            authenticate(state: state, challenge: challenge)

        case "CLOSED":
            guard arr.count >= 2, let subId = arr[1] as? String,
                  let sub = state.subscriptions[subId] else { return }
            let reason = arr.count >= 3 ? (arr[2] as? String ?? "") : ""
            handleClosed(state: state, sub: sub, reason: reason)

        case "NOTICE":
            // Informational; ignore.
            break

        default:
            break
        }
    }

    /// Bounded CLOSED handling — no path may loop at RTT rate (issue #6 F-6).
    private func handleClosed(state: RelayState, sub: SubscriptionState, reason: String) {
        let lower = reason.lowercased()
        if lower.hasPrefix("auth-required") {
            switch state.auth {
            case .unavailable:
                finish(state: state, sub: sub, with: .authUnavailable)
            case .failed(let why):
                finish(state: state, sub: sub, with: .authFailed(reason: why))
            case .authenticated:
                // Accepted, yet still refused as unauthenticated — replay
                // within the auth budget, then give up.
                replayOrFinish(state: state, sub: sub,
                               terminal: .closed(reason: reason),
                               count: \.authReplays, max: Self.maxAuthReplays)
            case .idle, .pending:
                // khatru sends the AUTH challenge before this CLOSED, so the
                // machine is normally already .pending. Park the sub; the
                // settle (OK true/false, unavailable, or timeout) decides.
                sub.awaitingAuth = true
                startAuthSettleTimeout(state: state)
            }
        } else if lower.hasPrefix("restricted") {
            // Authenticated but refused for this pubkey (e.g. pantry
            // membership). One replay covers an AUTH/REQ race; the second
            // refusal is the relay's answer.
            replayOrFinish(state: state, sub: sub,
                           terminal: .notMember(reason: reason),
                           count: \.nonAuthReplays, max: Self.maxNonAuthReplays)
        } else {
            replayOrFinish(state: state, sub: sub,
                           terminal: .closed(reason: reason),
                           count: \.nonAuthReplays, max: Self.maxNonAuthReplays)
        }
    }

    private func replayOrFinish(state: RelayState, sub: SubscriptionState,
                                terminal: GroupSubEvent,
                                count: ReferenceWritableKeyPath<SubscriptionState, Int>,
                                max: Int) {
        if sub[keyPath: count] < max, let filterJSON = state.subscriptionFilters[sub.subId] {
            sub[keyPath: count] += 1
            sendREQ(state: state, subId: sub.subId, filterJSON: filterJSON)
        } else {
            finish(state: state, sub: sub, with: terminal)
        }
    }

    /// Yield one terminal element and finish the stream. The relay has already
    /// CLOSED the sub server-side on every path that reaches here.
    private func finish(state: RelayState, sub: SubscriptionState, with terminal: GroupSubEvent) {
        state.subscriptions.removeValue(forKey: sub.subId)
        state.subscriptionFilters.removeValue(forKey: sub.subId)
        sub.continuation.yield(terminal)
        sub.continuation.finish()
    }

    // MARK: - NIP-42

    private func authenticate(state: RelayState, challenge: String) {
        switch state.auth {
        case .idle:
            break
        case .pending, .authenticated, .failed, .unavailable:
            // Already answered this connection's challenge (khatru re-sends it
            // on every rejection), or the outcome is settled. `.failed` stays
            // terminal for the connection — reconnect retries with fresh state.
            return
        }
        guard let keypair = state.keypair, !keypair.privkey.isEmpty else {
            settleAuth(state: state, outcome: .unavailable)
            return
        }
        do {
            let event = try Nip42.buildAuthEvent(challenge: challenge,
                                                 relayUrl: state.url,
                                                 keypair: keypair)
            send(state: state, payload: "[\"AUTH\",\(event.toJSON())]")
            // Sent is not accepted: hold .pending until the relay's OK for
            // this event id arrives (issue #6 defect 3).
            state.auth = .pending(authEventId: event.id)
        } catch {
            // Sign failed (empty or malformed key) — auth is unavailable on
            // this connection; parked subs surface .authUnavailable.
            settleAuth(state: state, outcome: .unavailable)
        }
    }

    /// Move the auth machine to a settled outcome, wake waiters, and act on
    /// every subscription parked by `CLOSED auth-required`.
    private func settleAuth(state: RelayState, outcome: GroupRelayAuthState) {
        assert(outcome.isSettled)
        state.auth = outcome
        state.authTimeoutTask?.cancel()
        state.authTimeoutTask = nil
        for cont in state.authCompletionContinuations { cont.resume() }
        state.authCompletionContinuations.removeAll()

        // Snapshot: replayOrFinish/finish mutate `subscriptions` mid-walk.
        let parked = state.subscriptions.values.filter(\.awaitingAuth)
        for sub in parked {
            sub.awaitingAuth = false
            switch outcome {
            case .authenticated:
                replayOrFinish(state: state, sub: sub,
                               terminal: .closed(reason: "auth replay budget exhausted"),
                               count: \.authReplays, max: Self.maxAuthReplays)
            case .failed(let reason):
                finish(state: state, sub: sub, with: .authFailed(reason: reason))
            case .unavailable:
                finish(state: state, sub: sub, with: .authUnavailable)
            case .idle, .pending:
                break // unreachable: outcome.isSettled asserted above
            }
        }
    }

    /// Backstop for a relay that CLOSEs `auth-required` but never lets AUTH
    /// settle (challenge lost, OK never sent): after `authSettleTimeout` the
    /// connection is marked failed so parked subs terminate instead of
    /// silently hanging.
    private func startAuthSettleTimeout(state: RelayState) {
        guard state.authTimeoutTask == nil else { return }
        state.authTimeoutTask = Task { [weak self, weak state] in
            try? await Task.sleep(for: .seconds(Self.authSettleTimeout))
            guard !Task.isCancelled, let self, let state else { return }
            await self.authSettleTimedOut(state: state)
        }
    }

    private func authSettleTimedOut(state: RelayState) {
        guard !state.auth.isSettled else { return }
        state.authTimeoutTask = nil
        settleAuth(state: state, outcome: .failed(reason: "auth did not settle in time"))
    }

    // MARK: - Send helpers

    private func sendREQ(state: RelayState, subId: String, filterJSON: String) {
        send(state: state, payload: "[\"REQ\",\"\(subId)\",\(filterJSON)]")
    }

    private func send(state: RelayState, payload: String) {
        guard let socket = state.socket else { return }
        #if DEBUG
        logFrame(state: state, "->", payload)
        #endif
        socket.send(payload)
    }

    private func cancelSubscription(state: RelayState, subId: String) {
        state.subscriptions.removeValue(forKey: subId)?.continuation.finish()
        state.subscriptionFilters.removeValue(forKey: subId)
        send(state: state, payload: "[\"CLOSE\",\"\(subId)\"]")
    }
}
