import Foundation
import Testing
@testable import wisp

/// Live NIP-51 saved-list write against production relays (Concern 3.1).
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.recipe_bookmark_live_enable` or
/// `RECIPE_BOOKMARK_LIVE=1`). Uses an ephemeral keypair — never a real nsec,
/// never printed, never written to disk. The key is held in memory until
/// this test has published the matching delete and confirmed the kind-30001
/// coordinate is gone. Publish-without-delete is how the first 2.3 run left
/// eight real recipes on primal / nos.lol (§7.13).
///
/// Do **not** add a `HiddenRecipes` d-tag prefix as cleanup. The hide list
/// is the safety net for events whose keys are already gone, not a
/// substitute for delete. This test writes a kind-30001 list (not a recipe
/// card); a new prefix would not hide it and would repeat the §7.13 failure.
///
/// Gates: save and unsave across a cold start with an existing collection
/// already on relays. Reports the published `a`-set before and after.
@Suite(.tags(.liveNetwork))
struct RecipeBookmarkLiveTests {

    private nonisolated static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".recipe_bookmark_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["RECIPE_BOOKMARK_LIVE"] == "1"
            || env["TEST_RUNNER_RECIPE_BOOKMARK_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: RecipeBookmarkLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.recipe_bookmark_live_enable (see ZAPCOOKING_IOS_BUILD.md)"
        )
    )
    @MainActor
    func saveAndUnsave_coldSession_existingCollection_appendsThenDeletes() async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))

        let stamp = Int(Date().timeIntervalSince1970)
        let coordA = "30023:\(keypair.pubkey):ios-3.1-existing-a-\(stamp)"
        let coordB = "30023:\(keypair.pubkey):ios-3.1-existing-b-\(stamp)"
        let coordC = "30023:\(keypair.pubkey):ios-3.1-saved-\(stamp)"
        // Defaults only — indexers are the kind-0/3/10002 discovery pool and
        // do not reliably EOSE a kind-30001 REQ. A first live run against
        // the indexer ∪ hung past 1000s and lost the result bundle.
        let relays = RelayDefaults.defaults
        var latestList: NostrEvent?

        func cleanup() async {
            guard let latest = latestList else { return }
            let empty = try? await Signer.sign(
                keypair: keypair,
                kind: RecipeBookmarkRepository.listKind,
                tags: [
                    ["d", RecipeBookmarkRepository.defaultListDTag],
                    ["title", RecipeBookmarkRepository.defaultListTitle],
                ],
                content: ""
            )
            if let empty {
                _ = await RelayPool.publish(event: empty, to: relays, timeout: 12)
                latestList = empty
            }
            let target = latestList ?? latest
            let deleteTags = [
                ["e", target.id],
                ["a", "\(RecipeBookmarkRepository.listKind):\(keypair.pubkey):\(RecipeBookmarkRepository.defaultListDTag)"],
                ["k", String(RecipeBookmarkRepository.listKind)],
            ]
            guard let deletion = try? await Signer.sign(
                keypair: keypair,
                kind: Nip09.kindDeletion,
                tags: deleteTags,
                content: ""
            ) else {
                Issue.record("failed to sign kind-5 — list remains live at 30001:\(keypair.pubkey):\(RecipeBookmarkRepository.defaultListDTag)")
                return
            }
            let delAccepted = await RelayPool.publish(event: deletion, to: relays, timeout: 12)
            print("RecipeBookmark live: deleteAccepted=\(delAccepted)")
            #expect(
                !delAccepted.isEmpty,
                "no relay accepted the delete — list remains live"
            )

            var leftover: [NostrEvent] = []
            for attempt in 1...3 {
                leftover = await Self.fetchDefaultList(author: keypair.pubkey, relays: relays)
                leftover = leftover.filter { $0.kind == RecipeBookmarkRepository.listKind }
                if leftover.isEmpty { break }
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            print("RecipeBookmark live: leftoverAfterDelete=\(leftover.map(\.id))")
            #expect(
                leftover.isEmpty,
                "relays still serving kind-30001 \(RecipeBookmarkRepository.defaultListDTag) after delete. leftover=\(leftover.map(\.id))"
            )
        }

        // Seed a populated Saved list — the "existing collection" a cold
        // session must not overwrite.
        let seed = try await Signer.sign(
            keypair: keypair,
            kind: RecipeBookmarkRepository.listKind,
            tags: [
                ["d", RecipeBookmarkRepository.defaultListDTag],
                ["title", RecipeBookmarkRepository.defaultListTitle],
                ["a", coordA],
                ["a", coordB],
            ],
            content: ""
        )
        latestList = seed
        let seedAccepted = await RelayPool.publish(event: seed, to: relays, timeout: 12)
        print("RecipeBookmark live: seedAccepted=\(seedAccepted)")
        guard !seedAccepted.isEmpty else {
            Issue.record("no relay accepted the seed list; nothing to save onto")
            await cleanup()
            return
        }

        var beforeEvents = await Self.fetchDefaultList(author: keypair.pubkey, relays: relays)
        if beforeEvents.isEmpty {
            try await Task.sleep(for: .seconds(2))
            beforeEvents = await Self.fetchDefaultList(author: keypair.pubkey, relays: relays)
        }
        let beforeCoords = Self.newestCoordinates(beforeEvents)
        print("RecipeBookmark live: before=\(beforeCoords)")
        #expect(
            Set(beforeCoords) == Set([coordA, coordB]),
            "seed did not round-trip. before=\(beforeCoords) fetched=\(beforeEvents.map(\.id))"
        )

        // Replaceable events newest-wins; a same-second republish can lose
        // to the seed on id-tiebreak. Wait out the clock before mutating.
        try await Task.sleep(for: .seconds(1))

        // Cold session 1: empty memory + empty cache. First save must append.
        let saveProbe = LiveProbe(keypair: keypair, relays: relays)
        let saveRepo = RecipeBookmarkRepository(env: saveProbe.env)
        #expect(saveRepo.lists.isEmpty)
        #expect(saveRepo.bookmarkedCoordinates.isEmpty)

        let saved = await saveRepo.mutateList(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordC,
            desired: true,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle,
            keypair: keypair
        )
        #expect(saved == true, "cold first-save was rejected or failed")
        #expect(saveProbe.signed.count == 1)
        if let published = saveProbe.published.last {
            latestList = published
        }
        let afterSaveCoords = saveProbe.published.last.map { RecipeBookmarkRepository.parseCoordinates($0) } ?? []
        print("RecipeBookmark live: afterSave=\(afterSaveCoords)")
        #expect(afterSaveCoords == [coordA, coordB, coordC])
        #expect(afterSaveCoords != [coordC], "cold first-save replaced the existing collection")

        try await Task.sleep(for: .seconds(1))

        // Cold session 2: new repo, empty cache. Unsave must drop only C.
        let unsaveProbe = LiveProbe(keypair: keypair, relays: relays)
        let unsaveRepo = RecipeBookmarkRepository(env: unsaveProbe.env)
        let stillSaved = await unsaveRepo.mutateList(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coord: coordC,
            desired: false,
            seedTitleIfNew: RecipeBookmarkRepository.defaultListTitle,
            keypair: keypair
        )
        #expect(stillSaved == false)
        if let published = unsaveProbe.published.last {
            latestList = published
        }
        let afterUnsaveCoords = unsaveProbe.published.last.map { RecipeBookmarkRepository.parseCoordinates($0) } ?? []
        print("RecipeBookmark live: afterUnsave=\(afterUnsaveCoords)")
        #expect(Set(afterUnsaveCoords) == Set([coordA, coordB]))

        await cleanup()
    }

    private static func fetchDefaultList(author: String, relays: [String]) async -> [NostrEvent] {
        await RelayPool.query(
            relays: relays,
            filter: NostrFilter(
                kinds: [RecipeBookmarkRepository.listKind],
                authors: [author],
                dTags: [RecipeBookmarkRepository.defaultListDTag],
                limit: 8
            ),
            timeout: 12,
            waitForAllRelays: false
        )
    }

    private static func newestCoordinates(_ events: [NostrEvent]) -> [String] {
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else { return [] }
        return RecipeBookmarkRepository.parseCoordinates(newest)
    }

    private final class LiveProbe: @unchecked Sendable {
        let keypair: Keypair
        let relays: [String]
        var signed: [NostrEvent] = []
        var published: [NostrEvent] = []

        init(keypair: Keypair, relays: [String]) {
            self.keypair = keypair
            self.relays = relays
        }

        var env: RecipeBookmarkRepository.Environment {
            RecipeBookmarkRepository.Environment(
                confirmList: { author, dTag in
                    let result = await RelayPool.queryDetailed(
                        relays: self.relays,
                        filter: NostrFilter(
                            kinds: [RecipeBookmarkRepository.listKind],
                            authors: [author],
                            dTags: [dTag],
                            limit: 8
                        ),
                        timeout: RecipeBookmarkRepository.confirmTimeout,
                        waitForAllRelays: true
                    )
                    let newest = result.events
                        .filter { RecipeBookmarkRepository.hasDTag($0, dTag) && $0.pubkey == author }
                        .max(by: { $0.createdAt < $1.createdAt })
                    return RecipeBookmarkRepository.classifyRelayListCheck(
                        newest: newest,
                        eoseCount: result.relaysResponded
                    )
                },
                cachedList: { _, _ in nil },
                cachedLists: { _ in [] },
                persist: { _ in },
                sign: { kind, tags, content in
                    let event = try await Signer.sign(
                        keypair: self.keypair,
                        kind: kind,
                        tags: tags,
                        content: content
                    )
                    self.signed.append(event)
                    return event
                },
                publish: { event in
                    self.published.append(event)
                    _ = await RelayPool.publish(event: event, to: self.relays, timeout: 12)
                },
                readRelays: { self.relays },
                nowMs: { Int64(Date().timeIntervalSince1970 * 1000) }
            )
        }
    }
}
