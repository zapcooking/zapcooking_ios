import Foundation
import Testing
@testable import wisp

/// Issue #1 Part B — one-time kind-10002 republish. Hermetic: every network
/// and signing edge is an injected closure; the marker lives in a throwaway
/// UserDefaults suite. Signing uses a real ephemeral key (pure compute).
@MainActor
struct RelayListRepairTests {

    private let dead: Set<String> = ["wss://dead.example"]

    /// A list the way another client might have written it: mixed markers,
    /// an odd spelling, a foreign tag, and one decommissioned relay in the middle.
    private let originalTags: [[String]] = [
        ["r", "wss://Relay.Primal.Net/", "read"],
        ["r", "wss://dead.example"],
        ["r", "wss://nos.lol", "write"],
        ["client", "otherclient"],
        ["r", "wss://relay.nostr.net"],
    ]

    // MARK: - Harness

    /// Everything a run touched, for assertions.
    final class Trace {
        var fetches = 0
        var signed: [NostrEvent] = []
        var published: [(event: NostrEvent, targets: [String])] = []
        var ingested: [NostrEvent] = []
    }

    private struct Fixture {
        let keypair: Keypair
        let defaults: UserDefaults
        let suite: String
        let trace: Trace
        var env: RelayListRepair.Environment
    }

    private func fixture(
        decommissioned: Set<String>? = nil,
        watchOnly: Bool = false,
        latest: NostrEvent?? = nil,            // nil → serve `originalTags`; .some(nil) → no list
        relaysResponded: Int = 3,
        acceptPublish: Bool = true,
        signThrows: Bool = false
    ) throws -> Fixture {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
        let suite = "RelayListRepairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let trace = Trace()

        // A mutable "relay" so a second run sees what the first published.
        final class Store { var latest: NostrEvent? }
        let store = Store()
        switch latest {
        case .none: store.latest = makeEvent(pubkey: keypair.pubkey, tags: originalTags, createdAt: 1_800_000_000)
        case .some(let e): store.latest = e
        }

        let env = RelayListRepair.Environment(
            decommissioned: decommissioned ?? dead,
            isWatchOnly: { _ in watchOnly },
            fetchLatest: { _ in
                trace.fetches += 1
                return (store.latest, relaysResponded)
            },
            publishTargets: { _ in ["wss://indexer.example", "wss://nos.lol"] },
            sign: { kp, tags, createdAt in
                struct Boom: Error {}
                if signThrows { throw Boom() }
                let e = try await Signer.sign(keypair: kp, kind: 10002, tags: tags, content: "", createdAt: createdAt)
                trace.signed.append(e)
                return e
            },
            publish: { event, targets in
                trace.published.append((event, targets))
                guard acceptPublish else { return [] }
                store.latest = event
                return [targets[0]]
            },
            afterPublish: { trace.ingested.append($0) },
            now: { 1_800_000_500 },
            defaults: defaults
        )
        return Fixture(keypair: keypair, defaults: defaults, suite: suite, trace: trace, env: env)
    }

    // MARK: - Tests

