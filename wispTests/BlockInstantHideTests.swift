import Foundation
import Testing
@testable import wisp

/// Guideline 1.2: "Blocking … should remove it from the user's feed
/// instantly." Every surface that holds already-loaded content must drop a
/// blocked author's posts the moment `MuteRepository.blockUser` returns —
/// no refresh, no relaunch. Block goes through the same `ContentHide`
/// broadcast as a report; each test here drives the real `blockUser` against
/// one surface. Hermetic: the throwaway account has no key, so the kind-10000
/// republish is a no-op, and queries are injected or never started.
@Suite(.serialized)
@MainActor
struct BlockInstantHideTests {

    private let me = String(repeating: "a", count: 64)
    private let alice = String(repeating: "b", count: 64)
    private let bob = String(repeating: "c", count: 64)

    // MARK: - Fixtures

    private func note(_ id: String, by author: String, kind: Int = 1,
                      tags: [[String]] = [["t", "foodstr"]], content: String = "yummy") -> NostrEvent {
        NostrEvent(id: id, pubkey: author, kind: kind, createdAt: 1_000,
                   tags: tags, content: content, sig: String(repeating: "0", count: 128))
    }

    private func repost(_ id: String, by reposter: String, of inner: NostrEvent) -> NostrEvent {
        let data = try! JSONSerialization.data(withJSONObject: [
            "id": inner.id, "pubkey": inner.pubkey, "kind": inner.kind,
            "created_at": inner.createdAt, "tags": inner.tags,
            "content": inner.content, "sig": inner.sig,
        ])
        return note(id, by: reposter, kind: 6,
                    tags: [["e", inner.id], ["p", inner.pubkey]],
                    content: String(data: data, encoding: .utf8)!)
    }

    /// A bound, keyless account, torn down with its UserDefaults keys.
    private func isolated(_ body: () async throws -> Void) async rethrows {
        let pk = "block-hide-test-\(UUID().uuidString)"
        MuteRepository.shared.bind(activePubkey: pk, privkey32: nil)
        ReportedContent.shared.bind(activePubkey: pk)
        defer {
            MuteRepository.shared.blockRecorder = nil
            MuteRepository.shared.unbind()
            ReportedContent.shared.unbind()
            for key in [MuteRepository.wordsKey(pk), MuteRepository.pubkeysKey(pk),
                        MuteRepository.threadsKey(pk), MuteRepository.updatedAtKey(pk),
                        ReportedContent.eventIdsKey(pk), ReportedContent.coordinatesKey(pk),
                        ReportedContent.pubkeysKey(pk)] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            SafetyFilter.shared.install(.empty)
        }
        try await body()
    }

