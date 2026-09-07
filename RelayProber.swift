import Foundation

/// Discovery + write-probe pipeline for new accounts that don't yet have a
/// kind-10002 relay list. Mirrors the Android `RelayProber` 5-phase flow:
///
///   1. Connect to bootstrap relays and harvest up to 500 kind-10002 events.
///   2. Tally `r`-tag URLs across harvested lists.
///   3. Drop the top 5 mega-relays, require ≥3 occurrences, take the next 15.
///   4. Concurrently probe each candidate by sending an ephemeral kind-20242
///      and waiting for its `OK`. Record per-relay latency.
///   5. Return the 8 lowest-latency passers as `[GeneralRelay]` (read+write).
///
/// On any failure path the fallback set is **probed the same way** and only
/// the passers are returned (`probedFallback`). The fallback constants are
/// never published unprobed: a relay that dies later would otherwise be signed
/// into every failed-discovery sign-up's public kind-10002 (issue #1). If
/// nothing passes, the result is empty and `SignUpViewModel` publishes no
/// relay list at all rather than an unverified one.
///
/// `RelayDefaults.decommissioned` is applied to the harvest tally and to the
/// fallback set before probing, so a confirmed-dead relay that still answers
/// `OK` (a zombie) cannot be selected either.
enum RelayProber {

    enum Phase: Equatable {
        case connecting
        case discovering
        case selecting
        case testing
        case done
        case failed
    }

    static let bootstrapRelays = [
        "wss://relay.primal.net",
        "wss://indexer.coracle.social",
        "wss://relay.nos.social"
    ]

    static let fallbackRelays: [GeneralRelay] = [
        GeneralRelay(url: "wss://relay.primal.net"),
        GeneralRelay(url: "wss://nos.lol"),
        GeneralRelay(url: "wss://relay.nos.social")
    ]

    static let harvestLimit = 500
    static let minFrequency = 3
    static let topExclude = 5
    static let candidatesToProbe = 15
    static let targetCount = 8
    static let probeTimeout: TimeInterval = 8
    static let harvestTimeout: TimeInterval = 10

