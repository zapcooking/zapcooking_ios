import Foundation

/// Remembers which note each note quoted, so a quote stack survives losing a
/// note in the middle of it.
///
/// A quote chain is only discoverable one link at a time: A names B, and the
/// link from B to C lives inside B. Lose B — retracted, or simply on no relay
/// this client can reach — and C and everything under it become unreachable,
/// because the only record of that link was inside the note that's gone.
///
/// Recording the edge while B renders fixes that for anyone who saw B before
/// it went away. It is deliberately not a cache of notes: just
/// `id -> the id it quoted`, which is small enough to keep for a long time and
/// useless to anyone who obtains it without the notes themselves.
///
/// This can't help where the client never saw the middle note. Nothing
/// client-side can — see the NIP discussion in #460.
nonisolated final class QuoteGraph: @unchecked Sendable {
    static let shared = QuoteGraph()

    /// Roughly 100 bytes per entry, so 20k edges is ~2 MB. Quote chains are a
    /// small fraction of what a reader scrolls past.
    private static let maxEdges = 20_000

    /// Coalesces a burst — a feed page renders many quotes at once — into one
    /// write instead of one per edge.
    private static let saveDebounce: DispatchTimeInterval = .milliseconds(750)

    private static let storageKey = "quote_graph_edges"

    /// One `q` tag: the event id it quoted, plus that note's author when the
    /// tag named one. The author is what a NIP-09 signer check needs, and
    /// what an outbox lookup searches with.
    struct Edge: Codable, Equatable {
        let quotedId: String
        let quotedAuthor: String?
    }

    /// quoting event id -> every note it quoted, in the order they were
    /// seen. A note can carry several `q` tags (`EventStore.persist` records
    /// each one), and each is a link some chain may depend on.
    private var edges: [String: [Edge]] = [:]
    /// Insertion order, oldest first, for the bound below.
    private var order: [String] = []
    private let lock = NSLock()
    private var saveScheduled = false
    private let saveQueue = DispatchQueue(label: "talk.wisp.quote-graph.save", qos: .utility)

    private init() {
        load()
    }

    // MARK: - Record

    /// Record that `eventId` quotes `quotedId`. Called as a note renders, so
    /// it must not block: memory under the lock, with the write debounced.
    func record(eventId: String, quotedId: String, quotedAuthor: String?) {
        guard !eventId.isEmpty, !quotedId.isEmpty, eventId != quotedId else { return }
        lock.lock()
        var list = edges[eventId] ?? []
        if let i = list.firstIndex(where: { $0.quotedId == quotedId }) {
            // An author learned later is worth upgrading to — the first
            // sighting may have come from a bare `note1…` with no attribution.
            guard list[i].quotedAuthor == nil, quotedAuthor != nil else {
                lock.unlock()
                return
            }
            list[i] = Edge(quotedId: quotedId, quotedAuthor: quotedAuthor)
            edges[eventId] = list
        } else {
            let isNewQuoter = list.isEmpty
            list.append(Edge(quotedId: quotedId, quotedAuthor: quotedAuthor))
            edges[eventId] = list
            if isNewQuoter {
                order.append(eventId)
                while order.count > Self.maxEdges {
                    let oldest = order.removeFirst()
                    edges.removeValue(forKey: oldest)
                }
            }
        }
        lock.unlock()
        scheduleSave()
    }

    // MARK: - Read

    /// The first note `eventId` quoted, if this client ever saw it.
    func quoted(by eventId: String) -> Edge? {
        quotes(by: eventId).first
    }

    /// Every note `eventId` quoted, in the order its `q` tags were recorded.
    func quotes(by eventId: String) -> [Edge] {
        lock.lock()
        let list = edges[eventId] ?? []
        lock.unlock()
        return list
    }

    /// The author of a note, as remembered from whoever quoted it. Answers
    /// the attribution question for a note that can no longer be fetched.
    func author(of quotedId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        for list in edges.values {
            for edge in list where edge.quotedId == quotedId {
                if let author = edge.quotedAuthor { return author }
            }
        }
        return nil
    }

    func clear() {
        lock.lock()
        edges.removeAll()
        order.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        lock.lock()
        if saveScheduled {
            lock.unlock()
            return
        }
        saveScheduled = true
        lock.unlock()
        saveQueue.asyncAfter(deadline: .now() + Self.saveDebounce) { [weak self] in
            self?.save()
        }
    }

    private func save() {
        lock.lock()
        saveScheduled = false
        let snapshot = edges
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        if let stored = try? JSONDecoder().decode([String: [Edge]].self, from: data) {
            edges = stored
        } else if let single = try? JSONDecoder().decode([String: Edge].self, from: data) {
            // The first shape this key held: one edge per quoting id.
            edges = single.mapValues { [$0] }
        } else {
            return
        }
        // Order is lost across a restart; seed it so the bound still applies.
        order = Array(edges.keys)
    }
}
