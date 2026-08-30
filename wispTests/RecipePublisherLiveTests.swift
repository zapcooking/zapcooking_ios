import Foundation
import Testing
@testable import wisp

/// Live recipe publish against public relays + zap.cooking (Concern 2.3
/// acceptance gate).
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.recipe_publish_live_enable` or
/// `RECIPE_PUBLISH_LIVE=1`). Uses an ephemeral keypair — never a real nsec,
/// never printed, never written to disk. The key is held in memory until
/// this test has published the matching delete and confirmed the coordinate
/// is gone from the articles union. Publish-without-delete is how the first
/// 2.3 run left eight real recipes on primal / nos.lol (§7.13).
///
/// The title still slugs to `ios-2.3-live-publish-<ts>` so a failed delete
/// is still client-hidden via `HiddenRecipes.dTagPrefixes`. That hide is
/// the safety net, not the cleanup: the gate still has to delete.
///
/// Confirms all four:
///  1. the event renders at `https://zap.cooking/r/{naddr}`
///  2. it is fetchable from the articles union the Recipes tab reads
///  3. which relays accepted vs rejected/timed out (partial success is a
///     finding, not a failure to paper over)
///  4. the same key then deletes the recipe (blanked replacement + kind-5)
///     and the articles union no longer serves an `isRecipe` at that
///     coordinate
@Suite(.tags(.liveNetwork))
struct RecipePublisherLiveTests {

