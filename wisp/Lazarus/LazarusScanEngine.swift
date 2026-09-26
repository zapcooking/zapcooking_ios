import Foundation

/// The relay sets a scan covers (spec "Scan" step 1). Configuration, not
/// protocol: two implementations with different sets see different
/// histories and both are conformant.
nonisolated struct LazarusRelaySets: Sendable {
    /// The app's own relays: where this app reads and writes the user's lists
    /// (`RelayDefaults.defaults`, the indexers `FollowSender` and profile
    /// edits publish to, and the onboarding set relay lists go to).
    var defaults: [String]
    /// Write relays that stand in when the user has no relay list, labeled as
    /// defaults wherever write relays are shown.
    var standIns: [String]
    var archival: [String]

    static let production = LazarusRelaySets(
        defaults: Lazarus.uniqueRelays(RelayDefaults.defaults + RelayDefaults.indexers + RelayDefaults.onboarding),
        standIns: Lazarus.uniqueRelays(RelayDefaults.defaults),
        archival: Lazarus.uniqueRelays(Lazarus.archivalRelays)
    )
}

nonisolated struct LazarusScanPlan: Sendable, Equatable {
    /// Every relay the scan asks: the user's relay list (read and write, not
    /// only the first few outbox relays), the defaults, the archival set.
    var relays: [String]
    var user: LazarusUserRelays

    /// Current is confirmed only once one of these answers.
    var write: [String] { user.write }
}

/// The relay I/O half of Lazarus: builds the relay set, asks every relay,
/// validates what comes back, and reports each relay's outcome. Validation
/// (id and signature checks) runs in the per-relay tasks, off the main actor.
nonisolated struct LazarusScanEngine: Sendable {
    let io: any LazarusRelayIO
    let sets: LazarusRelaySets
    /// Simultaneous relay requests. A scan fans out to the whole relay list
    /// plus the defaults and archival set; bounding it keeps a long list from
    /// opening dozens of sockets at once.
    let maxConcurrent: Int

    init(io: any LazarusRelayIO, sets: LazarusRelaySets = .production, maxConcurrent: Int = 16) {
        self.io = io
        self.sets = sets
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// The user's relay list: the app's copy when it holds one, otherwise the
    /// newest kind 10002 on the default and archival relays. A lookup that
    /// relays answered without a list is missing (the stand-ins become the
    /// write relays); one no relay answered is unknown, and nothing is
    /// substituted for it.
    func userRelays(pubkey: String, appCopy: LazarusUserRelays?) async -> LazarusUserRelays {
        if let appCopy { return appCopy }
        let filter = LazarusFilter(kinds: [10002], authors: [pubkey], limit: 1)
        let results = await fanOut(Lazarus.uniqueRelays(sets.defaults + sets.archival)) { relay in
            let answer = await io.query(relay: relay, filter: filter, timeout: Lazarus.relayTimeout)
            let valid = answer.events.filter { Lazarus.isVersion($0, kind: 10002, pubkey: pubkey) }
            return (outcome: answer.outcome, valid: valid)
        }
        // The newest by created_at, not the first to arrive. Versions a relay
        // sent before failing are real signed versions and count.
        let newest = results.flatMap(\.result.valid).max { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id > b.id
        }
        if let newest {
            let list = Lazarus.parseRelayList(newest)
            return Lazarus.userRelays(read: list.read, write: list.write, standIns: sets.standIns)
        }
        if results.contains(where: { $0.result.outcome == .answered }) {
            return LazarusUserRelays(read: [], write: sets.standIns, status: .missing)
        }
        return LazarusUserRelays(read: [], write: [], status: .unknown)
    }

    func plan(pubkey: String, appCopy: LazarusUserRelays?) async -> LazarusScanPlan {
        let user = await userRelays(pubkey: pubkey, appCopy: appCopy)
        return LazarusScanPlan(
            relays: Lazarus.uniqueRelays(user.write + user.read + sets.defaults + sets.archival),
            user: user
        )
    }

    /// Ask each relay for versions of `kind`: the first page, or with
    /// `cursors`, the next older page (`until` = the cursor). Only events
    /// that pass `Lazarus.isVersion` become candidates, mark a relay as
    /// responding, or move a cursor; a relay that answered with only invalid
    /// events answered with nothing.
    func fetch(kind: Int, pubkey: String, relays: [String], cursors: [String: Int]? = nil) async -> LazarusFetchPage {
        let results = await fanOut(relays) { relay in
            var filter = LazarusFilter(kinds: [kind], authors: [pubkey], limit: Lazarus.scanLimit)
            filter.until = cursors?[relay]
            let answer = await io.query(relay: relay, filter: filter, timeout: Lazarus.relayTimeout)
            // Validity first: a forged copy must not shadow the real event
            // with the same id.
            var seen = Set<String>()
            let valid = answer.events.filter {
                Lazarus.isVersion($0, kind: kind, pubkey: pubkey) && seen.insert($0.id).inserted
            }
            return (outcome: answer.outcome, valid: valid)
        }
        var page = LazarusFetchPage(queriedRelays: relays)
        for (relay, result) in results {
            page.outcomes[relay] = result.outcome
            guard !result.valid.isEmpty else { continue }
            page.respondingRelays.append(relay)
            page.tagged += result.valid.map { LazarusTaggedEvent(event: $0, relayUrl: relay) }
            if let cursor = Lazarus.nextCursor(validEvents: result.valid, previous: cursors?[relay]) {
                page.olderCursors[relay] = cursor
            }
        }
        return page
    }

    /// Every write relay's answer to the re-read before a restore. Waits for
    /// each of them up to the timeout rather than stopping at the first.
    func readCurrent(kind: Int, pubkey: String, writeRelays: [String]) async -> [LazarusReadAnswer] {
        let filter = LazarusFilter(kinds: [kind], authors: [pubkey], limit: 1)
        let results = await fanOut(writeRelays) { relay in
            let answer = await io.query(relay: relay, filter: filter, timeout: Lazarus.relayTimeout)
            return LazarusReadAnswer(
                events: answer.events.filter { Lazarus.isVersion($0, kind: kind, pubkey: pubkey) },
                answered: answer.outcome == .answered,
                relay: relay
            )
        }
        return results.map(\.result)
    }

    /// Send one signed event to each relay; the outcome per relay.
    func publish(_ event: NostrEvent, to relays: [String]) async -> [String: LazarusPublishOutcome] {
        let results = await fanOut(relays) { relay in
            await io.publish(event: event, relay: relay, timeout: Lazarus.publishTimeout)
        }
        return Dictionary(results.map { ($0.relay, $0.result) }, uniquingKeysWith: { first, _ in first })
    }

    /// Run `work` for every relay, at most `maxConcurrent` at a time, and
    /// return the results in relay order.
    private func fanOut<T: Sendable>(
        _ relays: [String],
        _ work: @escaping @Sendable (String) async -> T
    ) async -> [(relay: String, result: T)] {
        guard !relays.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, T).self) { group in
            let initial = min(maxConcurrent, relays.count)
            for index in 0..<initial {
                let relay = relays[index]
                group.addTask { (index, await work(relay)) }
            }
            var next = initial
            var results: [(Int, T)] = []
            results.reserveCapacity(relays.count)
            while let result = await group.next() {
                results.append(result)
                if next < relays.count {
                    let index = next
                    let relay = relays[index]
                    next += 1
                    group.addTask { (index, await work(relay)) }
                }
            }
            return results.sorted { $0.0 < $1.0 }.map { (relay: relays[$0.0], result: $0.1) }
        }
    }
}
