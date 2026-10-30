import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Long-lived NIP-46 client. Holds a per-relay WebSocket subscription, decrypts
/// incoming kind-24133 events from the signer, and routes responses back to
/// `sendRequest` callers by request `id`. One instance per active remote
/// session — see `Nip46Manager`.
///
/// The client is an `actor` so the pending-request map and listener bookkeeping
/// don't need ad-hoc locks. The actual relay sockets run on detached tasks and
/// hop back into actor context via `handleResponse(...)`.
actor Nip46Client {

    // MARK: - Config

    /// Ephemeral app keys generated at session creation. Persistent across app
    /// restarts (saved by `Nip46Session`).
    let appPriv32: Data
    let appPubkey: String   // hex
    /// Remote signer's pubkey. Identifies the responder. Hex.
    let signerPubkey: String
    /// Relay URLs the session communicates over. Order matters for some signer
    /// implementations (Primal iOS expects `relay.primal.net` to be present).
    let relays: [String]

    // MARK: - State

    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    /// Per-request timeout timers, cancelled when the response lands so a
    /// long session doesn't accumulate sleeping tasks.
    private var timeouts: [String: Task<Void, Never>] = [:]
    /// Request ids whose `auth_url` we've already surfaced — a signer may
    /// re-send the challenge, and we only want to open the page once.
    private var authUrlShown: Set<String> = []
    /// Called (on the main actor) with the URL a signer asks the user to
    /// open to approve a request (NIP-46 "Auth Challenges").
    private let onAuthURL: (@MainActor @Sendable (URL) -> Void)?
    private var listenerTasks: [Task<Void, Never>] = []
    private var isClosed = false
    /// Event ids we've already routed to a continuation in this session.
    /// A relay reconnect can re-deliver an EVENT we already saw and a
    /// hostile relay can replay an old signed-event response — without
    /// this dedupe an old `sign_event` response could resolve a fresh
    /// `pending[id]` entry. Bounded set: we trim down to the most recent
    /// 256 ids so memory doesn't grow over a long session.
    private var seenEventIds: Set<String> = []
    private var seenEventOrder: [String] = []
    /// Subscription `since` floor — set when `startListening` runs so the
    /// REQ filter ignores any event the relay was holding from before
    /// this session began. `limit: 0` already covers most relays, but
    /// the explicit `since` is a belt-and-suspenders against relays
    /// that interpret limit:0 as "unlimited".
    private var subscriptionSince: Int = 0
    /// Set once any relay has acknowledged our REQ (EOSE). kind-24133 is
    /// ephemeral — relays don't store it — so a response that lands before
    /// our subscription is live is gone for good. Requests wait on this.
    private var isSubscribed = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Holds an iOS background-execution assertion while any RPC is pending.
    /// Same-device signers (Clave, Amber on this phone) mean the user leaves
    /// the app to approve; kind-24133 is ephemeral, so a response that lands
    /// after iOS suspends us is gone for good. The assertion keeps the relay
    /// sockets alive through the approval round-trip.
    private var holdsBackgroundAssertion = false

    // MARK: - Init

    init(appPriv32: Data, appPubkey: String, signerPubkey: String, relays: [String],
         onAuthURL: (@MainActor @Sendable (URL) -> Void)? = nil) {
        self.appPriv32 = appPriv32
        self.appPubkey = appPubkey.lowercased()
        self.signerPubkey = signerPubkey.lowercased()
        self.relays = relays
        self.onAuthURL = onAuthURL
    }

    // MARK: - Background execution

    private func beginBackgroundAssertionIfNeeded() {
        guard !holdsBackgroundAssertion else { return }
        holdsBackgroundAssertion = true
        Task { @MainActor in
            await Nip46BackgroundAssertion.begin()
        }
    }

    private func endBackgroundAssertionIfNeeded() {
        guard holdsBackgroundAssertion, pending.isEmpty || isClosed else { return }
        holdsBackgroundAssertion = false
        Task { @MainActor in
            await Nip46BackgroundAssertion.end()
        }
    }

    /// Spin up the relay subscription and wait (bounded) until at least one
    /// relay has it live, so the first request's response can't outrun it.
    /// Must be called before sending any request. Idempotent.
    func startListening() async {
        openSockets()
        await waitUntilSubscribed(timeout: 6)
    }

    private func openSockets() {
        guard listenerTasks.isEmpty, !isClosed else { return }
        // Pin `since` to the moment listening starts so any old responses
        // a relay may have cached for our app pubkey don't get replayed
        // into our pending map.
        subscriptionSince = Int(Date().timeIntervalSince1970)
        let urls = relays.compactMap(RelayPool.wsURL)
        for url in urls {
            let task: Task<Void, Never> = Task { [weak self] in
                await self?.runRelayLoop(url: url)
            }
            listenerTasks.append(task)
        }
    }

    /// Tear down all sockets and cancel any pending requests. Awaits the
    /// listener tasks so the caller knows the per-relay sockets have actually
    /// been released by the time this returns — critical when a fresh
    /// `Nip46Client` is about to open new sockets to the same relays.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        markSubscribed()
        let tasks = listenerTasks
        listenerTasks.removeAll()
        for task in tasks { task.cancel() }
        for (_, timer) in timeouts { timer.cancel() }
        timeouts.removeAll()
        let cancelled = pending
        pending.removeAll()
        for (_, cont) in cancelled {
            cont.resume(throwing: Nip46.NipError.notConnected)
        }
        endBackgroundAssertionIfNeeded()
        for task in tasks { await task.value }
    }

    private func waitUntilSubscribed(timeout: TimeInterval) async {
        if isSubscribed { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.markSubscribed()
        }
        await withCheckedContinuation { readyWaiters.append($0) }
        timer.cancel()
    }

    /// Release everyone waiting on the subscription. Also called on timeout
    /// and close so a dead relay set fails the request instead of hanging.
    private func markSubscribed() {
        isSubscribed = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    // MARK: - RPC

    /// Send a single RPC and wait for the matching response. Encrypts with NIP-44 v2.
    func sendRequest(method: String, params: [String], timeout: TimeInterval = Nip46.rpcTimeoutSeconds) async throws -> String {
        if isClosed { throw Nip46.NipError.notConnected }
        if !isSubscribed {
            openSockets()
            await waitUntilSubscribed(timeout: 6)
        }
        let id = Nip46.randomRequestId()
        let plaintext = Nip46.makeRequestJSON(id: id, method: method, params: params)
        let cipher = try Nip46.encryptToSigner(plaintext: plaintext, appPriv32: appPriv32, signerPubkeyHex: signerPubkey)
        let createdAt = Int(Date().timeIntervalSince1970)
        let event = try NostrEvent.sign(
            privkey32: appPriv32,
            pubkey: appPubkey,
            kind: Nip46.kind,
            createdAt: createdAt,
            tags: [["p", signerPubkey]],
            content: cipher
        )

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            Task { await self.beginRequest(id: id, event: event, method: method, timeout: timeout, cont: cont) }
        }
    }

    private func beginRequest(id: String,
                              event: NostrEvent,
                              method: String,
                              timeout: TimeInterval,
                              cont: CheckedContinuation<String, Error>) {
        if isClosed {
            cont.resume(throwing: Nip46.NipError.notConnected)
            return
        }
        pending[id] = cont
        let relayList = self.relays
        Task.detached { [weak self] in
            let accepted = await RelayPool.publish(event: event, to: relayList, timeout: 6)
            // No relay took the request: the signer can never see it, so fail
            // now instead of leaving the user staring at a spinner for the
            // full RPC timeout.
            if accepted.isEmpty {
                await self?.failPending(id: id, error: Nip46.NipError.relaysUnreachable)
            }
        }
        armTimeout(id: id, method: method, after: timeout)
        beginBackgroundAssertionIfNeeded()
    }

    private func armTimeout(id: String, method: String, after seconds: TimeInterval) {
        timeouts[id]?.cancel()
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            await self?.failPending(id: id, error: Nip46.NipError.timeout(method: method))
        }
    }

    private func failPending(id: String, error: Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        authUrlShown.remove(id)
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
        endBackgroundAssertionIfNeeded()
    }

    private func resolvePending(id: String, with result: Result<String, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        authUrlShown.remove(id)
        guard let cont = pending.removeValue(forKey: id) else { return }
        switch result {
        case .success(let s): cont.resume(returning: s)
        case .failure(let e): cont.resume(throwing: e)
        }
        endBackgroundAssertionIfNeeded()
    }

    // MARK: - Listener

    private func runRelayLoop(url: URL) async {
        let urlString = url.absoluteString
        let req = "[\"REQ\",\"nip46-\(String(UUID().uuidString.prefix(8)).lowercased())\",\(filterJSON())]"
        var attempt = 0

        while !Task.isCancelled, !isClosed {
            let session = URLSession(configuration: .default)
            let ws = session.webSocketTask(with: url)
            ws.resume()

            // Force-cancel the WebSocket on Task cancellation. Without this,
            // `ws.receive()` ignores Swift task cancellation and keeps blocking
            // until the relay drops the socket — leaving zombie sockets after
            // `close()` and starving the next session of relay connections.
            await withTaskCancellationHandler {
                do { try await ws.send(.string(req)) } catch {
                    return
                }

                while !Task.isCancelled {
                    do {
                        let msg = try await ws.receive()
                        guard case .string(let text) = msg else { continue }
                        guard let data = text.data(using: .utf8),
                              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                              let type = arr.first as? String else { continue }
                        if type == "EVENT", arr.count >= 3,
                           let obj = arr[2] as? [String: Any],
                           let event = NostrEvent(json: obj) {
                            attempt = 0
                            processIncoming(event: event, relay: urlString)
                        } else if type == "EOSE" {
                            // Subscription is live on this relay; keep it open.
                            attempt = 0
                            markSubscribed()
                        } else if type == "CLOSED" {
                            return
                        }
                    } catch {
                        return
                    }
                }
            } onCancel: {
                ws.cancel(with: .normalClosure, reason: nil)
            }

            ws.cancel(with: .normalClosure, reason: nil)
            if Task.isCancelled { break }
            let delay = min(30.0, pow(2.0, Double(attempt)))
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func filterJSON() -> String {
        let f = NostrFilter(
            kinds: [Nip46.kind],
            authors: [signerPubkey],
            pTags: [appPubkey],
            limit: 0,
            since: subscriptionSince > 0 ? subscriptionSince : nil
        )
        return f.toJSON()
    }

    private func processIncoming(event: NostrEvent, relay: String) {
        guard event.kind == Nip46.kind, event.pubkey.lowercased() == signerPubkey else { return }
        // Drop events we've already routed once. A relay reconnect can
        // re-stream an event we just consumed; without this an old
        // sign_event response would resolve the next request we make.
        guard seenEventIds.insert(event.id).inserted else { return }
        seenEventOrder.append(event.id)
        if seenEventOrder.count > 256 {
            let drop = seenEventOrder.removeFirst()
            seenEventIds.remove(drop)
        }
        let plaintext: String
        do {
            plaintext = try Nip46.decryptFromSigner(payload: event.content, appPriv32: appPriv32, signerPubkeyHex: signerPubkey)
        } catch {
            return
        }
        guard let decoded = Nip46.decodeResponse(plaintext) else { return }
        // Auth challenge: the signer wants the user to approve in a browser.
        // Open the page, keep the request pending, and give the user time to
        // finish — the real response arrives later under the same id.
        if decoded.result == Nip46.authUrlResult {
            guard pending[decoded.id] != nil else { return }
            if let raw = decoded.error, let url = URL(string: raw),
               let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
               authUrlShown.insert(decoded.id).inserted {
                if let onAuthURL {
                    Task { @MainActor in onAuthURL(url) }
                }
            }
            armTimeout(id: decoded.id, method: "approval", after: Nip46.authChallengeTimeoutSeconds)
            return
        }
        if let err = decoded.error {
            resolvePending(id: decoded.id, with: .failure(Nip46.NipError.rpcError(err)))
        } else if let result = decoded.result {
            resolvePending(id: decoded.id, with: .success(result))
        } else {
            resolvePending(id: decoded.id, with: .failure(Nip46.NipError.malformedResponse))
        }
    }

    // MARK: - High-level RPC helpers

    /// Send `connect`. Per spec, params are
    /// `[<signer_pubkey_hex>, <secret?>, <perms?>, <client_metadata?>]` —
    /// positional, so empty strings hold the earlier slots when we send
    /// metadata. Both `"ack"` and the URI's secret echoed back are valid
    /// success responses; the caller validates.
    @discardableResult
    func connect(secret: String?, perms: [String] = []) async throws -> String {
        let params: [String] = [
            signerPubkey,
            secret ?? "",
            perms.joined(separator: ","),
            Nip46.clientMetadataJSON()
        ]
        return try await sendRequest(method: Nip46.Method.connect, params: params,
                                     timeout: Nip46.nostrconnectHandshakeTimeoutSeconds)
    }

    /// Ask the signer which relays it wants to talk on. Returns nil when it
    /// has no preference (`null`) or doesn't implement the method; returns a
    /// normalized list otherwise.
    func switchRelays() async -> [String]? {
        guard let result = try? await sendRequest(method: Nip46.Method.switchRelays, params: [], timeout: 15),
              let data = result.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        var out: [String] = []
        for raw in arr {
            if let r = Nip46.normalizeRelay(raw), !out.contains(r) { out.append(r) }
        }
        return out.isEmpty ? nil : out
    }

    /// Courtesy hint that this session is over (spec: not a security
    /// boundary — the caller deletes the app key regardless).
    func logout() async {
        _ = try? await sendRequest(method: Nip46.Method.logout, params: [], timeout: 5)
    }

    func getPublicKey() async throws -> String {
        let result = try await sendRequest(method: Nip46.Method.getPublicKey, params: [])
        let lower = result.lowercased()
        guard lower.count == 64, Hex.decode(lower) != nil else {
            throw Nip46.NipError.malformedResponse
        }
        return lower
    }

    /// Sign an unsigned event template. The signer returns a fully-signed
    /// event JSON string.
    func signEvent(unsigned: [String: Any]) async throws -> NostrEvent {
        guard let data = try? JSONSerialization.data(withJSONObject: unsigned),
              let json = String(data: data, encoding: .utf8) else {
            throw Nip46.NipError.malformedResponse
        }
        let result = try await sendRequest(method: Nip46.Method.signEvent, params: [json])
        guard let event = NostrEvent.fromJSON(result) else {
            throw Nip46.NipError.malformedResponse
        }
        return event
    }

    func nip44Encrypt(peerPubkeyHex: String, plaintext: String) async throws -> String {
        try await sendRequest(method: Nip46.Method.nip44Encrypt, params: [peerPubkeyHex, plaintext])
    }

    func nip44Decrypt(peerPubkeyHex: String, ciphertext: String) async throws -> String {
        try await sendRequest(method: Nip46.Method.nip44Decrypt, params: [peerPubkeyHex, ciphertext])
    }

    func ping() async throws -> String {
        try await sendRequest(method: Nip46.Method.ping, params: [])
    }
}

#if canImport(UIKit)
/// Single app-level assertion shared by every NIP-46 client. `begin` is
/// idempotent; whichever request finishes last ends it. On expiry iOS calls
/// the handler, we release the assertion, and any still-pending request falls
/// back to its normal timeout.
@MainActor
enum Nip46BackgroundAssertion {
    nonisolated(unsafe) private static var id: UIBackgroundTaskIdentifier = .invalid

    static func begin() async {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "NIP-46 request pending") {
            end()
        }
    }

    static func end() {
        guard id != .invalid else { return }
        let current = id
        id = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}
#endif
