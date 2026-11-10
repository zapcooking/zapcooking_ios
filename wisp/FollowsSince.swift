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

/// One Follows load, watched until it settles: every relay that was asked
/// has ended its backlog. Only then is the cursor advanced, to the newest
/// note the load delivered — not per event, so a load killed half-way
/// leaves the cursor where it was and the next load asks the slower relays
/// again. A relay that never answers means this load never settles, which
/// errs the same way.
///
/// Nothing is recorded if the follow list changed while the load ran: its
/// REQs named the old authors.
///
/// Each load writes one log line (`FollowsLoadReport`), at whichever comes
/// first: it settles, or it ends unsettled (`end()`: replaced by the next
/// load, the feed switched away, or the view model stopped).
nonisolated final class FollowsLoadSettle: RelayBacklogObserver, @unchecked Sendable {
    private let pubkey: String
    private let askedRelays: Set<String>
    private let followListStamp: Int
    private let now: @Sendable () -> Int
    private let defaults: UserDefaults
    private let uptime: @Sendable () -> TimeInterval
    private let startedAt: TimeInterval
    private let report: @Sendable (String) -> Void

    private let lock = NSLock()
    private var answeredRelays: Set<String> = []
    private var newest: Int?
    private var settled = false
    private var reported = false

    /// `askedRelays` are the socket URLs the load was sent to, as the
    /// connection pool reports them (`RelayPool.wsURL(_:)?.absoluteString`).
    init(pubkey: String, askedRelays: Set<String>,
         now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
         defaults: UserDefaults = .standard,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         report: @escaping @Sendable (String) -> Void = FollowsLoadReport.log) {
        self.pubkey = pubkey
        self.askedRelays = askedRelays
        self.followListStamp = FollowsCache.shared.storedCreatedAt(for: pubkey)
        self.now = now
        self.defaults = defaults
        self.uptime = uptime
        self.startedAt = uptime()
        self.report = report
    }

    /// The load is over without having settled (replaced, feed switched,
    /// view model stopped). Writes its log line unless settling already did.
    func end() {
        lock.lock()
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
        if !settled { newest = max(newest ?? 0, event.createdAt) }
        lock.unlock()
    }

    func answered(relayUrl: String) {
        lock.lock()
        guard !settled, !askedRelays.isEmpty, askedRelays.contains(relayUrl) else {
            lock.unlock()
            return
        }
        answeredRelays.insert(relayUrl)
        guard answeredRelays == askedRelays else {
            lock.unlock()
            return
        }
        settled = true
        let newest = self.newest
        let firstReport = !reported
        reported = true
        lock.unlock()

        if firstReport {
            report(FollowsLoadReport.line(asked: askedRelays.count, answered: askedRelays.count,
                                          settledAfter: uptime() - startedAt))
        }

        guard let newest,
              FollowsCache.shared.storedCreatedAt(for: pubkey) == followListStamp else { return }
        FollowsSyncCursor.record(newest, pubkey: pubkey, now: now(), defaults: defaults)
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
