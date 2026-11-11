import Foundation
import os

/// The `since` the Follows feed sends with a load (#188). Pure, so the
/// decision can be tested without a view model or a socket.
///
/// `anchor` is the timestamp Follows is already synced to
/// (`FollowsSyncCursor`), or nil.
nonisolated enum FollowsSince {
    /// Re-request this much before the anchor, to absorb relay clock skew
    /// and notes that reached a relay late.
    static let overlapSeconds = 5 * 60
    /// The same, from the newest note already in the list.
    static let listOverlapSeconds = 60

    /// How far back a load reaches when there is no anchor: shorter for a
    /// larger follow list, whose relays return more per day.
    static func window(followCount: Int) -> Int {
        switch followCount {
        case ...10: return 7 * 24 * 3600
        case ...30: return 5 * 24 * 3600
        case ...75: return 3 * 24 * 3600
        case ...150: return 2 * 24 * 3600
        case ...300: return 36 * 3600
        default: return 24 * 3600
        }
    }

    /// A load into an empty list (cold start): from the anchor, but never
    /// further back than the window.
    static func coldStart(anchor: Int?, followCount: Int, now: Int) -> Int {
        let defaultSince = now - window(followCount: followCount)
        if let anchor, anchor > 0 {
            return max(anchor - overlapSeconds, defaultSince)
        }
        return defaultSince
    }

    /// Pull-to-refresh, and the load that follows picking Follows in the
    /// feed picker. An empty list loads like a cold start. With notes in
    /// the list, from the newest of them or from the anchor, whichever is
    /// earlier: the list is seeded from the shared event store, so its
    /// newest note may be one another feed stored, not one Follows synced.
    static func refresh(listNewest: Int?, anchor: Int?, followCount: Int, now: Int) -> Int {
        let synced = coldStart(anchor: anchor, followCount: followCount, now: now)
        guard let listNewest else { return synced }
        return min(listNewest - listOverlapSeconds, synced)
    }
}

/// How far the Follows feed has synced, per account (#188): the newest
/// `created_at` its own subscription delivered in a load that settled.
///
/// It used to be inferred from the newest note in `EventStore`, which every
/// feature writes to (OnlyFood, threads, profiles, engagement), so a note
/// another feed stored moved `since` past follows' notes nobody had fetched.
/// Only `FollowsLoadSettle` writes this.
nonisolated enum FollowsSyncCursor {
    static func key(_ pubkey: String) -> String { "follows_sync_cursor_\(pubkey)" }

    /// A cursor can never be later than now, give or take clock skew: a
    /// future-dated note must not push `since` into the future.
    static func clamped(_ timestamp: Int, now: Int) -> Int {
        min(timestamp, now + OnlyFoodFilter.futureSkewSeconds)
    }

    /// The cursor, clamped; nil when Follows has never settled a load for
    /// this account (or since its follow list changed).
    static func load(pubkey: String, now: Int, defaults: UserDefaults = .standard) -> Int? {
        let stored = defaults.integer(forKey: key(pubkey))
        return stored > 0 ? clamped(stored, now: now) : nil
    }

    /// Advance the cursor to `newest` (clamped). It never moves back.
    static func record(_ newest: Int, pubkey: String, now: Int, defaults: UserDefaults = .standard) {
        let value = max(clamped(newest, now: now), load(pubkey: pubkey, now: now, defaults: defaults) ?? 0)
        guard value > 0 else { return }
        defaults.set(value, forKey: key(pubkey))
    }

    /// Forget it: the next load reaches back the whole default window.
    static func clear(pubkey: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(pubkey))
    }
}

