import Foundation
import Testing
@testable import wisp

/// Live recipe-compose publish against production relays + zap.cooking
/// (Concern 2.4). Goes through ``RecipeComposeViewModel.publish`` — the
/// form path, not the Sous Chef re-host overload.
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless
/// the operator opts in (`touch wispTests/.recipe_compose_live_enable`
/// or `RECIPE_COMPOSE_LIVE=1`). Uses an ephemeral keypair — never a
/// real nsec, never printed, never written to disk. The key is held in
/// memory until this test has published the matching delete and
/// confirmed the coordinate is gone from `RelayDefaults.defaults`.
///
/// Do **not** add a `HiddenRecipes` d-tag prefix as cleanup (§7.13).
/// Query and cleanup target **defaults**, not the indexer union.
@Suite(.tags(.liveNetwork))
struct RecipeComposeLiveTests {

    private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".recipe_compose_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["RECIPE_COMPOSE_LIVE"] == "1"
            || env["TEST_RUNNER_RECIPE_COMPOSE_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: RecipeComposeLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.recipe_compose_live_enable (see ZAPCOOKING_IOS_BUILD.md)"
        )
    )
    @MainActor
    func compose_publishVerifyDelete_keyHeldUntilGone() async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))

        let stamp = Int(Date().timeIntervalSince1970)
        let title = "iOS 2.4 Live Compose \(stamp)"
        let hostedImage = "https://image.nostr.build/95df427de745f56529810d928a4b6dd059f972fd5aee86efc618cd92023486ad.jpg"
        let relays = RelayDefaults.defaults

        var publishedEvent: NostrEvent?
        var cached: [NostrEvent] = []

        let publisher = RecipePublisher(env: RecipePublisher.Environment(
            downloadImage: { _ in nil },
            uploadBlossom: { _, _, _ in nil },
            writeRelays: { _ in [] },
            cacheEvent: { cached.append($0) },
            applyLocalDeletion: { _, _ in },
            publish: { event, targets in
                await RelayPool.publish(event: event, to: targets, timeout: 12)
            },
            now: { NostrClock.now() },
            articlesRelays: relays,
            pantryRelay: nil
        ))

        let vm = RecipeComposeViewModel()
        vm.title = title
        vm.addCategory("test")
        vm.summary = "Ephemeral Concern 2.4 live-compose probe. Safe to ignore."
        vm.chefNotes = "Published from the iOS compose form with an ephemeral key."
        vm.prepTime = "1 min"
        vm.cookTime = "1 min"
        vm.servings = "1"
        vm.updateIngredient(id: vm.ingredients[0].id, text: "1 ephemeral keypair")
        vm.addIngredient()
        vm.updateIngredient(id: vm.ingredients[1].id, text: "1 already-hosted cover image")
        vm.updateDirection(id: vm.directions[0].id, text: "Fill the compose form.")
        vm.addDirection()
        vm.updateDirection(id: vm.directions[1].id, text: "Publish, verify, delete.")
        vm.addHostedImage(url: hostedImage)

        #expect(vm.blockReason(canSign: true) == nil)

        await vm.publish(publisher: publisher, keypair: keypair, includeClientTag: true)
        guard case .published(let author, let dTag) = vm.publishState else {
            Issue.record("compose publish failed: \(vm.publishState)")
            return
        }
        let event = try #require(cached.first)
        publishedEvent = event
        #expect(author == keypair.pubkey)
        #expect(dTag == RecipeSerializer.slug(title))
        #expect(RecipeParser.isRecipe(event))

        func cleanup() async {
            guard let event = publishedEvent else { return }
            let deleted = try? await publisher.delete(event: event, keypair: keypair)
            guard case .deleted(let delTargeted, let delAccepted) = deleted else {
                Issue.record("delete failed: \(String(describing: deleted)) — recipe remains live")
                return
            }
            print("RecipeCompose live: deleteTargeted=\(delTargeted)")
            print("RecipeCompose live: deleteAccepted=\(delAccepted)")
            #expect(!delAccepted.isEmpty, "no relay accepted the delete — recipe remains live")

            var leftover: [NostrEvent] = []
            for attempt in 1...3 {
                let after = await RelayPool.query(
                    relays: relays,
                    filter: RecipeFormats.primary.coordinateFilter(author: author, dTag: dTag),
                    timeout: 15,
                    waitForAllRelays: true
                )
                leftover = after.filter { RecipeParser.isRecipe($0) }
                if leftover.isEmpty { break }
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            #expect(
                leftover.isEmpty,
                "defaults still serving an isRecipe after delete. leftover=\(leftover.map(\.id))"
            )
        }

        do {
            let accepted = await RelayPool.query(
                relays: relays,
                filter: RecipeFormats.primary.coordinateFilter(author: author, dTag: dTag),
                timeout: 15,
                waitForAllRelays: true
            )
            let found = accepted.contains { $0.id == event.id }
            #expect(found, "defaults did not echo the event. fetched=\(accepted.map(\.id))")

            let naddr = try #require(Nip19.naddrEncode(kind: event.kind, pubkeyHex: author, dTag: dTag))
            let webURL = URL(string: "https://zap.cooking/r/\(naddr)")!
            var request = URLRequest(url: webURL)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            let body = String(data: data, encoding: .utf8) ?? ""
            #expect(http.statusCode == 200, "web status=\(http.statusCode) url=\(webURL)")
            let titleVisible = body.contains(title) || body.contains(dTag) || body.contains(naddr)
            #expect(
                titleVisible,
                "zap.cooking/r/{naddr} did not render the recipe. url=\(webURL) status=\(http.statusCode) bodyPrefix=\(body.prefix(400))"
            )

            print("RecipeCompose live: naddr=\(naddr)")
            print("RecipeCompose live: web=\(webURL.absoluteString)")
            print("RecipeCompose live: title=\(title)")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