    static func discoverAndSelect(
        keypair: Keypair,
        decommissioned: Set<String> = RelayDefaults.decommissioned,
        onPhase: @escaping @Sendable (Phase) -> Void,
        onProbing: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> [GeneralRelay] {
        onPhase(.connecting)
        let fallback = { @Sendable () async -> [GeneralRelay] in
            await probedFallback(decommissioned: decommissioned) { url in
                onProbing(url)
                return await probe(url: url, keypair: keypair)?.passed ?? false
            }
        }

        let harvested = await RelayPool.query(
            relays: bootstrapRelays,
            filter: NostrFilter(kinds: [10002], limit: harvestLimit),
            timeout: harvestTimeout
        )

        guard !harvested.isEmpty else {
            onPhase(.failed)
            return await fallback()
        }

        onPhase(.discovering)
        onPhase(.selecting)
        let candidates = candidates(from: harvested, decommissioned: decommissioned)
        guard !candidates.isEmpty else {
            onPhase(.failed)
            return await fallback()
        }

        onPhase(.testing)
        let results = await probeCandidates(candidates: candidates, keypair: keypair, onProbing: onProbing)
        let passed = results.filter(\.passed).sorted { $0.latencyMs < $1.latencyMs }

        guard !passed.isEmpty else {
            onPhase(.failed)
            return await fallback()
        }

        onPhase(.done)
        return passed.prefix(targetCount).map { GeneralRelay(url: $0.url, read: true, write: true) }
    }

    /// Harvest → tally → middle tier → decommission prune. Everything before
    /// the network probe, in one pure step so the prune on community-sourced
    /// URLs is testable without sockets.
    static func candidates(
        from events: [NostrEvent],
        decommissioned: Set<String> = RelayDefaults.decommissioned
    ) -> [String] {
        let tally = tallyRelayUrls(events)
        guard !tally.isEmpty else { return [] }
        return RelayDecommission.prune(urls: filterMiddleTier(tally), decommissioned: decommissioned)
    }

    /// The failure-path replacement for returning `fallbackRelays` verbatim:
    /// drop confirmed-decommissioned entries, then run the same write probe
    /// over what is left and keep only the relays that answered `OK`.
    /// Probe-driven, so it never rots the way a list does. `probe` is
    /// injectable for tests; production passes `probe(url:keypair:)`.
    static func probedFallback(
        decommissioned: Set<String> = RelayDefaults.decommissioned,
        probe: @escaping @Sendable (String) async -> Bool
    ) async -> [GeneralRelay] {
        let candidates = RelayDecommission.prune(fallbackRelays, decommissioned: decommissioned)
        guard !candidates.isEmpty else { return [] }
        let passed: Set<String> = await withTaskGroup(of: String?.self) { group in
            for relay in candidates {
                group.addTask { await probe(relay.url) ? relay.url : nil }
            }
            var ok = Set<String>()
            for await url in group { if let url { ok.insert(url) } }
            return ok
        }
        // Preserve the constant's order so the published list is stable.
        return candidates.filter { passed.contains($0.url) }
    }

    // MARK: - Internals

    private struct ProbeResult {
        let url: String
        let passed: Bool
        let latencyMs: Int
    }

    private static func tallyRelayUrls(_ events: [NostrEvent]) -> [String: Int] {
        var tally: [String: Int] = [:]
        for event in events where event.kind == 10002 {
            for tag in event.tags {
                guard tag.count >= 2, tag[0] == "r" else { continue }
                let url = normalize(tag[1])
                guard !url.isEmpty else { continue }
                tally[url, default: 0] += 1
            }
        }
        return tally
    }

    private static func filterMiddleTier(_ tally: [String: Int]) -> [String] {
        let sorted = tally.sorted { $0.value > $1.value }
        return sorted
            .dropFirst(topExclude)
            .filter { $0.value >= minFrequency }
            .prefix(candidatesToProbe)
            .map(\.key)
    }

    private static func probeCandidates(
        candidates: [String],
        keypair: Keypair,
        onProbing: @escaping @Sendable (String) -> Void
    ) async -> [ProbeResult] {
        await withTaskGroup(of: ProbeResult?.self) { group in
            for url in candidates {
                group.addTask {
                    onProbing(url)
                    return await probe(url: url, keypair: keypair)
                }
            }
            var results: [ProbeResult] = []
            for await r in group {
                if let r { results.append(r) }
            }
            return results
        }
    }

    private static func probe(url urlString: String, keypair: Keypair) async -> ProbeResult? {
        guard let url = URL(string: urlString),
              let privkey = Hex.decode(keypair.privkey) else {
            return ProbeResult(url: urlString, passed: false, latencyMs: 0)
        }

        let now = NostrClock.now()
        guard let event = try? NostrEvent.sign(
            privkey32: privkey,
            pubkey: keypair.pubkey,
            kind: 20242,
            createdAt: now,
            tags: [],
            content: ""
        ) else {
            return ProbeResult(url: urlString, passed: false, latencyMs: 0)
        }

        let start = Date()
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()

        let killer = Task {
            try? await Task.sleep(for: .seconds(probeTimeout))
            ws.cancel(with: .normalClosure, reason: nil)
        }
        defer {
            killer.cancel()
            ws.cancel(with: .normalClosure, reason: nil)
        }

        do {
            try await ws.send(.string("[\"EVENT\",\(event.toJSON())]"))
        } catch {
            return ProbeResult(url: urlString, passed: false, latencyMs: 0)
        }

        while !Task.isCancelled {
            do {
                let msg = try await ws.receive()
                guard case .string(let text) = msg else { continue }
                guard let data = text.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      let type = arr.first as? String else { continue }

                if type == "OK", arr.count >= 3,
                   let eventId = arr[1] as? String,
                   eventId == event.id,
                   let accepted = arr[2] as? Bool {
                    let latency = Int(Date().timeIntervalSince(start) * 1000)
                    return ProbeResult(url: urlString, passed: accepted, latencyMs: latency)
                }
            } catch {
                break
            }
        }
        return ProbeResult(url: urlString, passed: false, latencyMs: 0)
    }

    private static func normalize(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        let lower = u.lowercased()
        guard lower.hasPrefix("wss://") || lower.hasPrefix("ws://") else { return "" }
        return u
    }
}