/// One Follows load, watched until it settles and its backlog is saved.
///
/// It settles when every relay that was asked has ended its backlog. Only
/// then may the cursor advance, to the newest note the load delivered — not
/// per event, so a load killed half-way leaves the cursor where it was and
/// the next load asks the slower relays again. A relay that never answers
/// means this load never settles, which errs the same way.
///
/// Settling is not enough on its own: at that moment the backlog has been
/// yielded to the feed's stream but not yet consumed, merged or written to
/// `EventStore`, and a feed switch in that window throws the unflushed
/// notes away. So the feed consumer reports every element it takes off the
/// stream (`consumed`), and the cursor is committed once the consumer has
/// taken all `streamCount` elements that were ahead of the settling answer
/// and the notes it accepted from them have been persisted.
///
/// Nothing is recorded if the load ends first (`end()`: replaced by the
/// next load, the feed switched away, or the view model stopped), or if the
/// follow list changed while it ran: its REQs named the old authors.
///
/// A `CLOSED` counts as an answer only when its reason says the request
/// will never be served (`blocked:`, `restricted:`, `invalid:`): asking that
/// relay again gets the same refusal, so waiting on it would stall the
/// cursor for nothing. Any other `CLOSED` (`rate-limited:`, `error:`, no
/// prefix) delivered nothing and may succeed next time, so the load stays
/// unsettled.
///
/// Each load writes one log line (`FollowsLoadReport`), at whichever comes
/// first: it settles, or it ends unsettled.
nonisolated final class FollowsLoadSettle: RelayBacklogObserver, @unchecked Sendable {
    /// The accepted backlog notes held until commit. A load holding more
    /// gives up on advancing the cursor rather than grow without bound.
    static let maxHeldEvents = 5_000

    /// `CLOSED` prefixes (NIP-01) that refuse the request for good.
    static let finalRejectionPrefixes = ["blocked:", "restricted:", "invalid:"]

    /// Production persistence for the held backlog.
    static func persistToStore(_ events: [NostrEvent]) async {
        await EventStore.shared.persist(events)
    }

    static func rejectionIsFinal(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        return finalRejectionPrefixes.contains { lowered.hasPrefix($0) }
    }

    private let pubkey: String
    private let askedRelays: Set<String>
    private let followListStamp: Int
    private let now: @Sendable () -> Int
    private let defaults: UserDefaults
    private let uptime: @Sendable () -> TimeInterval
    private let startedAt: TimeInterval
    private let report: @Sendable (String) -> Void
    private let persist: @Sendable ([NostrEvent]) async -> Void

    private let lock = NSLock()
    private var answeredRelays: Set<String> = []
    private var newest: Int?
    /// Stream elements ahead of the settling answer; set when settled.
    private var barrier: Int?
    private var consumedCount = 0
    private var held: [NostrEvent] = []
    private var overflowed = false
    private var ended = false
    private var committing = false
    private var reported = false

    /// `askedRelays` are the socket URLs the load was sent to, as the
    /// connection pool reports them (`RelayPool.wsURL(_:)?.absoluteString`).
    init(pubkey: String, askedRelays: Set<String>,
         now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
         defaults: UserDefaults = .standard,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         report: @escaping @Sendable (String) -> Void = FollowsLoadReport.log,
         persist: @escaping @Sendable ([NostrEvent]) async -> Void = FollowsLoadSettle.persistToStore) {
        self.pubkey = pubkey
        self.askedRelays = askedRelays
        self.followListStamp = FollowsCache.shared.storedCreatedAt(for: pubkey)
        self.now = now
        self.defaults = defaults
        self.uptime = uptime
        self.startedAt = uptime()
        self.report = report
        self.persist = persist
    }

    /// The load is over. Writes its log line unless settling already did,
    /// and stops it from settling or committing later (a late `EOSE` can
    /// still arrive while the socket deregisters). A commit already under
    /// way finishes: its notes were handed to persistence first.
    func end() {
        lock.lock()
        ended = true
        held = []
        guard !reported else {
            lock.unlock()
            return
        }
        reported = true
        let answered = answeredRelays.count
        lock.unlock()
        report(FollowsLoadReport.line(asked: askedRelays.count, answered: answered,
                                      settledAfter: nil))
    }

    func delivered(_ event: NostrEvent, from relayUrl: String) {
        lock.lock()
        if barrier == nil, !ended { newest = max(newest ?? 0, event.createdAt) }
        lock.unlock()
    }

    func answered(relayUrl: String, streamCount: Int) {
        markAnswered(relayUrl, streamCount: streamCount)
    }

    func rejected(relayUrl: String, reason: String, streamCount: Int) {
        guard Self.rejectionIsFinal(reason) else { return }
        markAnswered(relayUrl, streamCount: streamCount)
    }

    /// The feed consumer took one element off the subscription's stream, in
    /// order. `accepted`: it went into the feed (so it must be on disk
    /// before the cursor moves past it).
    func consumed(_ event: NostrEvent, accepted: Bool) {
        lock.lock()
        guard !ended, !committing else {
            lock.unlock()
            return
        }
        consumedCount += 1
        if accepted, !overflowed {
            held.append(event)
            if held.count > Self.maxHeldEvents {
                overflowed = true
                held = []
            }
        }
        let commit = takeCommitIfReady()
        lock.unlock()
        commit?()
    }

    private func markAnswered(_ relayUrl: String, streamCount: Int) {
        lock.lock()
        guard barrier == nil, !ended, !askedRelays.isEmpty, askedRelays.contains(relayUrl) else {
            lock.unlock()
            return
        }
        answeredRelays.insert(relayUrl)
        guard answeredRelays == askedRelays else {
            lock.unlock()
            return
        }
        barrier = streamCount
        let firstReport = !reported
        reported = true
        let commit = takeCommitIfReady()
        lock.unlock()

        if firstReport {
            report(FollowsLoadReport.line(asked: askedRelays.count, answered: askedRelays.count,
                                          settledAfter: uptime() - startedAt))
        }
        commit?()
    }

    /// Called under `lock`. Once settled and consumed up to the barrier,
    /// claims the commit and returns the work to run outside the lock.
    private func takeCommitIfReady() -> (() -> Void)? {
        guard let barrier, consumedCount >= barrier, !committing, !ended else { return nil }
        committing = true
        let batch = held
        held = []
        guard !overflowed, let newest else { return nil }
        return { [self] in
            if batch.isEmpty {
                recordCursor(newest)
            } else {
                Task.detached(priority: .utility) { [self] in
                    await persist(batch)
                    recordCursor(newest)
                }
            }
        }
    }

    private func recordCursor(_ newest: Int) {
        // Under the follow cache's lock: `update` can't swap the list (and
        // clear the cursor) between the stamp check and this write.
        FollowsCache.shared.ifFollowListUnchanged(pubkey: pubkey, stamp: followListStamp) {
            FollowsSyncCursor.record(newest, pubkey: pubkey, now: now(), defaults: defaults)
        }
    }
}

/// The one log line per Follows load: how many relays it asked, how many
/// ended their backlog, whether that was all of them, and how long it took.
/// Counts and a duration only; no relay URLs, authors or account.
nonisolated enum FollowsLoadReport {
    static let logger = Logger(subsystem: "wisp", category: "follows-sync")

    static func line(asked: Int, answered: Int, settledAfter: TimeInterval?) -> String {
        let seconds = settledAfter.map { String(format: "%.1f", max(0, $0)) } ?? "-"
        return "Follows load: relays asked \(asked), answered \(answered), "
            + "settled \(settledAfter == nil ? "no" : "yes"), seconds to settle \(seconds)"
    }

    static func log(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }
}
