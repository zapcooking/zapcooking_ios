import Foundation
import UIKit

// Fresh's own connection to the curated feed relay (`wss://feed.zap.cooking`).
//
// The contract is build spec §2 "Fresh feed relay — contract as measured";
// the web client (`frontend/src/lib/freshFeed/relay.ts`) is the reference for
// logic except where that section says "≠ web". What this client does that
// the rest of the app's relay code does not:
//
// - Its own socket, through the `GroupRelayTransport` seam, never the shared
//   pool: nothing it opens joins another feed's subscriptions.
// - No signer, at all. The relay sends an AUTH challenge on connect and again
//   before every `CLOSED auth-required:`; those frames are dropped unread, and
//   the only frames this client ever sends are `REQ` and `CLOSE`.
// - Every event's id and signature are checked here; a bad one is dropped
//   and counted, never returned (the rest of the app does not verify).
// - `auth-required:` is the free tier's edge (`.floor`), never an error and
//   never a prompt. `invalid:` on a topic preview means the slug is unknown:
//   that slug is never asked again by this client. A feed page, recipes page
//   or tail refused `invalid:` is reported but stays retryable.
// - The live tail survives a dropped socket: it is marked lost, revived from
//   the app's foreground notification (the hook `NostrClock` uses), and
//   resumes with an overlap, de-duplicated by id. The relay admitted one post
//   827 s after its `created_at`, so resuming from "newest seen + 1" (what
//   web does) would lose posts like it.
//
// Nothing about viewing leaves the device: no request names the reader, and
// nothing here logs what was read.

/// How one request to the feed relay ended.
nonisolated enum FreshOutcome: Equatable, Sendable {
    /// `EOSE`: the relay sent everything it has for the request.
    case answered
    /// The free tier ends here: `CLOSED auth-required:`, or a feed page whose
    /// `until` is already older than the 14-day floor (not sent). Never an
    /// error, never a login prompt.
    case floor
    /// `CLOSED invalid:`. For a topic preview (an unknown slug) it is
    /// permanent: this client never asks that slug again. Any other request
    /// refused this way may be sent again.
    case invalid(reason: String)
    /// Any other `CLOSED`, a dropped connection, or `close()`.
    case failed(reason: String)
    /// No frame for this request within the silence timeout.
    case timedOut
}

/// What a request returned. `events` is what arrived and verified, kept on
/// every outcome: posts that arrived before a failure or a timeout are real.
nonisolated struct FreshAnswer: Sendable {
    /// Verified events, newest first (ties by id), not previously returned by
    /// this client's feed pages or live tail when the request is one of those.
    var events: [NostrEvent]
    var outcome: FreshOutcome
    /// `EVENT` frames the relay sent for the request (the last one sent, for
    /// a feed page that stepped past a full boundary second).
    var received: Int = 0
    /// Events dropped for a bad id or signature.
    var rejected: Int = 0
    /// The `limit` the deciding request asked for, when it had one.
    var asked: Int? = nil

    /// A feed page the relay ended short: the free window has no more posts.
    var isShortPage: Bool {
        guard outcome == .answered, let asked else { return false }
        return received < asked
    }

    /// The `until` for the next feed page: the oldest post returned
    /// (inclusive; the boundary post comes back once and is skipped).
    var oldestCreatedAt: Int? { events.last?.createdAt }
}

/// One element of the live tail's stream.
nonisolated enum FreshTailUpdate: Sendable {
    /// A verified post not already returned by a page or the tail.
    case event(NostrEvent)
    /// The connection carrying the tail dropped (or the relay closed it for a
    /// non-verdict reason): nothing arrives until it is revived.
    case lost
    /// Subscribed again, asking from `since` (newest seen minus the overlap).
    case revived(since: Int)
    /// The relay refused the tail with a verdict (`.floor` or `.invalid`).
    /// The stream finishes after this.
    case ended(FreshOutcome)
}

