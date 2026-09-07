import Foundation
import Testing
@testable import wisp

/// Issue #1 Part B live gate — seed a kind-10002 that carries a
/// "decommissioned" relay alongside real user relays with mixed markers,
/// run the repair against production relays, and assert the user relays
/// survived byte-for-byte. Then delete and confirm gone.
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.relay_repair_live_enable` or
/// `RELAY_REPAIR_LIVE=1`). Run with `-parallel-testing-enabled NO`.
///
/// §7.13: ephemeral keypair — never a real nsec, never printed, never
/// written to disk — held until the kind-5 is accepted and a re-query of the
/// author's kind-10002 on `RelayDefaults.defaults` returns nothing. Target
/// `RelayDefaults.defaults`, not the indexer union. A hang is a leak, not a
/// failed test to retry with a fresh key.
///
/// The "dead" relay is a reserved `.invalid` TLD host injected through the
/// repair's `Environment` — the production set is empty and stays empty; no
/// real relay is named dead by this test.
@Suite(.tags(.liveNetwork))
struct RelayListRepairLiveTests {

    private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".relay_repair_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["RELAY_REPAIR_LIVE"] == "1"
            || env["TEST_RUNNER_RELAY_REPAIR_LIVE"] == "1"
    }

    private static let deadRelay = "wss://decommissioned-probe.invalid"

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: RelayListRepairLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.relay_repair_live_enable (see ZAPCOOKING_IOS_BUILD.md)"
        )
    )
    @MainActor
    func seedWithDead_repair_userRelaysSurvive_delete_confirmedGone() async throws {
        let started = Date()
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
        let relays = RelayDefaults.defaults
        let suite = "RelayListRepairLiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // What another client might have published: mixed markers, an odd
        // spelling, a foreign tag, and the dead relay in the middle.
        let seededTags: [[String]] = [
            ["r", "wss://Relay.Primal.Net/", "read"],
            ["r", Self.deadRelay],
            ["r", "wss://nos.lol", "write"],
            ["client", "ios-issue-1-live"],
            ["r", "wss://relay.nostr.net"],
        ]
        let expectedAfter: [[String]] = seededTags.filter { $0 != ["r", Self.deadRelay] }

        var liveIds: [String] = []
        var deleteConfirmedGone = false

        func deleteAndConfirmGone() async {
            guard !liveIds.isEmpty, !deleteConfirmedGone else { return }
            var tags = liveIds.map { ["e", $0] }
            tags.append(["k", String(Nip51Lists.kindRelayList)])
            guard let deletion = try? await Signer.sign(
                keypair: keypair, kind: Nip09.kindDeletion, tags: tags, content: ""
            ) else {
                Issue.record("failed to sign kind-5 — kind-10002 remains live for \(keypair.pubkey)")
                return
            }
            let delAccepted = await RelayPool.publish(event: deletion, to: relays, timeout: 12)
            print("RelayRepair live: deleteAccepted=\(delAccepted)")
            #expect(!delAccepted.isEmpty, "no relay accepted the delete — list remains live")

            var leftover: [NostrEvent] = []
            for attempt in 1...4 {
                leftover = await Self.fetchRelayList(author: keypair.pubkey, relays: relays)
                if leftover.isEmpty { break }
                if attempt < 4 { try? await Task.sleep(for: .seconds(2)) }
            }
            print("RelayRepair live: leftoverAfterDelete=\(leftover.map(\.id))")
            #expect(leftover.isEmpty, "defaults still serving kind-10002 for \(keypair.pubkey) after delete")
            deleteConfirmedGone = leftover.isEmpty
        }

        do {
            // 1. Seed.
            let seedCreatedAt = NostrClock.now() - 5
            let seeded = try await Signer.sign(
                keypair: keypair, kind: Nip51Lists.kindRelayList,
                tags: seededTags, content: "", createdAt: seedCreatedAt
            )
            let seedAccepted = await RelayPool.publish(event: seeded, to: relays, timeout: 12)
            print("RelayRepair live: seedAccepted=\(seedAccepted)")
            #expect(!seedAccepted.isEmpty, "no relay accepted the seed")
            liveIds.append(seeded.id)

            // 2. Verify the seed is served with the dead relay in it.
            var served: NostrEvent?
            for attempt in 1...4 {
                served = await Self.fetchRelayList(author: keypair.pubkey, relays: relays)
                    .max { $0.createdAt < $1.createdAt }
                if served?.id == seeded.id { break }
                if attempt < 4 { try? await Task.sleep(for: .seconds(2)) }
            }
            #expect(served?.id == seeded.id, "seed not served back")
            #expect(served?.tags.contains(["r", Self.deadRelay]) == true)

            // 3. Repair with the dead host injected. Production paths for fetch,
            //    sign, and publish; only the set, the targets, and the marker
            //    store are substituted.
            var env = RelayListRepair.Environment.production
            env.decommissioned = [Self.deadRelay]
            env.publishTargets = { _ in relays }
            env.defaults = defaults
            env.fetchLatest = { pubkey in
                let r = await RelayPool.queryDetailed(
                    relays: relays,
                    filter: NostrFilter(kinds: [Nip51Lists.kindRelayList], authors: [pubkey], limit: 1),
                    timeout: 8, waitForAllRelays: true
                )
                return (r.events.filter { $0.kind == Nip51Lists.kindRelayList }.max { $0.createdAt < $1.createdAt },
                        r.relaysResponded)
            }
            var republished: NostrEvent?
            env.afterPublish = { republished = $0 }   // keep the live-test key out of app state
            let repair = RelayListRepair(env: env)

            let repairStart = Date()
            let outcome = await repair.runIfNeeded(keypair: keypair)
            print("RelayRepair live: outcome=\(outcome) in \(Date().timeIntervalSince(repairStart))s")
            #expect(outcome == .republished(removed: [Self.deadRelay]))
            if let republished { liveIds.append(republished.id) }

            // 4. The relays now serve the repaired list: user relays and
            //    markers intact, dead one gone, strictly newer created_at.
            var latest: NostrEvent?
            for attempt in 1...4 {
                latest = await Self.fetchRelayList(author: keypair.pubkey, relays: relays)
                    .max { $0.createdAt < $1.createdAt }
                if latest?.id == republished?.id { break }
                if attempt < 4 { try? await Task.sleep(for: .seconds(2)) }
            }
            #expect(latest?.id == republished?.id, "repaired list not served back")
            #expect(latest?.tags == expectedAfter, "user relays / markers / order not preserved: \(latest?.tags ?? [])")
            #expect((latest?.createdAt ?? 0) > seedCreatedAt)

            // 5. Idempotent against the live relays: marker → no-op; marker cleared → clean.
            #expect(await repair.runIfNeeded(keypair: keypair) == .alreadyDone)
            defaults.removeObject(forKey: RelayListRepair.markerKey(keypair.pubkey))
            #expect(await repair.runIfNeeded(keypair: keypair) == .clean)
            let afterSecond = await Self.fetchRelayList(author: keypair.pubkey, relays: relays)
                .max { $0.createdAt < $1.createdAt }
            #expect(afterSecond?.id == republished?.id, "second run must not republish")

            await deleteAndConfirmGone()
        } catch {
            await deleteAndConfirmGone()
            throw error
        }

        await deleteAndConfirmGone()
        print("RelayRepair live: total \(Date().timeIntervalSince(started))s; cleanup confirmed=\(deleteConfirmedGone)")
        #expect(deleteConfirmedGone, "key released only after the kind-10002 is confirmed gone")
    }

    private static func fetchRelayList(author: String, relays: [String]) async -> [NostrEvent] {
        await RelayPool.query(
            relays: relays,
            filter: NostrFilter(kinds: [Nip51Lists.kindRelayList], authors: [author], limit: 3),
            timeout: 8,
            waitForAllRelays: true
        ).filter { $0.kind == Nip51Lists.kindRelayList && $0.pubkey == author }
    }
}
