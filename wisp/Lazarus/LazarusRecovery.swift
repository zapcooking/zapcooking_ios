import Foundation

// Lazarus core: rank, group, delta, the pre-sign re-read decision and the
// recovery draft. Pure and synchronous, so the conformance vectors in
// wispTests/Lazarus*Tests run without a network; the relay I/O lives in
// LazarusScanEngine / LazarusRelayClient and the one write path in
// LazarusPublisher.
//
// The four invariants (https://github.com/dmnyc/lazarus/blob/main/SPEC.md):
//  1. Nothing here publishes. A restore happens only when the user taps a
//     button that names what it publishes, signed by their own key.
//  2. Every candidate found is returned, including empty ones.
//  3. Empty candidates are never recommended (meaningful-empty kinds get no
//     recommendation at all).
//  4. The draft builder is the only signing surface; the caller owns the key
//     and the tap.

/// How a relay request ended. Only an answered relay counts as having
/// nothing; a failed or timed-out one never reads as "nothing found".
nonisolated enum LazarusRelayOutcome: String, Sendable, Equatable {
    /// The relay sent EOSE, with or without events.
    case answered
    /// The connection couldn't open, or the relay closed the request
    /// (`CLOSED`, e.g. `auth-required:`) or the connection before EOSE.
    case failed
    /// No EOSE within the per-relay timeout.
    case timedOut
}

/// The user's relay list: found (in the app's copy or on relays), missing
/// (relays answered without one, so the defaults stand in as write relays),
/// or unknown (no relay answered the lookup, so there are no write relays).
nonisolated enum LazarusRelayListStatus: Sendable, Equatable {
    case found
    case missing
    case unknown
}

nonisolated struct LazarusUserRelays: Sendable, Equatable {
    var read: [String]
    var write: [String]
    var status: LazarusRelayListStatus
}

/// An event together with the relay it was observed on.
nonisolated struct LazarusTaggedEvent: Sendable {
    let event: NostrEvent
    let relayUrl: String
}

nonisolated struct LazarusCandidate: Sendable, Identifiable {
    let event: NostrEvent
    /// Relays this exact event id was observed on.
    var foundOn: [String]
    var itemCount: LazarusItemCount
    /// The newest version the scan saw.
    var isCurrent: Bool
    var isRecommended: Bool

    var id: String { event.id }
}

/// One fetch across a set of relays: the first page of a scan, a page of
/// older versions, a retry of unreachable relays.
nonisolated struct LazarusFetchPage: Sendable {
    var tagged: [LazarusTaggedEvent] = []
    var queriedRelays: [String] = []
    /// Relays that returned at least one valid version.
    var respondingRelays: [String] = []
    /// Relays whose answer filled the page, keyed to the cursor for the next one.
    var olderCursors: [String: Int] = [:]
    var outcomes: [String: LazarusRelayOutcome] = [:]
}

nonisolated struct LazarusScanResult: Sendable {
    let kind: Int
    /// Ranked: size order for count kinds, newest first otherwise.
    var candidates: [LazarusCandidate]
    var current: LazarusCandidate?
    var recommended: LazarusCandidate?
    /// Meaningful-empty kinds: the user must choose with intent.
    var requiresIntentConfirmation: Bool
    var queriedRelays: [String]
    var respondingRelays: [String]
    /// True once at least one of the user's write relays answered. Until
    /// then the newest version found may not be current, nothing is
    /// recommended, and a restore is gated on the pre-sign re-read.
    var currentConfirmed: Bool
    /// How each queried relay's request ended; nil when the source reported none.
    var relayOutcomes: [String: LazarusRelayOutcome]? = nil
    var relayList: LazarusRelayListStatus? = nil
    /// Relays that may hold versions older than the scan returned, keyed to
    /// the `created_at` to page back from (`until` is inclusive).
    var olderCursors: [String: Int] = [:]
}