/// The filter a Fresh request sends. Built here rather than on `NostrFilter`
/// (main-actor isolated by the target's default isolation) because the
/// client runs off the main actor; it carries exactly the fields Fresh uses.
nonisolated struct FreshFilter: Sendable, Equatable {
    var kinds: [Int]
    var since: Int? = nil
    var until: Int? = nil
    var limit: Int? = nil
    var search: String? = nil
    var tTags: [String]? = nil

    var json: String {
        var object: [String: Any] = ["kinds": kinds]
        if let since { object["since"] = since }
        if let until { object["until"] = until }
        if let limit { object["limit"] = limit }
        if let search { object["search"] = search }
        if let tTags { object["#t"] = tTags }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

/// NIP-01 id and BIP-340 signature check for an event from the feed relay.
nonisolated enum FreshEventVerifier {
    static func isValid(_ event: NostrEvent) -> Bool {
        guard event.id.count == 64, event.pubkey.count == 64, event.sig.count == 128,
              event.id == event.id.lowercased() else { return false }
        let computed = NostrEvent.computeId(
            pubkey: event.pubkey, createdAt: event.createdAt, kind: event.kind,
            tags: event.tags, content: event.content
        )
        guard computed == event.id,
              let id = Hex.decode(event.id),
              let sig = Hex.decode(event.sig),
              let pubkey = Hex.decode(event.pubkey) else { return false }
        return Schnorr.verify(sig64: sig, messageId32: id, xonlyPubkey32: pubkey)
    }
}

actor FreshRelayClient {

    // MARK: Contract constants (build spec §2 "Fresh feed relay")

    /// Notes, long-form, polls. Kind 35000 is not requested.
    nonisolated static let kinds = [1, 30023, 1068]
    /// The relay's free window for readers who are not logged in.
    nonisolated static let freeWindowSeconds = 14 * 24 * 60 * 60
    nonisolated static let pageSize = 30
    /// The relay's `max_limit` (NIP-11).
    nonisolated static let maxLimit = 500
    /// The relay answers a topic preview with at most this many posts.
    nonisolated static let previewLimit = 5
    /// The tags that make kind 30023 "recipes" on this relay. The relay serves
    /// long-form at any age by kind, so the filter is what keeps blog posts out.
    nonisolated static let recipeTags = ["zapcooking", "nostrcooking"]
    /// Cap on the recipe pool (web's default).
    nonisolated static let maxRecipes = 2000
    /// How far before the newest post seen a revived tail asks from. The relay
    /// delivered one post 827 s after its `created_at` (probe 2026-11-10);
    /// an hour is more than four times that, and at the window's measured
    /// rate (616 events in 14 days, about 2 an hour) re-asking an hour costs
    /// a couple of duplicates, which the id de-duplication drops.
    nonisolated static let tailResumeOverlapSeconds = 60 * 60
    /// The backlog a (re)subscribed tail may return before it goes live.
    nonisolated static let tailBacklogLimit = 500
    /// Beyond this a relay ignoring `limit` can't grow one request unbounded.
    nonisolated static let maxEventsPerRequest = 1000
    /// A drop seen this soon after the app came to the foreground revives the
    /// tail at once: iOS often reports the background socket's death only
    /// when the app resumes, after the foreground notification has fired.
    nonisolated static let foregroundReviveGrace: TimeInterval = 10
    /// Clock skew allowed on a post's `created_at` (the app's 30 s, as in
    /// `OnlyFoodFilter.futureSkewSeconds`). A tail's resume point never moves
    /// past now plus this, so a future-dated post can't push it ahead.
    nonisolated static let futureSkewSeconds = 30

    // MARK: State

    private let url: URL
    private let transport: GroupRelayTransport
    private let now: @Sendable () -> Int
    private let silenceTimeout: TimeInterval
    private let notificationCenter: NotificationCenter
    private let foregroundNotification: Notification.Name

    private var socket: GroupRelaySocket?
    private var reader: Task<Void, Never>?
    /// Bumped per socket so a finished reader's late frames are ignored.
    private var generation = 0

    private var requests: [String: PendingRequest] = [:]
    private var tail: TailState?
    /// Ids returned by feed pages and the live tail (web's `seen`).
    private var seen: Set<String> = []
    /// Topic slugs the relay answered `invalid:` (as `topic:<slug>` keys);
    /// never asked again. Only previews are remembered.
    private var invalidTopics: Set<String> = []
    private var foregroundObserver: (any NSObjectProtocol)?
    private var lastForegroundAt: Date?

    private struct PendingRequest {
        let key: String
        let continuation: CheckedContinuation<FreshAnswer, Never>
        var events: [NostrEvent] = []
        var received = 0
        var rejected = 0
        let asked: Int?
        var timeout: Task<Void, Never>?
    }

    private struct TailState {
        /// Identifies this tail, so a finished stream's late termination
        /// can't stop a tail started after it.
        let token = UUID()
        let continuation: AsyncStream<FreshTailUpdate>.Continuation
        var subId: String?
        /// The `since` the tail was started with (clamped to the floor).
        let startSince: Int
        /// Newest `created_at` the tail delivered (verified, seen or not),
        /// clamped to now + `futureSkewSeconds`.
        var newest: Int
        var lost = false
    }

    init(
        url: URL = URL(string: FeedRelay.url)!,
        transport: GroupRelayTransport = URLSessionGroupRelayTransport(),
        now: @escaping @Sendable () -> Int = { NostrClock.now() },
        silenceTimeout: TimeInterval = 10,
        notificationCenter: NotificationCenter = .default,
        foregroundNotification: Notification.Name = UIApplication.willEnterForegroundNotification
    ) {
        self.url = url
        self.transport = transport
        self.now = now
        self.silenceTimeout = silenceTimeout
        self.notificationCenter = notificationCenter
        self.foregroundNotification = foregroundNotification
    }

    /// The start of the free window, by the corrected clock. The relay's own
    /// clock decides; a disagreement shows up as `.floor` on a page.
    var floor: Int { now() - Self.windowSeconds }

    /// The free window, or (DEBUG screenshot runs only) a narrower one.
    nonisolated static var windowSeconds: Int {
        #if DEBUG
        if let override = FreshScreenshotHarness.windowSecondsOverride { return override }
        #endif
        return freeWindowSeconds
    }

    // MARK: - Feed page

    /// One page of the feed, newest first: `since` = the floor, `until`
    /// inclusive (none = the newest). Posts already returned by this client
    /// are skipped, so the boundary post a page repeats is dropped. A page
    /// whose `until` is older than the floor is `.floor` without a request.
    func feedPage(until: Int? = nil, limit: Int = FreshRelayClient.pageSize) async -> FreshAnswer {
        let floor = self.floor
        if let until, until < floor {
            return FreshAnswer(events: [], outcome: .floor)
        }
        let base = FreshFilter(kinds: Self.kinds, since: floor, until: until, limit: limit)
        var answer = await request(base, key: "feed")
        var fresh = unseen(answer.events)
        // A full page of posts already shown: more posts share the boundary
        // second than fit on a page. Ask for that second again at the relay's
        // max; if even that is all shown, step past the second (web's rule).
        if answer.outcome == .answered, fresh.isEmpty, answer.received >= limit, let until {
            var wide = base
            wide.limit = Self.maxLimit
            let rejectedSoFar = answer.rejected
            answer = await request(wide, key: "feed")
            answer.rejected += rejectedSoFar
            fresh = unseen(answer.events)
            if answer.outcome == .answered, fresh.isEmpty, answer.received >= Self.maxLimit, until - 1 >= floor {
                var past = base
                past.until = until - 1
                let rejectedSoFar = answer.rejected
                answer = await request(past, key: "feed")
                answer.rejected += rejectedSoFar
                fresh = unseen(answer.events)
            }
        }
        for event in fresh { seen.insert(event.id) }
        answer.events = Self.newestFirst(fresh)
        return answer
    }

    /// Forget what pages and the tail returned (a full refresh).
    func resetSeen() {
        seen.removeAll()
    }

    // MARK: - Topic preview

    /// A topic's newest posts in the free window (at most five), for a
    /// spotlight card. Not de-duplicated against the feed. An unknown slug is
    /// `.invalid` and is never asked again by this client.
    func topicPreview(slug: String) async -> FreshAnswer {
        let filter = FreshFilter(
            kinds: Self.kinds, since: floor, limit: Self.previewLimit, search: "topic:\(slug)"
        )
        var answer = await request(filter, key: "topic:\(slug)")
        answer.events = Self.newestFirst(answer.events)
        return answer
    }

    // MARK: - Recipes

    /// Recipe long-form at any age: kind 30023 with the recipe `#t` filter and
    /// no `since` (the one request without it). Paged with an inclusive
    /// `until` at the relay's max until a page comes back short or adds
    /// nothing, up to `max`. A page that does not end `.answered` ends the
    /// walk with what was gathered so far.
    func recipes(max: Int = FreshRelayClient.maxRecipes) async -> FreshAnswer {
        var all: [String: NostrEvent] = [:]
        var until: Int?
        var rejected = 0
        var last = FreshAnswer(events: [], outcome: .answered)
        while all.count < max {
            let filter = FreshFilter(
                kinds: [30023], until: until, limit: Self.maxLimit, tTags: Self.recipeTags
            )
            last = await request(filter, key: "recipes")
            rejected += last.rejected
            var added = 0
            for event in last.events where all[event.id] == nil {
                all[event.id] = event
                added += 1
            }
            guard last.outcome == .answered, last.received >= Self.maxLimit, added > 0,
                  let oldest = last.events.map(\.createdAt).min() else { break }
            until = oldest
        }
        return FreshAnswer(
            events: Self.newestFirst(Array(all.values)), outcome: last.outcome,
            received: last.received, rejected: rejected, asked: last.asked
        )
    }

    // MARK: - Live tail

    /// New posts from `since` on as they arrive. One tail per client: starting
    /// another stops the previous one. The stream ends when the relay refuses
    /// the tail with a verdict, on `stopTail()` / `close()`, or when the
    /// consumer stops iterating.
    func liveTail(since: Int) -> AsyncStream<FreshTailUpdate> {
        stopTail()
        let (stream, continuation) = AsyncStream<FreshTailUpdate>.makeStream()
        let start = Swift.max(since, floor)
        let state = TailState(continuation: continuation, startSince: start, newest: start)
        tail = state
        let token = state.token
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopTail(token: token) }
        }
        observeForeground()
        subscribeTail(since: start)
        return stream
    }

    /// True while a tail exists and its connection has dropped.
    var tailIsLost: Bool { tail?.lost ?? false }

    /// Subscribe a lost tail again, from the newest post it delivered minus
    /// the overlap (never before the floor). True when revived.
    @discardableResult
    func reviveTail() -> Bool {
        guard let state = tail, state.lost else { return false }
        let anchor = Swift.max(state.startSince, state.newest)
        let since = Swift.max(floor, anchor - Self.tailResumeOverlapSeconds)
        subscribeTail(since: since)
        tail?.continuation.yield(.revived(since: since))
        return true
    }

    func stopTail() {
        guard let token = tail?.token else { return }
        stopTail(token: token)
    }

    private func stopTail(token: UUID) {
        guard let state = tail, state.token == token else { return }
        tail = nil
        if let subId = state.subId, !state.lost { socket?.send(Self.closeFrame(subId)) }
        state.continuation.finish()
        if let observer = foregroundObserver {
            notificationCenter.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    // MARK: - Lifecycle

    /// Close the socket: pending requests end `.failed` with what arrived,
    /// and the tail stops.
    func close() {
        stopTail()
        generation += 1
        tearDownSocket()
        for subId in Array(requests.keys) { finishRequest(subId, .failed(reason: "closed")) }
    }

    /// The app came to the foreground (the hook `NostrClock` also uses).
    func foregrounded() {
        lastForegroundAt = Date()
        reviveTail()
    }

    private func observeForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = notificationCenter.addObserver(
            forName: foregroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.foregrounded() }
        }
    }

    // MARK: - Requests

    nonisolated private static func subscriptionId() -> String {
        "fr-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }

    nonisolated private static func reqFrame(_ subId: String, _ filter: FreshFilter) -> String {
        "[\"REQ\",\"\(subId)\",\(filter.json)]"
    }

    nonisolated private static func closeFrame(_ subId: String) -> String {
        "[\"CLOSE\",\"\(subId)\"]"
    }

    /// One request to `EOSE` or `CLOSED`, as an outcome. The timeout is for
    /// silence: it restarts with every event, so a slow but steady page is
    /// not cut off. A topic slug the relay answered `invalid:` before is not
    /// asked again; every other request is always sent.
    private func request(_ filter: FreshFilter, key: String) async -> FreshAnswer {
        if invalidTopics.contains(key) {
            return FreshAnswer(events: [], outcome: .invalid(reason: "invalid: (refused earlier)"), asked: filter.limit)
        }
        let subId = Self.subscriptionId()
        return await withCheckedContinuation { continuation in
            requests[subId] = PendingRequest(key: key, continuation: continuation, asked: filter.limit)
            armTimeout(subId)
            send(Self.reqFrame(subId, filter))
        }
    }

    private func armTimeout(_ subId: String) {
        requests[subId]?.timeout?.cancel()
        let interval = silenceTimeout
        requests[subId]?.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            await self?.finishRequest(subId, .timedOut)
        }
    }

    private func finishRequest(_ subId: String, _ outcome: FreshOutcome) {
        guard let pending = requests.removeValue(forKey: subId) else { return }
        pending.timeout?.cancel()
        switch outcome {
        case .answered, .timedOut:
            // End the subscription on the relay too. After a CLOSED or a
            // dropped socket there is nothing to close.
            socket?.send(Self.closeFrame(subId))
        case .invalid:
            if pending.key.hasPrefix("topic:") { invalidTopics.insert(pending.key) }
        case .floor, .failed:
            break
        }
        pending.continuation.resume(returning: FreshAnswer(
            events: pending.events, outcome: outcome,
            received: pending.received, rejected: pending.rejected, asked: pending.asked
        ))
    }

    private func subscribeTail(since: Int) {
        guard tail != nil else { return }
        let subId = Self.subscriptionId()
        tail?.subId = subId
        tail?.lost = false
        let filter = FreshFilter(kinds: Self.kinds, since: since, limit: Self.tailBacklogLimit)
        send(Self.reqFrame(subId, filter))
    }

    private func markTailLost() {
        guard let state = tail, !state.lost else { return }
        tail?.lost = true
        tail?.subId = nil
        state.continuation.yield(.lost)
    }

    // MARK: - Socket

    private func send(_ frame: String) {
        ensureConnected()
        socket?.send(frame)
    }

    private func ensureConnected() {
        guard socket == nil else { return }
        generation += 1
        let current = generation
        let opened = transport.open(url: url)
        socket = opened
        opened.resume()
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await opened.receive()
                    guard let client = self else {
                        opened.cancel()
                        return
                    }
                    await client.handle(text, generation: current)
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
    }

    /// The socket dropped (or never opened): pending requests fail with what
    /// arrived, and the tail is lost.
    private func connectionLost(generation lost: Int) {
        guard lost == generation else { return }
        generation += 1
        tearDownSocket()
        for subId in Array(requests.keys) { finishRequest(subId, .failed(reason: "connection lost")) }
        guard tail != nil else { return }
        markTailLost()
        if let at = lastForegroundAt, Date().timeIntervalSince(at) < Self.foregroundReviveGrace {
            // Once per foreground: a socket that can't open must not loop.
            lastForegroundAt = nil
            reviveTail()
        }
    }

    // MARK: - Frames

    private func handle(_ text: String, generation frameGeneration: Int) {
        guard frameGeneration == generation,
              let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = frame.first as? String else { return }
        switch type {
        case "EVENT":
            guard frame.count >= 3, let subId = frame[1] as? String,
                  let object = frame[2] as? [String: Any] else { return }
            if requests[subId] != nil {
                receiveRequestEvent(subId, object)
            } else if subId == tail?.subId {
                receiveTailEvent(object)
            }
        case "EOSE":
            guard frame.count >= 2, let subId = frame[1] as? String else { return }
            finishRequest(subId, .answered)
            // A tail's EOSE ends its backlog; it stays open.
        case "CLOSED":
            guard frame.count >= 2, let subId = frame[1] as? String else { return }
            let reason = frame.count >= 3 ? (frame[2] as? String ?? "") : ""
            let outcome = Self.outcome(closedReason: reason)
            if requests[subId] != nil {
                finishRequest(subId, outcome)
            } else if subId == tail?.subId {
                tailClosed(outcome)
            }
        default:
            // AUTH is dropped unread: this client never logs in (build spec
            // §2, Guideline 2.1(b)). NOTICE, OK and anything else settle nothing.
            break
        }
    }

    nonisolated static func outcome(closedReason reason: String) -> FreshOutcome {
        if reason.hasPrefix("auth-required:") { return .floor }
        if reason.hasPrefix("invalid:") { return .invalid(reason: reason) }
        return .failed(reason: reason)
    }

    private func receiveRequestEvent(_ subId: String, _ object: [String: Any]) {
        guard var pending = requests[subId] else { return }
        pending.received += 1
        if pending.received <= Self.maxEventsPerRequest {
            if let event = NostrEvent(json: object), FreshEventVerifier.isValid(event) {
                if !pending.events.contains(where: { $0.id == event.id }) { pending.events.append(event) }
            } else {
                pending.rejected += 1
            }
        }
        requests[subId] = pending
        armTimeout(subId)
    }

    private func receiveTailEvent(_ object: [String: Any]) {
        guard let state = tail,
              let event = NostrEvent(json: object), FreshEventVerifier.isValid(event) else { return }
        // Clamped: a future-dated post must not move the resume point ahead.
        let createdAt = Swift.min(event.createdAt, now() + Self.futureSkewSeconds)
        if createdAt > state.newest { tail?.newest = createdAt }
        guard seen.insert(event.id).inserted else { return }
        state.continuation.yield(.event(event))
    }

    private func tailClosed(_ outcome: FreshOutcome) {
        switch outcome {
        case .floor, .invalid:
            // A verdict ends this tail; a later `liveTail` may ask again.
            guard let state = tail else { return }
            state.continuation.yield(.ended(outcome))
            tail?.subId = nil
            stopTail()
        case .answered, .failed, .timedOut:
            // Not a verdict on the request: treat as a lost connection.
            markTailLost()
        }
    }

    // MARK: - Helpers

    private func unseen(_ events: [NostrEvent]) -> [NostrEvent] {
        events.filter { !seen.contains($0.id) }
    }

    nonisolated static func newestFirst(_ events: [NostrEvent]) -> [NostrEvent] {
        events.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id < b.id
        }
    }
}