    private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".recipe_publish_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        return ProcessInfo.processInfo.environment["RECIPE_PUBLISH_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: RecipePublisherLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.recipe_publish_live_enable (see ZAPCOOKING_IOS_BUILD.md)"
        )
    )
    func publish_ephemeralRecipe_landsOnWebAndArticlesUnion() async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))

        let stamp = Int(Date().timeIntervalSince1970)
        let title = "iOS 2.3 Live Publish \(stamp)"
        let sourceImage = "https://image.nostr.build/95df427de745f56529810d928a4b6dd059f972fd5aee86efc618cd92023486ad.jpg"
        let recipe = RecipeParser.Recipe(
            id: "",
            author: "",
            dTag: "",
            title: title,
            images: [sourceImage],
            summary: "Ephemeral Concern 2.3 live-publish probe. Safe to ignore.",
            publishedAt: 0,
            hashtags: [],
            categories: ["test"],
            content: RecipeParser.RecipeContent(
                chefNotes: "Published from the iOS simulator with an ephemeral key.",
                details: RecipeParser.RecipeDetails(prepTime: "1 min", cookTime: "1 min", servings: "1"),
                ingredients: ["1 ephemeral keypair", "1 cover image"],
                directions: ["Sign kind 30023.", "Broadcast to write ∪ articles ∪ pantry."]
            )
        )

        var cached: [NostrEvent] = []
        let publisher = await RecipePublisher(env: RecipePublisher.Environment(
            downloadImage: { url in
                await RecipePublisher.downloadCapped(url: url)
            },
            uploadBlossom: { bytes, mime, kp in
                let servers = BlossomServerList.cached(for: kp.pubkey)
                do {
                    return try await BlossomClient.upload(
                        bytes: bytes,
                        mime: mime,
                        servers: servers,
                        keypair: kp
                    ).url
                } catch {
                    return nil
                }
            },
            writeRelays: { _ in [] },
            cacheEvent: { cached.append($0) },
            applyLocalDeletion: { _, _ in },
            publish: { event, relays in
                await RelayPool.publish(event: event, to: relays, timeout: 12)
            },
            now: { NostrClock.now() },
            articlesRelays: RelayDefaults.articles,
            pantryRelay: RelayDefaults.members.first
        ))

        let result = try await publisher.publish(
            recipe: recipe,
            categories: ["test"],
            keypair: keypair,
            includeClientTag: true
        )
        guard case .published(let author, let dTag, let event, let targeted, let accepted) = result else {
            Issue.record("publish failed: \(result)")
            return
        }

        #expect(cached.count == 1)
        #expect(cached.first?.id == event.id)
        #expect(author == keypair.pubkey)
        #expect(dTag == RecipeSerializer.slug(title))
        #expect(RecipeParser.isRecipe(event))

        let acceptedSet = Set(accepted.map { RecipePublisher.normalizeRelay($0) })
        let rejected = targeted.filter { !acceptedSet.contains(RecipePublisher.normalizeRelay($0)) }

        // Partial success is a finding. Fail only if *nobody* took the event —
        // then it cannot render on the web or in the Recipes tab.
        #expect(
            !accepted.isEmpty,
            "no relay accepted. targeted=\(targeted) accepted=\(accepted) rejectedOrTimeout=\(rejected)"
        )

        // Recipes tab reads the articles union. Confirm at least one articles
        // relay will serve this coordinate.
        let articlesHit = RelayDefaults.articles.filter { articlesURL in
            acceptedSet.contains(RecipePublisher.normalizeRelay(articlesURL))
        }
        let fetched = await RelayPool.query(
            relays: RelayDefaults.articles,
            filter: RecipeFormats.primary.coordinateFilter(author: author, dTag: dTag),
            timeout: 15,
            waitForAllRelays: true
        )
        let found = fetched.contains { $0.id == event.id }
        #expect(
            found,
            "articles union did not echo the event. acceptedArticles=\(articlesHit) fetched=\(fetched.map(\.id))"
        )

        let naddr = try #require(Nip19.naddrEncode(kind: event.kind, pubkeyHex: author, dTag: dTag))
        let webURL = URL(string: "https://zap.cooking/r/\(naddr)")!
        var request = URLRequest(url: webURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(http.statusCode == 200, "web status=\(http.statusCode) url=\(webURL)")
        // The page should mention the recipe title or the naddr. A 200 that is
        // the generic 404-shell still has status 200 on some hosts, so look
        // for the title we published.
        let titleVisible = body.contains(title) || body.contains(dTag) || body.contains(naddr)
        #expect(
            titleVisible,
            "zap.cooking/r/{naddr} did not render the recipe. url=\(webURL) status=\(http.statusCode) bodyPrefix=\(body.prefix(400))"
        )

        // Print the relay ledger into the xcodebuild log — the gate asks for
        // which relays accepted vs rejected/timed out.
        print("RecipePublisher live: naddr=\(naddr)")
        print("RecipePublisher live: web=\(webURL.absoluteString)")
        print("RecipePublisher live: targeted=\(targeted)")
        print("RecipePublisher live: accepted=\(accepted)")
        print("RecipePublisher live: rejectedOrTimeout=\(rejected)")
        print("RecipePublisher live: articlesUnionHit=\(found) articlesAccepted=\(articlesHit)")

        // Cleanup is part of the gate. The privkey lives only in `keypair`
        // above; if we return without deleting, this recipe stays on the
        // production feed forever (NIP-09 needs this same pubkey).
        let deleted = try await publisher.delete(event: event, keypair: keypair)
        guard case .deleted(let delTargeted, let delAccepted) = deleted else {
            Issue.record("delete failed: \(deleted) — recipe remains live at \(webURL)")
            return
        }
        let delAcceptedSet = Set(delAccepted.map { RecipePublisher.normalizeRelay($0) })
        let delRejected = delTargeted.filter { !delAcceptedSet.contains(RecipePublisher.normalizeRelay($0)) }
        print("RecipePublisher live: deleteTargeted=\(delTargeted)")
        print("RecipePublisher live: deleteAccepted=\(delAccepted)")
        print("RecipePublisher live: deleteRejectedOrTimeout=\(delRejected)")
        #expect(
            !delAccepted.isEmpty,
            "no relay accepted the delete. targeted=\(delTargeted) accepted=\(delAccepted) — recipe remains live"
        )

        var leftover: [NostrEvent] = []
        for attempt in 1...3 {
            let after = await RelayPool.query(
                relays: RelayDefaults.articles,
                filter: RecipeFormats.primary.coordinateFilter(author: author, dTag: dTag),
                timeout: 15,
                waitForAllRelays: true
            )
            leftover = after.filter { RecipeParser.isRecipe($0) }
            if leftover.isEmpty { break }
            if attempt < 3 {
                try await Task.sleep(for: .seconds(2))
            }
        }
        #expect(
            leftover.isEmpty,
            "articles union still serving an isRecipe after delete. leftover=\(leftover.map(\.id))"
        )
    }
}