nonisolated enum LazarusListItem: Sendable, Identifiable {
    case version(LazarusCandidate)
    /// A run of small edits, or a clobber episode (`clobbered`).
    case group([LazarusCandidate], clobbered: Bool)

    var id: String {
        switch self {
        case .version(let candidate): return candidate.id
        case .group(let candidates, _): return "group:" + (candidates.first?.id ?? "")
        }
    }
}

nonisolated enum LazarusSortOrder: Sendable {
    case date
    case size
}

nonisolated struct LazarusDelta: Sendable, Equatable {
    var added: [[String]]
    var removed: [[String]]
    /// Either version carries encrypted private items that weren't
    /// decrypted, so the changes cover public tags only.
    var privateUnknown: Bool

    var addedCount: Int { added.count }
    var removedCount: Int { removed.count }
    /// The restore grows the list.
    var grows: Bool { !added.isEmpty && added.count >= removed.count }
    /// The restore shrinks the list below current: needs its own confirmation.
    var shrinks: Bool { removed.count > added.count }
}

nonisolated struct LazarusProfileChange: Sendable, Equatable {
    let field: String
    let from: String?
    let to: String?
}

/// One write relay's answer to the re-read before a restore: the valid
/// versions it sent, and whether it answered (sent EOSE). Versions from a
/// relay that failed or timed out still show an edit.
nonisolated struct LazarusReadAnswer: Sendable {
    var events: [NostrEvent]
    var answered: Bool
    var relay: String = ""
}

nonisolated enum LazarusCurrentCheck: Sendable {
    /// Nothing newer than the reviewed version, and a write relay answered.
    case proceed(current: NostrEvent?)
    /// A newer version appeared: it becomes current, and the user reviews again.
    case changed(current: NostrEvent)
    /// No write relay answered: current can't be confirmed, don't sign.
    case unconfirmed
}

nonisolated struct LazarusRecoveryDraft: Sendable, Equatable {
    let kind: Int
    let content: String
    let tags: [[String]]
    let createdAt: Int
}