    @Test func republish_removesOnlyDead_preservesMarkersOrderForeignTags() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let outcome = await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair)

        #expect(outcome == .republished(removed: ["wss://dead.example"]))
        #expect(f.trace.signed.count == 1)
        let signed = try #require(f.trace.signed.first)
        #expect(signed.tags == [
            ["r", "wss://Relay.Primal.Net/", "read"],
            ["r", "wss://nos.lol", "write"],
            ["client", "otherclient"],
            ["r", "wss://relay.nostr.net"],
        ])
        #expect(signed.kind == 10002)
        #expect(signed.pubkey == f.keypair.pubkey)
        #expect(signed.createdAt == 1_800_000_500)                 // max(orig+1, now)
        #expect(Schnorr.verify(
            sig64: try #require(Hex.decode(signed.sig)),
            messageId32: try #require(Hex.decode(signed.id)),
            xonlyPubkey32: try #require(Hex.decode(signed.pubkey))
        ))
        // Published to the metadata targets plus the surviving write relays, deduped.
        let targets = try #require(f.trace.published.first?.targets)
        #expect(targets == ["wss://indexer.example", "wss://nos.lol", "wss://relay.nostr.net"])
        #expect(f.trace.ingested.map(\.id) == [signed.id])
        #expect(f.defaults.string(forKey: RelayListRepair.markerKey(f.keypair.pubkey)) == RelayDecommission.version(of: dead))
    }

    @Test func createdAt_isStrictlyNewerThanOriginal_whenClockLags() async throws {
        var f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        f.env.now = { 1_700_000_000 }   // device clock behind the original event
        _ = await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair)
        #expect(f.trace.signed.first?.createdAt == 1_800_000_001)
    }

    @Test func idempotent_secondRunIsMarkerNoOp_andClearedMarkerFindsNothingToRemove() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let repair = RelayListRepair(env: f.env)

        #expect(await repair.runIfNeeded(keypair: f.keypair) == .republished(removed: ["wss://dead.example"]))
        #expect(await repair.runIfNeeded(keypair: f.keypair) == .alreadyDone)
        #expect(f.trace.fetches == 1)
        #expect(f.trace.published.count == 1)

        // Marker lost (reinstall, wipe): the repaired list is fetched, nothing is
        // removed, nothing is signed or published — a fixed point.
        f.defaults.removeObject(forKey: RelayListRepair.markerKey(f.keypair.pubkey))
        #expect(await repair.runIfNeeded(keypair: f.keypair) == .clean)
        #expect(f.trace.fetches == 2)
        #expect(f.trace.published.count == 1)
        #expect(f.trace.signed.count == 1)
    }

    @Test func noOp_whenListIsClean_burnsMarkerWithoutSigning() async throws {
        let clean = makeEvent(pubkey: "", tags: [["r", "wss://nos.lol"], ["r", "wss://relay.primal.net", "read"]], createdAt: 1)
        var f = try fixture(latest: .some(clean))
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        f.env.fetchLatest = { pk in (self.makeEvent(pubkey: pk, tags: clean.tags, createdAt: 1), 2) }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .clean)
        #expect(f.trace.signed.isEmpty)
        #expect(f.trace.published.isEmpty)
        #expect(f.defaults.string(forKey: RelayListRepair.markerKey(f.keypair.pubkey)) != nil)
    }

    @Test func emptySet_settlesCleanWithoutFetching() async throws {
        let f = try fixture(decommissioned: [])
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .clean)
        #expect(f.trace.fetches == 0)
        #expect(f.defaults.string(forKey: RelayListRepair.markerKey(f.keypair.pubkey)) == "empty")
    }

    @Test func setVersionChange_rerunsExactlyOnce() async throws {
        let f = try fixture(decommissioned: [])
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .clean)
        var env2 = f.env
        env2.decommissioned = dead
        let repair2 = RelayListRepair(env: env2)
        #expect(await repair2.runIfNeeded(keypair: f.keypair) == .republished(removed: ["wss://dead.example"]))
        #expect(await repair2.runIfNeeded(keypair: f.keypair) == .alreadyDone)
    }

    @Test func watchOnly_skipsEverything_andLeavesMarkerUnset() async throws {
        let f = try fixture(watchOnly: true)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .watchOnly)
        #expect(f.trace.fetches == 0)
        #expect(f.trace.signed.isEmpty)
        #expect(f.trace.published.isEmpty)
        #expect(f.defaults.string(forKey: RelayListRepair.markerKey(f.keypair.pubkey)) == nil)
    }

    @Test func unreachable_doesNotPublishOrBurnMarker() async throws {
        let f = try fixture(relaysResponded: 0)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .unreachable)
        #expect(f.trace.published.isEmpty)
        #expect(f.defaults.string(forKey: RelayListRepair.markerKey(f.keypair.pubkey)) == nil)
    }

    @Test func noList_settlesWithoutPublishing() async throws {
        let f = try fixture(latest: .some(nil))
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .noList)
        #expect(f.trace.published.isEmpty)
        #expect(f.defaults.string(forKey: RelayListRepair.markerKey(f.keypair.pubkey)) != nil)
    }

    @Test func refusesToPublishAnEmptyList() async throws {
        var f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        f.env.fetchLatest = { pk in
            (self.makeEvent(pubkey: pk, tags: [["r", "wss://dead.example"], ["r", "wss://DEAD.example/", "write"]], createdAt: 1), 1)
        }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .wouldEmpty)
        #expect(f.trace.signed.isEmpty)
        #expect(f.trace.published.isEmpty)
    }

    @Test func publishRejected_leavesMarkerUnset_soNextLaunchRetries() async throws {
        let f = try fixture(acceptPublish: false)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .publishFailed)
        #expect(f.trace.ingested.isEmpty)
        #expect(f.defaults.string(forKey: RelayListRepair.markerKey(f.keypair.pubkey)) == nil)
    }

    @Test func signFailure_leavesMarkerUnset() async throws {
        let f = try fixture(signThrows: true)
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        #expect(await RelayListRepair(env: f.env).runIfNeeded(keypair: f.keypair) == .signFailed)
        #expect(f.defaults.string(forKey: RelayListRepair.markerKey(f.keypair.pubkey)) == nil)
    }

    // MARK: - Helpers

    private func makeEvent(pubkey: String, tags: [[String]], createdAt: Int) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: pubkey,
            kind: 10002,
            createdAt: createdAt,
            tags: tags,
            content: "",
            sig: String(repeating: "2", count: 128)
        )
    }
}
