import Foundation
import os.log

private let repairLog = Logger(subsystem: "wisp", category: "relay-list-repair")

/// Issue #1 Part B — one-time republish of an account's kind-10002 without
/// the relays in `RelayDefaults.decommissioned`.
///
/// Part A stops a decommissioned relay from being carried into any *new*
/// publish. This closes the remaining gap: an account whose already-published
/// list still advertises one keeps doing so, to every client that reads it,
/// until something re-signs the list. This runs once per account per version
/// of the set, after `RelaySettingsRepository.bootstrap`.
///
/// Guarantees, in order of what would go wrong without them:
///
///  1. **Watch-only accounts never publish.** They cannot sign; nothing is
///     fetched, nothing is written, no marker is burned.
///  2. **The fetched event's tags are pruned, not the parsed list.**
///     `RelayDecommission.pruneTags` removes only `r` / `relay` tags whose
///     host is decommissioned and carries every other tag — surviving
///     relays' `read` / `write` markers, their order, extra positional
///     fields, foreign tags — into the new event byte-for-byte. Do not
///     refactor this onto `Nip51Lists.parseGeneralRelayList` +
///     `buildGeneralRelayTags`: that round trip normalises URLs and drops
///     unknown tags, which is a change to signed user data nobody asked for.
///  3. **Clobber guard.** The latest list is fetched with
///     `waitForAllRelays` across the same targets we publish to, and nothing
///     happens unless at least one relay answered (`relaysResponded > 0`). A
///     blind republish on an offline launch would supersede, by `created_at`,
///     a newer list from another client we merely failed to fetch.
///  4. **No-op when clean.** If nothing was removed there is no signing and
///     no publish; the marker is burned so the fetch is not repeated.
///  5. **Never publish an empty list.** If every relay in the list is
///     decommissioned the repair refuses; the user's next Settings edit
///     republishes with Part A's prune applied.
///  6. **Idempotent twice over.** The marker (`relay_list_repair_done_<pk>`,
///     value = `RelayDecommission.version`) stops a second run; and even
///     with the marker cleared, a second run fetches the repaired list, finds
///     nothing to remove, and exits at (4). Running it N times cannot compound.
///  7. **The marker is burned only on a settled outcome** (already done,
///     clean, no list, would-empty, or a publish at least one relay accepted).
///     Unreachable / sign failure / publish failure leave it unset so the
///     next launch retries.
///
/// The shipped set is empty, so today every account settles at `.clean`
/// without a fetch. The machinery is here for the first confirmed shutdown.
@MainActor
final class RelayListRepair {

    struct Environment {
        var decommissioned: Set<String>
        var isWatchOnly: (Keypair) -> Bool
        /// Latest kind-10002 for the pubkey plus how many relays answered.
        var fetchLatest: (String) async -> (event: NostrEvent?, relaysResponded: Int)
        /// Relays the account's list metadata is published to (write relays + indexers).
        var publishTargets: (String) -> [String]
        var sign: (Keypair, [[String]], Int) async throws -> NostrEvent
        /// Returns the relays that accepted the event.
        var publish: (NostrEvent, [String]) async -> [String]
        /// Persist + ingest the republished event so local state matches what is live.
        var afterPublish: (NostrEvent) async -> Void
        var now: () -> Int
        var defaults: UserDefaults

        static var production: Environment {
            Environment(
                decommissioned: RelayDefaults.decommissioned,
                isWatchOnly: { NostrKey.isWatchOnly(pubkey: $0.pubkey) },
                fetchLatest: { pubkey in
                    let targets = RelaySettingsRepository.shared.publishTargets(pubkey: pubkey)
                    let r = await RelayPool.queryDetailed(
                        relays: targets,
                        filter: NostrFilter(kinds: [Nip51Lists.kindRelayList], authors: [pubkey], limit: 1),
                        timeout: 6,
                        waitForAllRelays: true
                    )
                    let best = r.events
                        .filter { $0.kind == Nip51Lists.kindRelayList && $0.pubkey == pubkey }
                        .max { $0.createdAt < $1.createdAt }
                    return (best, r.relaysResponded)
                },
                publishTargets: { RelaySettingsRepository.shared.publishTargets(pubkey: $0) },
                sign: { keypair, tags, createdAt in
                    try await Signer.sign(keypair: keypair, kind: Nip51Lists.kindRelayList,
                                          tags: tags, content: "", createdAt: createdAt)
                },
                publish: { event, targets in
                    await RelayPool.publish(event: event, to: targets, timeout: 6)
                },
                afterPublish: { event in
                    await EventStore.shared.persist([event])
                    RelaySettingsRepository.shared.ingestRepublishedRelayList(event)
                },
                now: { NostrClock.now() },
                defaults: .standard
            )
        }
    }

    enum Outcome: Equatable {
        case watchOnly
        case alreadyDone
        /// Nobody answered the fetch; retried next launch, marker untouched.
        case unreachable
        case noList
        case clean
        /// Every relay in the list is decommissioned; refused to publish an empty list.
        case wouldEmpty
        case signFailed
        case publishFailed
        case republished(removed: [String])
    }

    static let shared = RelayListRepair(env: .production)

    private let env: Environment

    init(env: Environment) {
        self.env = env
    }

    static func markerKey(_ pubkey: String) -> String { "relay_list_repair_done_\(pubkey)" }

    @discardableResult
    func runIfNeeded(keypair: Keypair) async -> Outcome {
        guard !env.isWatchOnly(keypair) else { return .watchOnly }
        let pubkey = keypair.pubkey
        let version = RelayDecommission.version(of: env.decommissioned)
        let key = Self.markerKey(pubkey)
        if env.defaults.string(forKey: key) == version { return .alreadyDone }

        func settle(_ outcome: Outcome) -> Outcome {
            env.defaults.set(version, forKey: key)
            repairLog.info("kind-10002 repair settled: \(String(describing: outcome), privacy: .public)")
            return outcome
        }

        // Nothing to look for — no fetch, no publish.
        if env.decommissioned.isEmpty { return settle(.clean) }

        let fetched = await env.fetchLatest(pubkey)
        guard fetched.relaysResponded > 0 else { return .unreachable }
        guard let event = fetched.event else { return settle(.noList) }

        let (tags, removed) = RelayDecommission.pruneTags(event.tags, decommissioned: env.decommissioned)
        guard !removed.isEmpty else { return settle(.clean) }

        // Survivors that still carry a write side get the new list directly,
        // so the account's own outbox stops serving the stale one.
        let survivingWrite = tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "r" || tag[0] == "relay",
                  let url = RelayUrlValidator.canonicalize(tag[1]) else { return nil }
            if tag.count >= 3, tag[2].lowercased() == "read" { return nil }
            return url
        }
        let survivingAny = tags.contains { $0.count >= 2 && ($0[0] == "r" || $0[0] == "relay") }
        guard survivingAny else {
            repairLog.warning("kind-10002 repair: every relay is decommissioned; refusing to publish an empty list")
            return settle(.wouldEmpty)
        }

        let createdAt = max(event.createdAt + 1, env.now())
        guard let signed = try? await env.sign(keypair, tags, createdAt) else { return .signFailed }

        var seen = Set<String>()
        let targets = (env.publishTargets(pubkey) + survivingWrite).filter { seen.insert($0).inserted }
        let accepted = await env.publish(signed, targets)
        guard !accepted.isEmpty else {
            repairLog.warning("kind-10002 repair: no relay accepted the republish; retrying next launch")
            return .publishFailed
        }
        await env.afterPublish(signed)
        return settle(.republished(removed: removed))
    }
}