nonisolated enum Lazarus {

    /// Per-relay timeout for every request (scan, lookup, re-read).
    static let relayTimeout: TimeInterval = 6
    static let publishTimeout: TimeInterval = 10
    /// Versions requested per relay. A relay that fills a page can be paged further back.
    static let scanLimit = 50

    /// A clobber drops a large share of a list at once, while curation moves
    /// a few items at a time. A step between two versions is a sudden drop
    /// when the later one is missing at least this share of the earlier
    /// one's items, and at least this many.
    static let clobberMinLossRatio = 0.2
    static let clobberMinLossItems = 5
    /// Drops within this long of each other are one clobber episode.
    static let clobberEpisodeSeconds = 24 * 60 * 60
    /// A clobber the list has since been edited on this many times, over at
    /// least this long, is settled: the current version is the user's choice.
    static let settledMinEdits = 5
    static let settledMinSeconds = 7 * 24 * 60 * 60

    /// A user's own relays usually keep only the latest version of a
    /// replaceable event, so a scan limited to them misses most of the
    /// history. These relays have been seen holding older versions:
    /// relay.ditto.pub keeps every version, hist.nostr.land keeps recent
    /// history, and the rest are large relays that often still have versions
    /// the user's own relays already replaced. Same set as the zap.cooking
    /// web and Android apps.
    static let archivalRelays = [
        "wss://relay.ditto.pub",
        "wss://hist.nostr.land",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://purplepag.es",
        "wss://nostr.bitcoiner.social",
    ]

    // MARK: - Validation

    /// Whether an event a relay returned counts as a version of the scanned
    /// list. Relays are untrusted: one can return events outside the filter,
    /// or forged ones, and a restore would sign their content as the user's
    /// own. Nothing that fails this becomes a candidate, adds a relay to a
    /// found-on list, or moves a paging cursor.
    static func isVersion(_ event: NostrEvent, kind: Int, pubkey: String) -> Bool {
        event.kind == kind && event.pubkey == pubkey && hasValidSignature(event)
    }

    /// The id is the hash of the event's own fields and the signature is the
    /// author's over that id.
    static func hasValidSignature(_ event: NostrEvent) -> Bool {
        let id = NostrEvent.computeId(
            pubkey: event.pubkey, createdAt: event.createdAt, kind: event.kind,
            tags: event.tags, content: event.content
        )
        guard id == event.id,
              let idBytes = Hex.decode(id),
              let sig = Hex.decode(event.sig),
              let pubkey = Hex.decode(event.pubkey) else { return false }
        return Schnorr.verify(sig64: sig, messageId32: idBytes, xonlyPubkey32: pubkey)
    }

    // MARK: - Relays

    /// Canonical relay URL, or nil for anything that isn't a reachable
    /// `ws(s)://` relay (`.onion` can't be dialed on iOS).
    static func normalizeRelay(_ raw: String) -> String? {
        guard let url = RelayUrlValidator.normalize(raw), !RelayUrlValidator.isOnion(url) else { return nil }
        return url
    }

    /// Normalized, deduplicated, first occurrence wins.
    static func uniqueRelays(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in urls {
            guard let url = normalizeRelay(raw), seen.insert(url).inserted else { continue }
            out.append(url)
        }
        return out
    }

    /// The relays a kind 10002 names. An unmarked relay is both read and
    /// write (NIP-65).
    static func parseRelayList(_ event: NostrEvent) -> (read: [String], write: [String]) {
        var read: [String] = []
        var write: [String] = []
        for tag in event.tags where tag.count >= 2 && tag[0] == "r" && !tag[1].isEmpty {
            let marker = tag.count >= 3 ? tag[2].lowercased() : ""
            if marker != "write" { read.append(tag[1]) }
            if marker != "read" { write.append(tag[1]) }
        }
        return (uniqueRelays(read), uniqueRelays(write))
    }

    /// The user's relay list from a kind 10002 (or the app's copy of one). A
    /// list naming no write relays counts as missing: the stand-ins become
    /// the write relays and the UI says so.
    static func userRelays(read: [String], write: [String], standIns: [String]) -> LazarusUserRelays {
        let write = uniqueRelays(write)
        guard !write.isEmpty else {
            return LazarusUserRelays(read: uniqueRelays(read), write: uniqueRelays(standIns), status: .missing)
        }
        return LazarusUserRelays(read: uniqueRelays(read), write: write, status: .found)
    }

    /// Relays to publish a restore to. Success is judged on the user's write
    /// relays; the other relays that answered the scan (or returned versions
    /// before failing) hold older copies and keep serving the clobbered one
    /// otherwise, so they get the restore as a best effort.
    ///
    /// A relay list restore (kind 10002) replaces the write relays themselves,
    /// so it's judged on the write relays the restored version names (the
    /// current ones may be the dead relays the restore is meant to fix); the
    /// current ones still get it as a best effort. A restored list naming no
    /// write relays is missing the same way a current one can be, and the
    /// stand-ins take its place. A restored DM relay list also goes to the
    /// DM relays it names, where peers look it up.
    static func publishRelays(
        currentWrite: [String],
        answeredRelays: [String],
        restoring: NostrEvent,
        standIns: [String]
    ) -> (judged: [String], extra: [String]) {
        let judged: [String]
        if restoring.kind == 10002 {
            let restored = parseRelayList(restoring).write
            judged = restored.isEmpty ? uniqueRelays(standIns) : restored
        } else {
            judged = uniqueRelays(currentWrite)
        }
        var extraSources = currentWrite + answeredRelays
        if restoring.kind == 10050 {
            extraSources += restoring.tags.compactMap { $0.count >= 2 && $0[0] == "relay" ? $0[1] : nil }
        }
        let judgedSet = Set(judged)
        return (judged, uniqueRelays(extraSources).filter { !judgedSet.contains($0) })
    }

    // MARK: - Paging

    /// A full page of valid versions means the relay may hold older ones.
    /// `until` is inclusive, so the next page repeats the oldest event; a
    /// cursor that didn't move means the relay has nothing older to give.
    static func nextCursor(validEvents: [NostrEvent], previous: Int?) -> Int? {
        guard validEvents.count >= scanLimit,
              let oldest = validEvents.map(\.createdAt).min() else { return nil }
        if let previous, oldest >= previous { return nil }
        return oldest
    }

    /// A scan no relay answered, with nothing to show: a failed scan, never
    /// "no versions found".
    static func isFailedScan(_ page: LazarusFetchPage) -> Bool {
        page.tagged.isEmpty && !page.outcomes.values.contains(.answered)
    }

    /// The scan got versions but no relay answered: what arrived may be incomplete.
    static func reachedNoRelay(_ scan: LazarusScanResult) -> Bool {
        guard let outcomes = scan.relayOutcomes else { return false }
        return !outcomes.values.contains(.answered)
    }

    // MARK: - Rank

    private static func countItems(
        _ profile: LazarusKindProfile,
        _ event: NostrEvent,
        _ privateTags: [[String]]?
    ) -> LazarusItemCount {
        let itemCount = profile.itemCount(event)
        guard let privateTags, let types = profile.privateItemTypes else { return itemCount }
        return LazarusItemCount(
            count: itemCount.count,
            partial: false,
            privateCount: LazarusPrivateItems.countItemTags(privateTags, types: types)
        )
    }

    private static func newerFirst(_ a: LazarusCandidate, _ b: LazarusCandidate) -> Bool {
        a.event.createdAt != b.event.createdAt ? a.event.createdAt > b.event.createdAt : a.id < b.id
    }

    /// Sum of a range's ends: orders ranges without favoring a wide estimate.
    private static func sizeKey(_ candidate: LazarusCandidate) -> Int {
        let range = candidate.itemCount.range
        return range.min + range.max
    }

    /// Whether a list of `laterMax` items looks clobbered next to an earlier
    /// one of `earlierMin`: sizes compare conservatively.
    static func looksClobbered(laterMax: Int, earlierMin: Int) -> Bool {
        if earlierMin <= 0 { return false }
        if laterMax <= 0 { return true }
        let loss = earlierMin - laterMax
        return loss >= clobberMinLossItems && Double(loss) >= Double(earlierMin) * clobberMinLossRatio
    }

    /// Versions with a known size, oldest first (the exact reverse of newest first).
    private static func knownTimeline(_ candidates: [LazarusCandidate]) -> [LazarusCandidate] {
        candidates.filter { $0.itemCount.isSizeKnown }.sorted { newerFirst($1, $0) }
    }

    private struct ClobberEpisode {
        /// Index of each version that dropped suddenly from the one before it.
        var drops: [Int]
        /// The episode's ends: just before its first drop, and its last drop.
        var first: Int
        var last: Int
    }

    /// Sudden drops in a timeline, newest episode first. Drops back to back
    /// or within a day of each other are one episode, however the list bounced.
    private static func clobberEpisodes(_ timeline: [LazarusCandidate]) -> [ClobberEpisode] {
        var episodes: [ClobberEpisode] = []
        guard timeline.count > 1 else { return episodes }
        for i in 1..<timeline.count {
            guard looksClobbered(
                laterMax: timeline[i].itemCount.range.max,
                earlierMin: timeline[i - 1].itemCount.range.min
            ) else { continue }
            if var open = episodes.last,
               i - 1 == open.last
                || timeline[i].event.createdAt - timeline[open.last].event.createdAt <= clobberEpisodeSeconds {
                open.drops.append(i)
                open.last = i
                episodes[episodes.count - 1] = open
            } else {
                episodes.append(ClobberEpisode(drops: [i], first: i - 1, last: i))
            }
        }
        return episodes.reversed()
    }

    /// The version to recommend: the fullest version from just before a drop
    /// in the most recent clobber episode the current version still hasn't
    /// recovered from. Curation moves a few items at a time and never
    /// registers as a drop, so a list that shrank slowly keeps its current
    /// version, however far it shrank. A clobber the list has since been
    /// edited on several times over at least a week is settled. Restore
    /// points are never empty (invariant 3): a drop needs a non-empty version
    /// before it.
    private static func restorePoint(
        _ candidates: [LazarusCandidate],
        current: LazarusCandidate
    ) -> LazarusCandidate? {
        let timeline = knownTimeline(candidates)
        let currentMax = current.itemCount.range.max
        for episode in clobberEpisodes(timeline) {
            var fullest = timeline[episode.drops[0] - 1]
            for drop in episode.drops.dropFirst() {
                let candidate = timeline[drop - 1]
                if candidate.itemCount.range.min >= fullest.itemCount.range.min { fullest = candidate }
            }
            guard looksClobbered(laterMax: currentMax, earlierMin: fullest.itemCount.range.min) else { continue }
            let edits = timeline.count - 1 - episode.last
            let settledFor = current.event.createdAt - timeline[episode.last].event.createdAt
            if edits >= settledMinEdits && settledFor >= settledMinSeconds { return nil }
            return fullest
        }
        return nil
    }

    /// Dedupe by event id (keeping every relay a version was found on), mark
    /// current, rank by the kind's profile, recommend per the spec.
    static func rank(
        _ profile: LazarusKindProfile,
        _ tagged: [LazarusTaggedEvent],
        queriedRelays: [String] = [],
        respondingRelays: [String] = [],
        privateTags: [String: [[String]]] = [:],
        currentConfirmed: Bool = true
    ) -> LazarusScanResult {
        var order: [String] = []
        var byId: [String: LazarusCandidate] = [:]
        for entry in tagged {
            if var existing = byId[entry.event.id] {
                if !existing.foundOn.contains(entry.relayUrl) {
                    existing.foundOn.append(entry.relayUrl)
                    byId[entry.event.id] = existing
                }
                continue
            }
            order.append(entry.event.id)
            byId[entry.event.id] = LazarusCandidate(
                event: entry.event,
                foundOn: [entry.relayUrl],
                itemCount: countItems(profile, entry.event, privateTags[entry.event.id]),
                isCurrent: false,
                isRecommended: false
            )
        }

        var candidates = order.compactMap { byId[$0] }
        let currentId = candidates.min(by: newerFirst)?.id
        for i in candidates.indices where candidates[i].id == currentId {
            candidates[i].isCurrent = true
        }
        let current = candidates.first { $0.isCurrent }

        var recommendedId: String?
        var ordered: [LazarusCandidate]
        if profile.ranking == .count {
            // Private items count too: a private-only mute list has no public
            // tags, so ranking on tags alone would score an emptied list like
            // a full one.
            ordered = candidates.sorted { a, b in
                let (sa, sb) = (sizeKey(a), sizeKey(b))
                return sa != sb ? sa > sb : newerFirst(a, b)
            }
            // Nothing is recommended while the current size is unknown, or
            // while no write relay answered: current may be a version the
            // user already replaced.
            if currentConfirmed, let current, current.itemCount.isSizeKnown {
                recommendedId = restorePoint(candidates, current: current)?.id
            }
        } else {
            // Recency kinds, and meaningful-empty kinds where ranking is
            // forbidden: newest first, the user chooses.
            ordered = candidates.sorted(by: newerFirst)
        }
        for i in ordered.indices where ordered[i].id == recommendedId {
            ordered[i].isRecommended = true
        }

        return LazarusScanResult(
            kind: profile.kind,
            candidates: ordered,
            current: ordered.first { $0.isCurrent },
            recommended: ordered.first { $0.isRecommended },
            requiresIntentConfirmation: profile.ranking == .intent,
            queriedRelays: queriedRelays,
            respondingRelays: respondingRelays,
            currentConfirmed: currentConfirmed
        )
    }

    /// Rank the first page of a scan. `writeRelays` are the user's (or the
    /// stand-ins, when the relay list is missing): current is confirmed only
    /// when one of them answered.
    static func scanResult(
        _ profile: LazarusKindProfile,
        page: LazarusFetchPage,
        writeRelays: [String],
        relayList: LazarusRelayListStatus,
        privateTags: [String: [[String]]] = [:]
    ) -> LazarusScanResult {
        var result = rank(
            profile, page.tagged,
            queriedRelays: page.queriedRelays,
            respondingRelays: page.respondingRelays,
            privateTags: privateTags,
            currentConfirmed: writeRelays.contains { page.outcomes[$0] == .answered }
        )
        result.relayOutcomes = page.outcomes
        result.relayList = relayList
        result.olderCursors = page.olderCursors
        return result
    }

    private static func taggedEvents(of scan: LazarusScanResult) -> [LazarusTaggedEvent] {
        scan.candidates.flatMap { candidate in
            candidate.foundOn.map { LazarusTaggedEvent(event: candidate.event, relayUrl: $0) }
        }
    }

    /// Re-rank with new versions merged in: decrypted private items, the
    /// newer version a re-read found. Relay outcomes and cursors carry over.
    static func merge(
        _ profile: LazarusKindProfile,
        _ scan: LazarusScanResult,
        adding tagged: [LazarusTaggedEvent] = [],
        privateTags: [String: [[String]]]
    ) -> LazarusScanResult {
        var result = rank(
            profile, taggedEvents(of: scan) + tagged,
            queriedRelays: scan.queriedRelays,
            respondingRelays: uniquePreservingOrder(scan.respondingRelays + tagged.map(\.relayUrl)),
            privateTags: privateTags,
            currentConfirmed: scan.currentConfirmed
        )
        result.relayOutcomes = scan.relayOutcomes
        result.relayList = scan.relayList
        result.olderCursors = scan.olderCursors
        return result
    }

    /// Merge a page of older versions. A relay whose page failed or timed out
    /// keeps its cursor, so the page can be asked for again: silence is not
    /// evidence that the relay is exhausted.
    static func mergeOlder(
        _ profile: LazarusKindProfile,
        _ scan: LazarusScanResult,
        page: LazarusFetchPage,
        privateTags: [String: [[String]]]
    ) -> LazarusScanResult {
        var result = merge(profile, scan, adding: page.tagged, privateTags: privateTags)
        var cursors = page.olderCursors
        for (url, cursor) in scan.olderCursors where cursors[url] == nil && page.outcomes[url] != .answered {
            cursors[url] = cursor
        }
        result.olderCursors = cursors
        return result
    }

    /// Merge a retry of the relays that failed or timed out. Their new
    /// outcomes replace the old ones, and a write relay answering now
    /// confirms current.
    static func mergeRetry(
        _ profile: LazarusKindProfile,
        _ scan: LazarusScanResult,
        page: LazarusFetchPage,
        writeRelays: [String],
        privateTags: [String: [[String]]]
    ) -> LazarusScanResult {
        let confirmed = scan.currentConfirmed || writeRelays.contains { page.outcomes[$0] == .answered }
        var result = rank(
            profile, taggedEvents(of: scan) + page.tagged,
            queriedRelays: uniquePreservingOrder(scan.queriedRelays + page.queriedRelays),
            respondingRelays: uniquePreservingOrder(scan.respondingRelays + page.respondingRelays),
            privateTags: privateTags,
            currentConfirmed: confirmed
        )
        result.relayOutcomes = (scan.relayOutcomes ?? [:]).merging(page.outcomes) { _, new in new }
        result.relayList = scan.relayList
        result.olderCursors = scan.olderCursors.merging(page.olderCursors) { _, new in new }
        return result
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Display

    /// Newest first, or largest first with newer versions first on ties.
    static func sorted(_ candidates: [LazarusCandidate], by order: LazarusSortOrder) -> [LazarusCandidate] {
        switch order {
        case .date:
            return candidates.sorted(by: newerFirst)
        case .size:
            return candidates.sorted { a, b in
                let (sa, sb) = (sizeKey(a), sizeKey(b))
                return sa != sb ? sa > sb : newerFirst(a, b)
            }
        }
    }

    /// An empty version from the past: evidence of a clobber rather than a
    /// state anyone wants back, so a list hides it until asked and never
    /// offers it for restore. Never the current version, and never on
    /// meaningful-empty kinds, where an empty version is a valid option.
    static func isPastEmptyVersion(_ candidate: LazarusCandidate, profile: LazarusKindProfile) -> Bool {
        !candidate.isCurrent
            && !profile.meaningfulEmpty
            && candidate.itemCount.isSizeKnown
            && candidate.itemCount.range.max == 0
    }

    /// Candidates newest first, folded into groups so a long history stays
    /// readable: runs of small edits, and clobber episodes, flagged so the
    /// sudden drops stand out. The current version keeps its own row, as do
    /// empty versions when shown. Only countable list kinds are grouped;
    /// every version stays reachable by expanding its group.
    static func group(
        _ scan: LazarusScanResult,
        profile: LazarusKindProfile,
        hidePastEmpty: Bool = false
    ) -> [LazarusListItem] {
        let newestFirst = sorted(scan.candidates, by: .date)
        let visible = hidePastEmpty
            ? newestFirst.filter { !isPastEmptyVersion($0, profile: profile) }
            : newestFirst
        guard profile.ranking == .count else { return visible.map { .version($0) } }

        let timeline = knownTimeline(scan.candidates)
        var episodeOf: [String: Int] = [:]
        for (n, episode) in clobberEpisodes(timeline).enumerated() {
            for i in episode.first...episode.last { episodeOf[timeline[i].id] = n }
        }

        var items: [LazarusListItem] = []
        var run: [LazarusCandidate] = []
        var runEpisode: Int?
        func flush() {
            if run.count == 1 { items.append(.version(run[0])) }
            if run.count > 1 { items.append(.group(run, clobbered: runEpisode != nil)) }
            run = []
        }
        for candidate in visible {
            let empty = candidate.itemCount.isSizeKnown && candidate.itemCount.range.max == 0
            if candidate.isCurrent || empty {
                flush()
                items.append(.version(candidate))
                continue
            }
            let episode = episodeOf[candidate.id]
            if !run.isEmpty && episode != runEpisode { flush() }
            runEpisode = episode
            run.append(candidate)
        }
        flush()
        return items
    }

    // MARK: - Delta

    /// What makes two tags the same item: their type and value. A relay hint
    /// or petname a client rewrote doesn't change who is followed or muted.
    /// On relay lists the read/write marker counts too, since it changes what
    /// the relay is for.
    static func itemIdentity(_ tag: [String], kind: Int) -> [String] {
        Array(tag.prefix(kind == 10002 ? 3 : 2))
    }

    static func delta(
        chosen: NostrEvent,
        current: NostrEvent?,
        privateTags: [String: [[String]]] = [:]
    ) -> LazarusDelta {
        // Decrypted private items compare together with the public tags, so
        // an item that only moved between public and private isn't a change.
        func items(_ event: NostrEvent?) -> (tags: [[String]], unknown: Bool) {
            guard let event else { return ([], false) }
            let decrypted = privateTags[event.id]
            return (event.tags + (decrypted ?? []),
                    decrypted == nil && LazarusPrivateItems.encryption(of: event.content) != nil)
        }
        func unique(_ tags: [[String]]) -> [[String]] {
            var order: [[String]] = []
            var byIdentity: [[String]: [String]] = [:]
            for tag in tags {
                let identity = itemIdentity(tag, kind: chosen.kind)
                if byIdentity[identity] == nil { order.append(identity) }
                byIdentity[identity] = tag
            }
            return order.compactMap { byIdentity[$0] }
        }
        let chosenItems = items(chosen)
        let currentItems = items(current)
        let chosenTags = unique(chosenItems.tags)
        let currentTags = unique(currentItems.tags)
        let chosenIds = Set(chosenTags.map { itemIdentity($0, kind: chosen.kind) })
        let currentIds = Set(currentTags.map { itemIdentity($0, kind: chosen.kind) })
        return LazarusDelta(
            added: chosenTags.filter { !currentIds.contains(itemIdentity($0, kind: chosen.kind)) },
            removed: currentTags.filter { !chosenIds.contains(itemIdentity($0, kind: chosen.kind)) },
            privateUnknown: chosenItems.unknown || currentItems.unknown
        )
    }

    /// Well-known profile fields, shown first in this order.
    static let profileFields = [
        "name", "display_name", "about", "picture", "banner", "nip05", "lud16", "lud06", "website",
    ]

    /// The profile (kind 0) fields and tags a restore would change. Profile
    /// content is extensible (pronouns, bot, client-specific fields) and a
    /// restore replaces all of it, tags included, so every field and tag
    /// counts: the well-known fields first, then any other field, then tags
    /// by name (NIP-30 custom emoji live there). Values that aren't strings
    /// show as JSON, and an empty string reads as absent.
    static func profileChanges(chosen: NostrEvent, current: NostrEvent?) -> [LazarusProfileChange] {
        func fields(_ event: NostrEvent?) -> [String: Any] {
            guard let data = (event?.content ?? "").data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
        func text(_ value: Any?) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            if let string = value as? String {
                return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
            }
            guard let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
            ) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        // Tag order carries no meaning here, so each tag name compares as a sorted set.
        func tags(_ event: NostrEvent?) -> [String: String] {
            var byName: [String: [String]] = [:]
            for tag in event?.tags ?? [] {
                guard let name = tag.first, !name.isEmpty else { continue }
                byName["\(name) tags", default: []].append(tag.dropFirst().joined(separator: " "))
            }
            return byName.mapValues { $0.sorted().joined(separator: ", ") }
        }
        let to = fields(chosen)
        let from = fields(current)
        let toTags = tags(chosen)
        let fromTags = tags(current)
        let wellKnown = Set(profileFields)
        let otherFields = Set(from.keys).union(to.keys).filter { !wellKnown.contains($0) }.sorted()
        let tagFields = Set(fromTags.keys).union(toTags.keys).sorted()
        let fieldChanges = (profileFields + otherFields).map {
            LazarusProfileChange(field: $0, from: text(from[$0]), to: text(to[$0]))
        }
        let tagChanges = tagFields.map { LazarusProfileChange(field: $0, from: fromTags[$0], to: toTags[$0]) }
        return (fieldChanges + tagChanges).filter { $0.from != $0.to }
    }

    // MARK: - Recover

    /// Decide the re-read before a restore. The list changed only if the
    /// local copy or a write relay holds a version newer than the one the
    /// delta was computed against: the re-read asks fewer relays than the
    /// scan, so an older copy is no edit. Otherwise at least one write relay
    /// must have answered (an answer with no events counts), or current can't
    /// be confirmed and the restore must not go ahead. The local copy can't
    /// confirm it on its own.
    static func checkCurrent(
        reviewed: NostrEvent?,
        local: NostrEvent?,
        answers: [LazarusReadAnswer]
    ) -> LazarusCurrentCheck {
        var newest = reviewed
        // Relay copies first, so a relay's real event wins a tie with this
        // device's copy of the same version.
        for event in answers.flatMap(\.events) + (local.map { [$0] } ?? []) {
            if let known = newest, event.createdAt <= known.createdAt { continue }
            newest = event
        }
        if let newest, newest.id != reviewed?.id { return .changed(current: newest) }
        guard answers.contains(where: \.answered) else { return .unconfirmed }
        return .proceed(current: reviewed)
    }

    /// The recovery event, unsigned. The chosen version's item set is copied
    /// verbatim, including encrypted private content (it stays encrypted to
    /// the user's own key). It's dated after the version it replaces even
    /// when a clobbering client's clock ran ahead, or relays and caches
    /// would keep the clobbered one.
    static func draft(chosen: NostrEvent, current: NostrEvent?, now: Int) -> LazarusRecoveryDraft {
        LazarusRecoveryDraft(
            kind: chosen.kind,
            content: chosen.content,
            tags: chosen.tags,
            createdAt: max(now, (current?.createdAt ?? 0) + 1)
        )
    }
}