    /// Observers hop to the MainActor in a `Task`; give them a few turns.
    /// "Instant" here means within the runloop turns that follow the block,
    /// with no refresh — not a timing budget.
    private func settle(until done: () -> Bool) async {
        for _ in 0..<100 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The block itself

    @Test func block_installsTheSnapshotSynchronously() async {
        await isolated {
            MuteRepository.shared.blockUser(bob, context: .profile)
            // No await between the block and the check: a live subscription
            // delivering bob's next event in this turn must already be dropped.
            #expect(SafetyFilter.shared.snapshot.blockedPubkeys.contains(bob))
            #expect(SafetyFilter.shared.shouldDrop(event: note("n", by: bob), context: .feed))
            #expect(SafetyFilter.shared.shouldDrop(event: note("t", by: bob), context: .thread(rootId: "r")))
        }
    }

    @Test func block_postsContentHidden_withTheBlockedPubkey() async {
        await isolated {
            var received: Set<String> = []
            let token = NotificationCenter.default.addObserver(
                forName: .contentHidden, object: nil, queue: nil
            ) { note in
                received = Set(note.userInfo?[ContentHideKey.pubkeys] as? [String] ?? [])
            }
            defer { NotificationCenter.default.removeObserver(token) }
            MuteRepository.shared.blockUser(bob.uppercased(), context: .profile)
            #expect(received == [bob], "posted synchronously, lowercased")
        }
    }

    /// The notify seam: a user-initiated block hands one record, with its
    /// context, to `blockRecorder`. Nothing is wired in production yet.
    @Test func block_handsARecordToTheRecorderSeam_once() async {
        await isolated {
            var records: [BlockRecord] = []
            MuteRepository.shared.blockRecorder = { records.append($0) }
            MuteRepository.shared.blockUser(bob, context: .event(id: "post-1", kind: 1))
            MuteRepository.shared.blockUser(bob, context: .profile)  // already blocked: no-op
            #expect(records.count == 1)
            #expect(records.first?.blocked == bob)
            #expect(records.first?.blocker == MuteRepository.shared.activePubkey)
            #expect(records.first?.context == .event(id: "post-1", kind: 1))
        }
    }

    // MARK: - Surfaces

    @Test func homeFeed_dropsBlockedAuthor_andTheirReposts() async {
        await isolated {
            let vm = FeedViewModel(keypair: Keypair(privkey: "", pubkey: me))
            let bobs = note("bob-1", by: bob)
            vm.events = [note("alice-1", by: alice), bobs, repost("rp", by: alice, of: bobs)]
            MuteRepository.shared.blockUser(bob, context: .profile)
            await settle { vm.events.count == 1 }
            #expect(vm.events.map(\.id) == ["alice-1"])
        }
    }

    @Test func onlyFood_dropsBlockedAuthor() async {
        await isolated {
            let vm = OnlyFoodFeedViewModel(
                pubkey: me,
                filter: OnlyFoodFilter(
                    nowSeconds: { 2_000 },
                    blockedPubkeys: OnlyFoodFilter.blockedPubkeys,
                    isUserBlocked: { _ in false },
                    containsMutedWord: { _ in false },
                    isThreadMuted: { _ in false },
                    isDeleted: { _ in false },
                    isWotFiltered: { _ in false }
                ),
                query: { _ in
                    OnlyFoodQueryResult(
                        events: [self.note("alice-1", by: self.alice), self.note("bob-1", by: self.bob)],
                        connected: true, anySent: true, eoseFired: true
                    )
                },
                seedCache: { [] },
                persist: { _ in }
            )
            await vm.startAndWait()
            #expect(Set(vm.notes.map(\.id)) == ["alice-1", "bob-1"])
            MuteRepository.shared.blockUser(bob, context: .profile)
            await settle { vm.notes.count == 1 }
            #expect(vm.notes.map(\.id) == ["alice-1"])
        }
    }

    @Test func thread_swapsBlockedRepliesForThePlaceholder() async {
        await isolated {
            let root = "root-\(UUID().uuidString)"
            let vm = ThreadViewModel(seedEventId: root, authorHint: nil,
                                     keypair: Keypair(privkey: "", pubkey: me))
            let reply = note("reply-\(UUID().uuidString)", by: bob,
                             tags: [["e", root, "", "root"], ["p", me]])
            NotificationCenter.default.post(name: .nostrEventPublished, object: nil,
                                            userInfo: ["event": reply])
            await settle { vm.replies.contains { $0.id == reply.id } }
            #expect(vm.replies.contains { $0.id == reply.id && !$0.isBlocked })

            MuteRepository.shared.blockUser(bob, context: .profile)
            await settle { vm.replies.contains { $0.id == reply.id && $0.isBlocked } }
            #expect(!vm.replies.contains { $0.id == reply.id && !$0.isBlocked },
                    "no row renders bob's content")
        }
    }

    @Test func search_dropsBlockedAuthorsNotesAndPeopleRow() async {
        await isolated {
            let vm = SearchViewModel(keypair: Keypair(privkey: "", pubkey: me))
            vm.start()
            defer { vm.stop() }
            vm.notes = [note("alice-1", by: alice), note("bob-1", by: bob)]
            vm.people = [ProfileData(pubkey: alice), ProfileData(pubkey: bob)]
            MuteRepository.shared.blockUser(bob, context: .profile)
            await settle { vm.notes.count == 1 && vm.people.count == 1 }
            #expect(vm.notes.map(\.id) == ["alice-1"])
            #expect(vm.people.map(\.pubkey) == [alice])
        }
    }

    @Test func hashtag_dropsBlockedAuthor() async {
        await isolated {
            let vm = HashtagFeedViewModel(keypair: Keypair(privkey: "", pubkey: me),
                                          source: .single("foodstr"))
            // Seeded before `start()`: a non-empty list skips the load.
            vm.events = [note("alice-1", by: alice), note("bob-1", by: bob)]
            await vm.start()
            MuteRepository.shared.blockUser(bob, context: .profile)
            await settle { vm.events.count == 1 }
            #expect(vm.events.map(\.id) == ["alice-1"])
        }
    }

