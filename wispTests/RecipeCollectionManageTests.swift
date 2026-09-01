import Foundation
import Testing
@testable import wisp

/// Concern 3.2 — named-collection rename / edit-description / set-cover /
/// delete through the 3.1 kind-30001 path, with the cold-session guard
/// intact. The load-bearing cases run against a **populated remote list**
/// (the 3.1 guard test pattern): a metadata edit on a cold cache must carry
/// the relay version forward, never clobber it, and an unconfirmed relay
/// check signs nothing.
@MainActor
struct RecipeCollectionManageTests {

    private let author = String(repeating: "bb", count: 32)
    private var coordA: String { "30023:\(author):tuscan-peposo" }
    private var coordB: String { "30023:\(author):shakshuka" }
    private var coordC: String { "30023:\(author):meatloaf" }

    private func listEvent(
        tags: [[String]],
        content: String = "",
        createdAt: Int = 1_700_000_000,
        id: String = String(repeating: "aa", count: 32)
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: author,
            kind: RecipeBookmarkRepository.listKind,
            createdAt: createdAt,
            tags: tags,
            content: content,
            sig: String(repeating: "0", count: 128)
        )
    }

    /// A populated named collection as another client published it —
    /// summary, image, cover, client tag, recipe `t`, two members.
    private func populatedRemote() -> NostrEvent {
        listEvent(
            tags: [
                ["d", "weeknight"],
                ["title", "Weeknight"],
                ["summary", "fast dinners"],
                ["image", "https://example.com/img.jpg"],
                ["cover", coordA],
                ["client", "Zap Cooking Web"],
                ["t", "zapcooking"],
                ["a", coordA],
                ["a", coordB],
            ],
            content: "web content"
        )
    }

    // MARK: - Rename

    @Test func rename_coldSession_populatedRemote_changesOnlyTheTitleTag() async {
        let remote = populatedRemote()
        let probe = Probe()
        probe.confirm = .found(remote)
        #expect(probe.cached.isEmpty, "cold session: on-device cache must be empty")
        let repo = RecipeBookmarkRepository(env: probe.env)
        #expect(repo.lists.isEmpty)
        let kp = try! makeKeypair()

        let ok = await repo.renameList(dTag: "weeknight", newTitle: "Weeknight Dinners", keypair: kp)

        #expect(ok == true)
        #expect(probe.signed.count == 1)
        #expect(probe.published.count == 1)
        #expect(probe.signed[0].tags == [
            ["d", "weeknight"],
            ["title", "Weeknight Dinners"],
            ["summary", "fast dinners"],
            ["image", "https://example.com/img.jpg"],
            ["cover", coordA],
            ["t", "zapcooking"],
            ["a", coordA],
            ["a", coordB],
        ])
        #expect(probe.signed[0].content == "web content")
        #expect(repo.lists.first(where: { $0.dTag == "weeknight" })?.title == "Weeknight Dinners")
        #expect(repo.lastWriteError == nil)
    }

    @Test func rename_defaultList_refused_signsNothing() async {
        let probe = Probe()
        probe.confirm = .found(listEvent(tags: [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", "Saved"],
            ["a", coordA],
        ]))
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.renameList(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            newTitle: "My Stuff",
            keypair: try! makeKeypair()
        )
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
        #expect(probe.published.isEmpty)
    }

    @Test func rename_blankTitle_refused_signsNothing() async {
        let probe = Probe()
        probe.confirm = .found(populatedRemote())
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.renameList(dTag: "weeknight", newTitle: "   ", keypair: try! makeKeypair())
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
    }

    @Test func rename_unconfirmedCold_signsNothing_surfacesGuardMessage() async {
        let probe = Probe()
        probe.confirm = .unconfirmed
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.renameList(dTag: "weeknight", newTitle: "Weeknight Dinners", keypair: try! makeKeypair())
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
        #expect(probe.published.isEmpty)
        #expect(repo.lastWriteError == RecipeBookmarkRepository.writeUnconfirmedMessage)
    }

    /// Metadata edits never create: a confirmed-absent list is nothing to
    /// rename, not a fresh replaceable to publish.
    @Test func rename_confirmedAbsent_neverCreates() async {
        let probe = Probe()
        probe.confirm = .confirmedAbsent
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.renameList(dTag: "weeknight", newTitle: "Weeknight Dinners", keypair: try! makeKeypair())
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
        #expect(repo.lastWriteError == nil, "absence is a quiet no-op, not the guard error")
    }

    // MARK: - Edit description

    @Test func setDescription_coldSession_populatedRemote_replacesOnlySummary() async {
        let probe = Probe()
        probe.confirm = .found(populatedRemote())
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.setListDescription(dTag: "weeknight", summary: "New desc", keypair: try! makeKeypair())
        #expect(ok == true)
        #expect(probe.signed.count == 1)
        #expect(probe.signed[0].tags == [
            ["d", "weeknight"],
            ["title", "Weeknight"],
            ["image", "https://example.com/img.jpg"],
            ["cover", coordA],
            ["t", "zapcooking"],
            ["summary", "New desc"],
            ["a", coordA],
            ["a", coordB],
        ])
        #expect(probe.signed[0].content == "web content")
    }

    @Test func setDescription_nil_clearsTheSummaryTag() async {
        let probe = Probe()
        probe.confirm = .found(populatedRemote())
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.setListDescription(dTag: "weeknight", summary: nil, keypair: try! makeKeypair())
        #expect(ok == true)
        #expect(probe.signed[0].tags.contains(where: { $0.first == "summary" }) == false)
        #expect(probe.signed[0].tags.contains(["cover", coordA]), "clearing summary must not touch cover")
    }

    /// The web only locks the default list's title — description is editable.
    @Test func setDescription_defaultList_allowed() async {
        let probe = Probe()
        probe.confirm = .found(listEvent(tags: [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", "Saved"],
            ["a", coordA],
        ]))
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.setListDescription(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            summary: "keepers",
            keypair: try! makeKeypair()
        )
        #expect(ok == true)
        #expect(probe.signed[0].tags.contains(["summary", "keepers"]))
        #expect(!probe.signed[0].tags.contains(where: { $0.first == "t" }), "the default list never gains a t tag")
    }

    // MARK: - Set cover

    @Test func setCover_memberCoordinate_replacesTheCoverTag() async {
        let probe = Probe()
        probe.confirm = .found(populatedRemote())
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.setListCover(dTag: "weeknight", coverCoord: coordB, keypair: try! makeKeypair())
        #expect(ok == true)
        #expect(probe.signed.count == 1)
        #expect(probe.signed[0].tags == [
            ["d", "weeknight"],
            ["title", "Weeknight"],
            ["summary", "fast dinners"],
            ["image", "https://example.com/img.jpg"],
            ["t", "zapcooking"],
            ["cover", coordB],
            ["a", coordA],
            ["a", coordB],
        ])
    }

    /// Web guard: a cover can only be a recipe already in the collection.
    @Test func setCover_nonMemberCoordinate_refused_signsNothing() async {
        let probe = Probe()
        probe.confirm = .found(populatedRemote())
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.setListCover(dTag: "weeknight", coverCoord: coordC, keypair: try! makeKeypair())
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
        #expect(probe.published.isEmpty)
    }

    @Test func setCover_nil_clearsTheCoverTag() async {
        let probe = Probe()
        probe.confirm = .found(populatedRemote())
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.setListCover(dTag: "weeknight", coverCoord: nil, keypair: try! makeKeypair())
        #expect(ok == true)
        #expect(probe.signed[0].tags.contains(where: { $0.first == "cover" }) == false)
        #expect(probe.signed[0].tags.contains(["a", coordA]) && probe.signed[0].tags.contains(["a", coordB]))
    }

    @Test func setCover_defaultList_allowed() async {
        let probe = Probe()
        probe.confirm = .found(listEvent(tags: [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", "Saved"],
            ["a", coordA],
        ]))
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.setListCover(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            coverCoord: coordA,
            keypair: try! makeKeypair()
        )
        #expect(ok == true)
        #expect(probe.signed[0].tags.contains(["cover", coordA]))
    }

    @Test func setCover_unconfirmedCold_signsNothing() async {
        let probe = Probe()
        probe.confirm = .unconfirmed
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.setListCover(dTag: "weeknight", coverCoord: coordA, keypair: try! makeKeypair())
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
        #expect(repo.lastWriteError == RecipeBookmarkRepository.writeUnconfirmedMessage)
    }

    // MARK: - Delete

    @Test func deleteList_publishesKind5Tombstone_andRemovesLocally() async {
        let remote = populatedRemote()
        let probe = Probe()
        probe.confirm = .found(remote)
        let repo = RecipeBookmarkRepository(env: probe.env)
        let kp = try! makeKeypair()

        let ok = await repo.deleteList(dTag: "weeknight", keypair: kp)

        #expect(ok == true)
        #expect(probe.signed.count == 1)
        #expect(probe.published.count == 1)
        let deletion = probe.signed[0]
        #expect(deletion.kind == Nip09.kindDeletion)
        #expect(deletion.content == "")
        // Android's shape (`e` + `a`) plus a `k` tag for consistency with
        // `RecipeDeletion` — deliberate iOS divergence, noted in the PR.
        #expect(deletion.tags == [
            ["e", remote.id],
            ["a", "\(RecipeBookmarkRepository.listKind):\(kp.pubkey):weeknight"],
            ["k", String(RecipeBookmarkRepository.listKind)],
        ])
        // Optimistic local removal — the Saved grid updates immediately,
        // and the on-device cache is evicted so a paint cannot resurrect it.
        #expect(!repo.lists.contains(where: { $0.dTag == "weeknight" }))
        #expect(probe.removedFromCache.contains(where: { $0.1 == "weeknight" }))
    }

    /// A laggard relay (or the cache) re-serving the deleted version must
    /// not resurrect the collection; a strictly newer republish revives it.
    @Test func deleteList_laggardCopyDoesNotResurrect_newerRepublishRevives() async {
        let remote = populatedRemote()
        let probe = Probe()
        probe.confirm = .found(remote)
        let repo = RecipeBookmarkRepository(env: probe.env)
        _ = await repo.deleteList(dTag: "weeknight", keypair: try! makeKeypair())
        #expect(!repo.lists.contains(where: { $0.dTag == "weeknight" }))

        repo.applyEvent(remote)
        #expect(!repo.lists.contains(where: { $0.dTag == "weeknight" }), "deleted version must stay gone")

        let revived = listEvent(
            tags: [["d", "weeknight"], ["title", "Weeknight"], ["t", "zapcooking"], ["a", coordC]],
            createdAt: 1_700_000_002,
            id: String(repeating: "dd", count: 32)
        )
        repo.applyEvent(revived)
        #expect(repo.lists.contains(where: { $0.dTag == "weeknight" }), "a strictly newer republish revives the address")
    }

    @Test func deleteList_defaultList_refused_signsNothing() async {
        let probe = Probe()
        probe.confirm = .found(listEvent(tags: [
            ["d", RecipeBookmarkRepository.defaultListDTag],
            ["title", "Saved"],
            ["a", coordA],
        ]))
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.deleteList(
            dTag: RecipeBookmarkRepository.defaultListDTag,
            keypair: try! makeKeypair()
        )
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
        #expect(probe.published.isEmpty)
    }

    @Test func deleteList_unconfirmedCold_signsNothing() async {
        let probe = Probe()
        probe.confirm = .unconfirmed
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.deleteList(dTag: "weeknight", keypair: try! makeKeypair())
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
        #expect(repo.lastWriteError == RecipeBookmarkRepository.writeUnconfirmedMessage)
    }

    @Test func deleteList_confirmedAbsent_nothingToDelete_signsNothing() async {
        let probe = Probe()
        probe.confirm = .confirmedAbsent
        let repo = RecipeBookmarkRepository(env: probe.env)
        let ok = await repo.deleteList(dTag: "weeknight", keypair: try! makeKeypair())
        #expect(ok == false)
        #expect(probe.signed.isEmpty)
        #expect(repo.lastWriteError == nil)
    }

    // MARK: - Helpers

    private func makeKeypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private final class Probe: @unchecked Sendable {
        var confirm: RecipeBookmarkRepository.RelayListCheck = .unconfirmed
        var cached: [NostrEvent] = []
        var signed: [NostrEvent] = []
        var published: [NostrEvent] = []
        var removedFromCache: [(String, String)] = []
        var env: RecipeBookmarkRepository.Environment {
            RecipeBookmarkRepository.Environment(
                confirmList: { _, _ in self.confirm },
                cachedList: { _, _ in self.cached.first },
                cachedLists: { _ in self.cached },
                persist: { _ in },
                sign: { kind, tags, content in
                    let event = NostrEvent(
                        id: String(repeating: "11", count: 32),
                        pubkey: String(repeating: "bb", count: 32),
                        kind: kind,
                        createdAt: 1_700_000_001,
                        tags: tags,
                        content: content,
                        sig: String(repeating: "0", count: 128)
                    )
                    self.signed.append(event)
                    return event
                },
                publish: { event in self.published.append(event) },
                readRelays: { [] },
                nowMs: { 0 },
                removeCached: { author, dTag in self.removedFromCache.append((author, dTag)) }
            )
        }
    }
}
