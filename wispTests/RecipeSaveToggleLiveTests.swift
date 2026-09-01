import Foundation
import Testing
@testable import wisp

/// Concern 3.1b live gate — save a throwaway recipe coordinate onto the
/// default Saved list, unsave it, then NIP-09-delete the list (kind-5
/// `e`+`a`+`k`) and confirm it is gone.
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.save_toggle_live_enable` or
/// `SAVE_TOGGLE_LIVE=1`). Run with `-parallel-testing-enabled NO`.
///
/// §7.13: ephemeral keypair — never a real nsec, never printed, never
/// written to disk — held until the matching kind-5 is accepted and a
/// re-query of `30001:<pubkey>:nostrcooking-bookmarks` returns nothing.
/// Target `RelayDefaults.defaults`. Do not mint a HiddenRecipes prefix.
@Suite(.tags(.liveNetwork))
struct RecipeSaveToggleLiveTests {

    private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".save_toggle_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["SAVE_TOGGLE_LIVE"] == "1"
            || env["TEST_RUNNER_SAVE_TOGGLE_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: RecipeSaveToggleLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.save_toggle_live_enable (see ZAPCOOKING_IOS_BUILD.md)"
        )
    )
    @MainActor
    func save_listCarriesIt_unsave_gone_deleteList_confirmedGone() async throws {
        let started = Date()
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))

        let stamp = Int(Date().timeIntervalSince1970)
        let dTag = "ios-3.1b-save-\(stamp)"
        let recipeEvent = NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: keypair.pubkey,
            kind: RecipeParser.recipeKind,
            createdAt: stamp,
            tags: [["d", dTag], ["t", "zapcooking"], ["title", "iOS 3.1b save \(stamp)"]],
            content: "## Ingredients\n\n- ephemeral\n\n## Directions\n\n1. Save.\n2. Unsave.\n3. Delete.",
            sig: String(repeating: "0", count: 128)
        )
        let coord = try #require(RecipeBookmarkRepository.coordinateForEvent(recipeEvent))
        let relays = RelayDefaults.defaults
        var latestList: NostrEvent?
        var deleteConfirmedGone = false

        func deleteListAndConfirmGone() async {
            guard let latest = latestList, !deleteConfirmedGone else { return }
            let deleteTags = [
                ["e", latest.id],
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
            print("SaveToggle live: deleteAccepted=\(delAccepted)")
            #expect(!delAccepted.isEmpty, "no relay accepted the delete — list remains live")

            var leftover: [NostrEvent] = []
            for attempt in 1...4 {
                leftover = await Self.fetchDefaultList(author: keypair.pubkey, relays: relays)
                    .filter { $0.kind == RecipeBookmarkRepository.listKind }
                if leftover.isEmpty { break }
                if attempt < 4 { try? await Task.sleep(for: .seconds(2)) }
            }
            print("SaveToggle live: leftoverAfterDelete=\(leftover.map(\.id))")
            #expect(
                leftover.isEmpty,
                "defaults still serving kind-30001 \(RecipeBookmarkRepository.defaultListDTag) after delete. leftover=\(leftover.map(\.id))"
            )
            deleteConfirmedGone = leftover.isEmpty
        }

        do {
            try await Task.sleep(for: .seconds(1))

            let saveStart = Date()
            let saveProbe = LiveProbe(keypair: keypair, relays: relays)
            let saveRepo = RecipeBookmarkRepository(env: saveProbe.env)
            #expect(saveRepo.bookmarkedCoordinates.isEmpty)
            let saved = await saveRepo.toggle(event: recipeEvent, keypair: keypair)
            #expect(saved == true, "cold first-save was rejected or failed")
            #expect(saveProbe.signed.count == 1)
            if let published = saveProbe.published.last {
                latestList = published
            }
            let afterSave = saveProbe.published.last.map { RecipeBookmarkRepository.parseCoordinates($0) } ?? []
            print("SaveToggle live: afterSave=\(afterSave) in \(Date().timeIntervalSince(saveStart))s")
            #expect(afterSave.contains(coord), "list does not carry the saved coordinate")

            try await Task.sleep(for: .seconds(1))

            let unsaveStart = Date()
            let unsaveProbe = LiveProbe(keypair: keypair, relays: relays)
            let unsaveRepo = RecipeBookmarkRepository(env: unsaveProbe.env)
            let stillSaved = await unsaveRepo.toggle(event: recipeEvent, keypair: keypair)
            #expect(stillSaved == false)
            if let published = unsaveProbe.published.last {
                latestList = published
            }
            let afterUnsave = unsaveProbe.published.last.map { RecipeBookmarkRepository.parseCoordinates($0) } ?? []
            print("SaveToggle live: afterUnsave=\(afterUnsave) in \(Date().timeIntervalSince(unsaveStart))s")
            #expect(!afterUnsave.contains(coord), "list still carries the coordinate after unsave")

            let deleteStart = Date()
            await deleteListAndConfirmGone()
            print("SaveToggle live: delete-and-gone in \(Date().timeIntervalSince(deleteStart))s")
        } catch {
            await deleteListAndConfirmGone()
            throw error
        }

        await deleteListAndConfirmGone()
        print("SaveToggle live: total \(Date().timeIntervalSince(started))s; cleanup confirmed=\(deleteConfirmedGone)")
        #expect(deleteConfirmedGone, "key released only after the list coordinate is confirmed gone")
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
