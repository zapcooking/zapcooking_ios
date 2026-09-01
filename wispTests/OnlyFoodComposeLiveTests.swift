import Foundation
import Testing
@testable import wisp

/// Live gate for Concern C-H — a kind-1 note composed the way the OnlyFood
/// FAB composes it (editor seeded with `OnlyFoodCompose.prefill`) is
/// published, comes back through the OnlyFood `#t` filter, passes the
/// feed's own accept chain, and is then deleted with the key held until the
/// id is confirmed gone (§7.13).
///
/// Opt-in: `touch wispTests/.onlyfood_compose_live_enable` or
/// `ONLYFOOD_COMPOSE_LIVE=1`. Ephemeral keypair — never printed, never
/// written to disk. Publish and cleanup target `RelayDefaults.defaults`
/// (the write set an account without a NIP-65 list gets). The OnlyFood
/// search relay is probed read-only and reported; whether the archive has
/// indexed the note within the probe window is a finding, not an
/// assertion — in-app visibility comes from the optimistic insert and, after
/// a relaunch, from the `EventStore` seed cache that `PostPublisher` persists
/// to.
///
/// The content marker is not a recipe d-tag and is not on any hide list.
@Suite(.tags(.liveNetwork))
struct OnlyFoodComposeLiveTests {

    private nonisolated static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".onlyfood_compose_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["ONLYFOOD_COMPOSE_LIVE"] == "1"
            || env["TEST_RUNNER_ONLYFOOD_COMPOSE_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: OnlyFoodComposeLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.onlyfood_compose_live_enable (see ZAPCOOKING_IOS_BUILD.md §7.13)"
        )
    )
    @MainActor
    func composeFromOnlyFood_publishVerifyDelete_keyHeldUntilGone() async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))

        let stamp = Int(Date().timeIntervalSince1970)
        let marker = "iOS C-H OnlyFood live gate \(stamp)"
        let relays = RelayDefaults.defaults
        let searchRelay = OnlyFoodFeedViewModel.searchRelay

        // Phase 1 — the composer, seeded exactly as the OnlyFood FAB seeds it,
        // then typed into below the seed. The `t` tags are the composer's own
        // derivation from the body (same regex path the publish pipeline
        // uses), plus the client tag.
        UserDefaults.standard.removeObject(forKey: "compose_autosave_new_\(keypair.pubkey)")
        let vm = ComposeViewModel(keypair: keypair, initialText: OnlyFoodCompose.prefill)
        #expect(vm.hashtags == ["foodstr"], "seed must derive the food tag before any keystroke")
        vm.updateContent(vm.content + "\(marker). Ephemeral key, safe to ignore.")
        #expect(vm.hashtags == ["foodstr"])
        var tags = vm.hashtags.map { ["t", $0] }
        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }
        let event = try await Signer.sign(keypair: keypair, kind: 1, tags: tags, content: vm.content)
        #expect(FoodHashtags.hasFoodTag(event))
        #expect(!OnlyFoodFilter.isStructuralSpam(event))

        // Phase 2 — publish.
        let accepted = await RelayPool.publish(event: event, to: relays, timeout: 12)
        print("OnlyFoodCompose live: id=\(event.id)")
        print("OnlyFoodCompose live: publishAccepted=\(accepted)")
        #expect(!accepted.isEmpty, "no default relay accepted the note")
        var seenOn = Set(accepted)

        func cleanup() async {
            var delTags = Nip09.deletionTagsForEvent(id: event.id, kind: 1)
            if let clientTag = NostrEvent.clientTagIfEnabled() { delTags.append(clientTag) }
            guard let deletion = try? await Signer.sign(
                keypair: keypair, kind: Nip09.kindDeletion, tags: delTags, content: "live gate cleanup"
            ) else {
                Issue.record("could not sign the delete — note \(event.id) remains live")
                return
            }
            let targets = Array(seenOn.union(relays))
            let delAccepted = await RelayPool.publish(event: deletion, to: targets, timeout: 12)
            print("OnlyFoodCompose live: deleteTargeted=\(targets)")
            print("OnlyFoodCompose live: deleteAccepted=\(delAccepted)")
            #expect(!delAccepted.isEmpty, "no relay accepted the delete — note remains live")

            var leftover: [NostrEvent] = []
            for attempt in 1...3 {
                let after = await RelayPool.query(
                    relays: targets,
                    filter: NostrFilter(kinds: [1], ids: [event.id]),
                    timeout: 15,
                    waitForAllRelays: true
                )
                leftover = after.filter { $0.id == event.id }
                if leftover.isEmpty { break }
                if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
            }
            #expect(leftover.isEmpty, "note \(event.id) still served after delete on \(targets)")
        }

        // Phase 3 — the OnlyFood filter brings it back, and the feed's
        // own accept chain admits it.
        let feedFilter = NostrFilter(kinds: [1], authors: [keypair.pubkey], tTags: FoodHashtags.all, limit: 10)
        let echoed = await RelayPool.query(relays: relays, filter: feedFilter, timeout: 15, waitForAllRelays: true)
        let found = echoed.first { $0.id == event.id }
        #expect(found != nil, "defaults did not echo the note through the OnlyFood #t filter. fetched=\(echoed.map(\.id))")
        if let found {
            #expect(FoodHashtags.hasFoodTag(found))
            #expect(OnlyFoodFilter.live().decideKind1(found) == .accept)
        }

        // Phase 4 — read-only probe of the OnlyFood search relay. Finding,
        // not assertion: reports whether the archive indexed the note
        // within the window.
        var indexedAfter: TimeInterval? = nil
        let probeStart = Date()
        for _ in 0..<6 {
            let hit = await RelayPool.query(
                relays: [searchRelay], filter: feedFilter, timeout: 8, waitForAllRelays: true
            )
            if hit.contains(where: { $0.id == event.id }) {
                indexedAfter = Date().timeIntervalSince(probeStart)
                seenOn.insert(searchRelay)
                break
            }
            try? await Task.sleep(for: .seconds(5))
        }
        if let indexedAfter {
            print("OnlyFoodCompose live: searchRelayIndexedAfter=\(String(format: "%.1f", indexedAfter))s")
        } else {
            print("OnlyFoodCompose live: searchRelayIndexedAfter=NOT_WITHIN_\(Int(Date().timeIntervalSince(probeStart)))s")
        }
        print("OnlyFoodCompose live: marker=\(marker)")
        await cleanup()
    }
}
