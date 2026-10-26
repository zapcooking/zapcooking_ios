import Foundation
import os

private let liveDiscoveryLog = Logger(subsystem: "cooking.zap.app", category: "live-discovery")

/// Owns the long-lived NIP-53 discovery subscriptions for the current user session.
/// Two subs run in parallel:
///  - kind 30311 (live activities) — feeds `LiveStreamRepository.streams`
///  - kind 1311 since=now-3600 (recent live chat) — feeds chatter counts only (no full message storage)
///
/// Both stay open until `stopDiscovery()` is called (typically on logout). Per-stream chat/reaction/zap
/// subs are owned separately by `LiveStreamViewModel`.
@MainActor
final class LiveStreamCoordinator {
    static let shared = LiveStreamCoordinator()

    private var activitySub: RelaySubscription?
    private var chatDiscoverySub: RelaySubscription?
    private var consumerTasks: [Task<Void, Never>] = []
    private var profileFetchTask: Task<Void, Never>?
    private var pendingHostFetches = Set<String>()
    /// Indexer-query attempts per pubkey. Caps the pill row's self-heal so a
    /// host with no kind-0 anywhere doesn't get refetched on every re-request.
    private var hostFetchAttempts: [String: Int] = [:]
    private static let maxHostFetchAttempts = 3

    private static let indexerRelays = RelayDefaults.indexers

    func startDiscovery(myPubkey: String, readRelays: [String]) {
        guard activitySub == nil, chatDiscoverySub == nil else { return }
        let relays = Self.discoveryRelays(readRelays: readRelays)

        // All live activities republished in the last hour — the window the
        // repository's liveness rule keeps — rather than a newest-N window
        // that busy relays crowd with stale broadcasters.
        let activity = RelayPool.subscribe(
            relays: relays,
            filter: NostrFilter(
                kinds: [Nip53.kindLiveActivity],
                limit: 200,
                since: Int(Date().timeIntervalSince1970) - 3600
            ),
            id: "live-activities"
        )
        activitySub = activity

        let since = Int(Date().timeIntervalSince1970) - 3600
        let chat = RelayPool.subscribe(
            relays: relays,
            filter: NostrFilter(kinds: [Nip53.kindLiveChatMessage], limit: 500, since: since),
            id: "live-chat-discovery"
        )
        chatDiscoverySub = chat
        #if DEBUG
        liveDiscoveryLog.notice("discovery: start on \(relays.count, privacy: .public) relays: \(relays.joined(separator: ", "), privacy: .public)")
        #endif

        let activityTask = Task { [weak self] in
            for await (event, _) in activity.events {
                guard let self else { return }
                await MainActor.run {
                    #if DEBUG
                    let age = Int(Date().timeIntervalSince1970) - event.createdAt
                    let activity = Nip53.parseLiveActivity(event)
                    liveDiscoveryLog.notice("discovery: activity '\(activity?.title ?? "?", privacy: .public)' age=\(age / 60, privacy: .public)min url=\(activity?.streamingUrl?.isEmpty == false ? "yes" : "NO", privacy: .public) status=\(activity?.status ?? "?", privacy: .public)")
                    #endif
                    LiveStreamRepository.shared.addActivity(event)
                    self.queueHostProfileFetch(event.pubkey)
                    if let streamerPk = Nip53.parseLiveActivity(event)?.streamerPubkey {
                        self.queueHostProfileFetch(streamerPk)
                    }
                }
            }
        }
        consumerTasks.append(activityTask)

        let chatTask = Task {
            for await (event, _) in chat.events {
                await MainActor.run {
                    LiveStreamRepository.shared.trackChatter(event)
                }
            }
        }
        consumerTasks.append(chatTask)
    }

    /// The relay set live discovery asks: the user's NIP-65 read relays PLUS
    /// the app's indexers and a known live-coverage set. A read-relay-only
    /// subscription misses streams whose activities live on relays the
    /// account doesn't read (sidecar asks a broad set and dedupes; that is
    /// why its list ran longer). Bounded at 16 so a large read list can't
    /// open dozens of sockets for a passive row.
    static func discoveryRelays(readRelays: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for url in readRelays + RelayDefaults.indexers + [
            "wss://relay.ditto.pub",
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://relay.damus.io",
        ] {
            guard !url.isEmpty, seen.insert(url).inserted else { continue }
            out.append(url)
        }
        return out.count > 16 ? Array(out.prefix(16)) : out
    }

    func stopDiscovery() {
        for t in consumerTasks { t.cancel() }
        consumerTasks.removeAll()
        activitySub?.cancel()
        chatDiscoverySub?.cancel()
        activitySub = nil
        chatDiscoverySub = nil
        profileFetchTask?.cancel()
        profileFetchTask = nil
        pendingHostFetches.removeAll()
        hostFetchAttempts.removeAll()
    }

    // MARK: - Profile prefetch (debounced batch)

    /// Entry point for the pill row's self-heal: request a host profile that
    /// still hasn't resolved. Rides the same debounced batch as discovery, so
    /// a burst of requests (streams trickling in during startup) collapses
    /// into one indexer query instead of overlapping per-stream fetches.
    func requestHostProfile(_ pubkey: String) {
        queueHostProfileFetch(pubkey)
    }

    private func queueHostProfileFetch(_ pubkey: String) {
        // Already cached → publish straight to the observable repo so the pill
        // renders the avatar. (`ProfileRepository` alone isn't observable, so a
        // cache hit that never reaches `hostProfiles` is invisible to the row.)
        if let cached = ProfileRepository.shared.get(pubkey) {
            LiveStreamRepository.shared.setHostProfile(cached)
            return
        }
        guard hostFetchAttempts[pubkey, default: 0] < Self.maxHostFetchAttempts else { return }
        pendingHostFetches.insert(pubkey)
        if profileFetchTask == nil || profileFetchTask?.isCancelled == true {
            profileFetchTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.flushProfileFetches()
            }
        }
    }

    private func flushProfileFetches() async {
        let batch = Array(pendingHostFetches.prefix(50))
        pendingHostFetches.subtract(batch)
        profileFetchTask = nil
        guard !batch.isEmpty else { return }
        for pk in batch { hostFetchAttempts[pk, default: 0] += 1 }
        let events = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [0], authors: batch, limit: batch.count),
            timeout: 6
        )
        for event in events where event.kind == 0 {
            if let profile = ProfileRepository.shared.updateFromEvent(event) {
                LiveStreamRepository.shared.setHostProfile(profile)
            }
        }
        if !pendingHostFetches.isEmpty {
            profileFetchTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.flushProfileFetches()
            }
        }
    }
}