    @Test func trending_dropsBlockedAuthorsNotesAndUserRow() async {
        await isolated {
            let vm = TrendingFeedViewModel(keypair: Keypair(privkey: "", pubkey: me))
            vm.events = [note("alice-1", by: alice), note("bob-1", by: bob)]
            vm.users = [ProfileData(pubkey: alice), ProfileData(pubkey: bob)]
            await vm.start()
            MuteRepository.shared.blockUser(bob, context: .profile)
            await settle { vm.events.count == 1 && vm.users.count == 1 }
            #expect(vm.events.map(\.id) == ["alice-1"])
            #expect(vm.users.map(\.pubkey) == [alice])
        }
    }

    /// Blocking from bob's own profile clears his posts; the view stays (with
    /// Unblock showing) rather than dismissing as a profile report does.
    @Test func profile_dropsBlockedAuthorsPosts_withoutStart() async {
        await isolated {
            let vm = ProfileViewModel(pubkey: bob, activeUserPubkey: me)
            let bobs = note("bob-1", by: bob)
            vm.rootNotes = [bobs]
            vm.sortedNotes = [bobs]
            vm.replies = [note("bob-2", by: bob)]
            vm.galleryPosts = [bobs]
            MuteRepository.shared.blockUser(bob, context: .profile)
            await settle { vm.rootNotes.isEmpty }
            #expect(vm.rootNotes.isEmpty)
            #expect(vm.sortedNotes.isEmpty)
            #expect(vm.replies.isEmpty)
            #expect(vm.galleryPosts.isEmpty)
            #expect(!ReportedContent.shared.isHidden(pubkey: bob),
                    "a block is not a report: ProfileView's dismiss-on-report does not fire")
        }
    }

    @Test func recipes_dropBlockedAuthorsRecipes() async {
        await isolated {
            let repo = RecipeRepository.shared
            defer { repo.ingest([], reset: true) }
            @MainActor func recipe(_ id: String, by author: String) -> NostrEvent {
                note(id, by: author, kind: RecipeParser.recipeKind,
                     tags: [["d", id], ["t", "zapcooking"]],
                     content: "## Ingredients\n\n- flour\n\n## Directions\n\n1. Bake.")
            }
            repo.ingest([recipe("alice-r", by: alice), recipe("bob-r", by: bob)], reset: true)
            #expect(Set(repo.recipes.map(\.id)) == ["alice-r", "bob-r"])
            MuteRepository.shared.blockUser(bob, context: .profile)
            #expect(repo.recipes.map(\.id) == ["alice-r"], "synchronous: no observer hop")
        }
    }

    @Test func notifications_dropBlockedAuthorsRows() async {
        await isolated {
            let repo = NotificationRepository.shared
            let myNote = "mynote-\(UUID().uuidString)"
            repo.bind(activePubkey: "notif-\(UUID().uuidString)")
            repo.selfEventIds = [myNote]
            let reply = note("reply-\(UUID().uuidString)", by: bob,
                             tags: [["e", myNote, "", "reply"], ["p", me]], content: "hi")
            #expect(repo.ingest(reply, relayUrl: "", persist: false))
            #expect(repo.flatItems.contains { $0.actorPubkey == bob })
            MuteRepository.shared.blockUser(bob, context: .profile)
            #expect(!repo.flatItems.contains { $0.actorPubkey == bob })
        }
    }

    @Test func groupRoom_dropsBlockedAuthorsMessages() async {
        await isolated {
            let room = GroupRoom(
                groupId: "bakers", relayUrl: "wss://pantry.zap.cooking",
                messages: [
                    GroupMessage(id: "m1", senderPubkey: alice, content: "hi", createdAt: 1),
                    GroupMessage(id: "m2", senderPubkey: bob, content: "hi", createdAt: 2),
                ]
            )
            MuteRepository.shared.blockUser(bob, context: .groupRoom(
                groupId: "bakers", relayUrl: "wss://pantry.zap.cooking"
            ))
            #expect(room.visibleMessages.map(\.id) == ["m1"])
        }
    }

    // MARK: - Report still takes the same path

    @Test func profileReport_stillReachesTheThreadObserver() async {
        await isolated {
            var blocked: [String] = []
            let token = NotificationCenter.default.addObserver(
                forName: .userBlocked, object: nil, queue: nil
            ) { note in
                if let pk = note.object as? String { blocked.append(pk) }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            ReportedContent.shared.hide(.profile(pubkey: bob))
            #expect(blocked == [bob])
            ReportedContent.shared.hide(.event(note("alice-1", by: alice)))
            #expect(blocked == [bob], "a post report hides the post, not the author")
        }
    }
}
