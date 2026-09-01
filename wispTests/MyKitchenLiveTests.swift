import Foundation
import Testing
@testable import wisp

/// Concern 3.2 live gate — publish → appears in Published (the authored
/// repository query against live relays) → delete → gone from Published,
/// the feed session, and detail resolution without relaunch, then confirmed
/// gone from the relays themselves.
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.my_kitchen_live_enable` or
/// `MY_KITCHEN_LIVE=1`). Run with `-parallel-testing-enabled NO`.
///
/// §7.13, in full: ephemeral keypair — never a real nsec, never printed,
/// never written to disk — **held in memory until the delete is accepted
/// and a re-query of the coordinate comes back gone**. The d-tag
/// (`ios-3.2-my-kitchen-<stamp>`) is deliberately **not** a `HiddenRecipes`
/// prefix, and no new prefix may be minted as cleanup — the hide list is
/// the safety net for events whose keys are already gone. Publish, query,
/// and cleanup all target `RelayDefaults.defaults`, not the indexer union
/// (the 3.1 indexer-union run hung past 1000s; defaults finished in 27.8s).
@Suite(.tags(.liveNetwork))
struct MyKitchenLiveTests {

    private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".my_kitchen_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["MY_KITCHEN_LIVE"] == "1"
            || env["TEST_RUNNER_MY_KITCHEN_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: MyKitchenLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.my_kitchen_live_enable (see ZAPCOOKING_IOS_BUILD.md)"
        )
    )
    @MainActor
    func publish_appearsInPublished_delete_goneEverywhere_withoutRelaunch() async throws {
        let started = Date()
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))

        let stamp = Int(Date().timeIntervalSince1970)
        let title = "iOS 3.2 My Kitchen \(stamp)"
        let relays = RelayDefaults.defaults

        var publishedEvent: NostrEvent?
        var deleteConfirmedGone = false

        let publisher = RecipePublisher(env: RecipePublisher.Environment(
            downloadImage: { _ in nil },
            uploadBlossom: { _, _, _ in nil },
            writeRelays: { _ in [] },
            cacheEvent: { publishedEvent = $0 },
            applyLocalDeletion: { _, _ in },
            publish: { event, targets in
                await RelayPool.publish(event: event, to: targets, timeout: 12)
            },
            now: { NostrClock.now() },
            articlesRelays: relays,
            pantryRelay: nil
        ))

        /// Delete + confirm-gone. The gate's own final phase, and the §7.13
        /// cleanup on any earlier failure — one path, so a mid-test throw
        /// still deletes with the key this test is holding.
        func deleteAndConfirmGone() async {
            guard let event = publishedEvent, !deleteConfirmedGone else { return }
            let deleted = try? await publisher.delete(event: event, keypair: keypair)
            guard case .deleted(_, let accepted) = deleted else {
                Issue.record("delete failed: \(String(describing: deleted)) — recipe remains live at \(RecipeRepository.coordinate(event))")
                return
            }
            print("MyKitchen live: deleteAccepted=\(accepted)")
            #expect(!accepted.isEmpty, "no relay accepted the delete — recipe remains live")

            var leftover: [NostrEvent] = []
            for attempt in 1...4 {
                let after = await RelayPool.query(
                    relays: relays,
                    filter: RecipeFormats.primary.coordinateFilter(
                        author: keypair.pubkey,
                        dTag: RecipeParser.dTag(event)
                    ),
                    timeout: 15,
                    waitForAllRelays: true
                )
                leftover = after.filter { RecipeParser.isRecipe($0) }
                if leftover.isEmpty { break }
                if attempt < 4 { try? await Task.sleep(for: .seconds(2)) }
            }
            #expect(
                leftover.isEmpty,
                "defaults still serving an isRecipe after delete. leftover=\(leftover.map(\.id))"
            )
            deleteConfirmedGone = leftover.isEmpty
        }

        do {
            // Phase 1 — publish through the compose path.
            let vm = RecipeComposeViewModel()
            vm.title = title
            vm.addCategory("test")
            vm.summary = "Ephemeral Concern 3.2 live-gate probe. Safe to ignore."
            vm.updateIngredient(id: vm.ingredients[0].id, text: "1 ephemeral keypair")
            vm.updateDirection(id: vm.directions[0].id, text: "Publish, verify in Published, delete.")
            vm.addDirection()
            vm.updateDirection(id: vm.directions[1].id, text: "Confirm the coordinate is gone.")
            vm.addHostedImage(url: "https://image.nostr.build/95df427de745f56529810d928a4b6dd059f972fd5aee86efc618cd92023486ad.jpg")
            #expect(vm.blockReason(canSign: true) == nil)

            let publishStart = Date()
            await vm.publish(publisher: publisher, keypair: keypair, includeClientTag: true)
            guard case .published(let author, let dTag) = vm.publishState else {
                Issue.record("publish failed: \(vm.publishState)")
                return
            }
            let event = try #require(publishedEvent)
            #expect(author == keypair.pubkey)
            let coordinate = RecipeRepository.coordinate(event)
            print("MyKitchen live: published \(coordinate) in \(Date().timeIntervalSince(publishStart))s")

            // Phase 2 — appears in Published, through the authored
            // repository query (contract 2), not a view-side filter.
            let repo = RecipeRepository(relays: relays)
            let appearStart = Date()
            repo.loadAuthoredFeed(author: keypair.pubkey)
            await repo.authoredInFlight?.value
            for _ in 1...4 where !repo.authoredRecipes.contains(where: { RecipeRepository.coordinate($0) == coordinate }) {
                try? await Task.sleep(for: .seconds(2))
                repo.refreshAuthoredFeed()
                await repo.authoredInFlight?.value
            }
            #expect(
                repo.authoredRecipes.contains { RecipeRepository.coordinate($0) == coordinate },
                "published recipe never appeared in the authored session. held=\(repo.authoredRecipes.map(\.id))"
            )
            print("MyKitchen live: appeared in Published in \(Date().timeIntervalSince(appearStart))s")

            // Detail resolution — same repository instance, same session.
            let detail = await repo.requestRecipe(author: author, dTag: dTag)
            #expect(detail?.id == event.id, "detail did not resolve the published recipe")

            // Phase 3 — delete, then gone from Published, feed, and detail
            // on the SAME repository instance: no relaunch.
            let deleteStart = Date()
            await deleteAndConfirmGone()
            repo.removeRecipe(coordinate: coordinate, asOf: event.createdAt)
            repo.refreshAuthoredFeed()
            await repo.authoredInFlight?.value
            #expect(
                !repo.authoredRecipes.contains { RecipeRepository.coordinate($0) == coordinate },
                "deleted recipe still in Published without relaunch"
            )
            repo.refresh()
            await repo.inFlight?.value
            #expect(
                !repo.recipes.contains { RecipeRepository.coordinate($0) == coordinate },
                "deleted recipe still in the feed session without relaunch"
            )
            #expect(await repo.requestRecipe(author: author, dTag: dTag) == nil,
                    "deleted recipe still resolves in detail without relaunch")
            print("MyKitchen live: delete-and-gone in \(Date().timeIntervalSince(deleteStart))s")
        } catch {
            await deleteAndConfirmGone()
            throw error
        }

        await deleteAndConfirmGone()
        print("MyKitchen live: total \(Date().timeIntervalSince(started))s; cleanup confirmed=\(deleteConfirmedGone)")
        #expect(deleteConfirmedGone, "key released only after the coordinate is confirmed gone")
    }
}
