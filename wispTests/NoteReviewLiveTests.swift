import Foundation
import Testing
@testable import wisp

/// Live gates for Cheffy Note Review — production `zap.cooking` and
/// production relays. Opt-in: `touch wispTests/.note_review_live_enable` or
/// `NOTE_REVIEW_LIVE=1`. The member-gated drafts also need the Cook+ test
/// key in `wispTests/.zc_member_nsec` (or `ZC_MEMBER_NSEC`); never printed,
/// never written anywhere else.
///
/// The publish gate follows §7.13: an EPHEMERAL key publishes the parent
/// note and the reply (the member key only signs the NIP-98 draft
/// request, so its timeline stays clean), both are verified on the relays,
/// then deleted with the key held until each id is confirmed gone.
@Suite(.tags(.liveNetwork))
@MainActor
struct NoteReviewLiveTests {

    nonisolated private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".note_review_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["NOTE_REVIEW_LIVE"] == "1" || env["TEST_RUNNER_NOTE_REVIEW_LIVE"] == "1"
    }

    nonisolated private static var memberNsecRaw: String? {
        let env = ProcessInfo.processInfo.environment
        if let nsec = env["ZC_MEMBER_NSEC"] ?? env["TEST_RUNNER_ZC_MEMBER_NSEC"], !nsec.isEmpty {
            return nsec
        }
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".zc_member_nsec")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static var memberNsecSet: Bool { memberNsecRaw != nil }

    private static func memberKeypair() throws -> Keypair {
        let nsec = try #require(Self.memberNsecRaw)
        return try #require(NostrKey.parseNsec(nsec), "ZC_MEMBER_NSEC / .zc_member_nsec is not a valid nsec")
    }

    private static func ephemeralKeypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    /// A stable, publicly hosted food photo with an image extension (passes
    /// `ImageUrls.isImageUrl` and the server's identical check).
    private static let foodPhoto = "https://upload.wikimedia.org/wikipedia/commons/6/6d/Good_Food_Display_-_NCI_Visuals_Online.jpg"

    private static func parentStub(content: String) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "ab", count: 32),
            pubkey: String(repeating: "cd", count: 32),
            kind: 1, createdAt: NostrClock.now(), tags: [], content: content, sig: String(repeating: "0", count: 128)
        )
    }

    private static func timed(_ label: String, _ body: () async -> NoteReviewResult) async -> NoteReviewResult {
        let start = Date()
        let result = await body()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("NoteReview live: \(label) latency=\(ms)ms")
        return result
    }

    // MARK: Gate 4 — both modes draft with the member key

    @Test(
        .tags(.liveNetwork),
        .enabled(if: NoteReviewLiveTests.isDeliberatelyEnabled, "Opt in: touch wispTests/.note_review_live_enable"),
        .enabled(if: NoteReviewLiveTests.memberNsecSet, "Needs the Cook+ member key (wispTests/.zc_member_nsec)")
    )
    func member_commentAndRecipeModesBothDraft() async throws {
        let keypair = try Self.memberKeypair()
        let signer = LocalNip98Signer(keypair: keypair)
        let service = NoteReviewService()
        let parent = Self.parentStub(content: "Sunday spread. \(Self.foodPhoto)")

        let comment = await Self.timed("comment") {
            await service.draft(
                NoteReviewService.request(imageUrl: Self.foodPhoto, mode: .comment, noteText: parent.content, noteId: parent.id),
                signer: signer
            )
        }
        guard case .success(let commentDraft) = comment else {
            Issue.record("comment draft failed: \(comment)")
            return
        }
        print("NoteReview live: comment chars=\(commentDraft.count)")
        #expect(!commentDraft.isEmpty)

        let recipe = await Self.timed("recipe") {
            await service.draft(
                NoteReviewService.request(imageUrl: Self.foodPhoto, mode: .recipe, noteText: parent.content, noteId: parent.id),
                signer: signer
            )
        }
        guard case .success(let recipeDraft) = recipe else {
            Issue.record("recipe draft failed: \(recipe)")
            return
        }
        print("NoteReview live: recipe chars=\(recipeDraft.count)")
        #expect(recipeDraft.count > commentDraft.count, "a recipe draft is the longer structured one")
        #expect(NoteReview.phaseForResult(recipe).phase == .draft)
    }

    // MARK: Gate 6 — a verified non-member sees the message-only gate

    @Test(
        .tags(.liveNetwork),
        .enabled(if: NoteReviewLiveTests.isDeliberatelyEnabled, "Opt in: touch wispTests/.note_review_live_enable")
    )
    func nonMember_isTypedNotMember_andLandsTheMessageOnlyGate() async throws {
        let keypair = try Self.ephemeralKeypair()
        let service = NoteReviewService()
        let result = await Self.timed("non-member") {
            await service.draft(
                NoteReviewService.request(imageUrl: Self.foodPhoto, mode: .comment, noteText: nil, noteId: nil),
                signer: LocalNip98Signer(keypair: keypair)
            )
        }
        print("NoteReview live: non-member result=\(result)")
        #expect(result == .notMember, "the endpoint's 403 carries code NOT_MEMBER")
        let vm = NoteReviewViewModel()
        vm.applyResult(result)
        #expect(vm.phase == .membersOnly)
    }

    // MARK: Gate 5 — §7.13 publish, verify, delete with the key held

    @Test(
        .tags(.liveNetwork),
        .enabled(if: NoteReviewLiveTests.isDeliberatelyEnabled, "Opt in: touch wispTests/.note_review_live_enable"),
        .enabled(if: NoteReviewLiveTests.memberNsecSet, "Needs the Cook+ member key (wispTests/.zc_member_nsec)")
    )
    func publishDraftedReply_verify_delete_keyHeldUntilGone() async throws {
        let member = try Self.memberKeypair()
        let author = try Self.ephemeralKeypair()
        let relays = RelayDefaults.defaults
        let stamp = Int(Date().timeIntervalSince1970)

        // Phase 1 — the ephemeral key publishes a parent note carrying the photo.
        var parentTags: [[String]] = []
        if let clientTag = NostrEvent.clientTagIfEnabled() { parentTags.append(clientTag) }
        let parent = try await Signer.sign(
            keypair: author, kind: 1, tags: parentTags,
            content: "iOS Note Review live gate \(stamp). Ephemeral key, safe to ignore. \(Self.foodPhoto)"
        )
        #expect(NoteReviewTrigger.isEligible(noteContent: parent.content, flagEnabled: true))
        let parentAccepted = await RelayPool.publish(event: parent, to: relays, timeout: 12)
        print("NoteReview live: parent id=\(parent.id) accepted=\(parentAccepted)")
        #expect(!parentAccepted.isEmpty, "no default relay accepted the parent")

        var published: [NostrEvent] = [parent]
        var seenOn = Set(parentAccepted)

        func cleanup() async {
            for event in published.reversed() {
                var delTags = Nip09.deletionTagsForEvent(id: event.id, kind: 1)
                if let clientTag = NostrEvent.clientTagIfEnabled() { delTags.append(clientTag) }
                guard let deletion = try? await Signer.sign(
                    keypair: author, kind: Nip09.kindDeletion, tags: delTags, content: "live gate cleanup"
                ) else {
                    Issue.record("could not sign the delete — \(event.id) remains live")
                    continue
                }
                let targets = Array(seenOn.union(relays))
                let delAccepted = await RelayPool.publish(event: deletion, to: targets, timeout: 12)
                print("NoteReview live: delete \(event.id) accepted=\(delAccepted)")
                #expect(!delAccepted.isEmpty, "no relay accepted the delete — \(event.id) remains live")
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
                #expect(leftover.isEmpty, "\(event.id) still served after delete on \(targets)")
            }
        }

        // Phase 2 — the member key drafts a comment against that note
        // (NIP-98 only; the member publishes nothing).
        let vm = NoteReviewViewModel()
        vm.open(parent: parent, imageUrls: ImageUrls.extractImageUrls(parent.content))
        #expect(vm.imageUrl == Self.foodPhoto)
        let start = Date()
        vm.choose(.comment, keypair: member, prefs: nil)
        for _ in 0..<900 {
            if vm.phase != .signing && vm.phase != .loading { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("NoteReview live: draft phase=\(vm.phase) latency=\(Int(Date().timeIntervalSince(start) * 1000))ms")
        guard vm.phase == .draft else {
            Issue.record("draft did not land: phase=\(vm.phase) message=\(vm.message)")
            await cleanup()
            return
        }
        vm.updateDraft("\(vm.draft)\n\n(iOS Note Review live gate \(stamp), ephemeral key)")

        // Phase 3 — the ephemeral key publishes the drafted reply through the
        // real publisher, pinned to the default relay set.
        var publisher = RelayNoteReviewReplyPublisher()
        publisher.relayResolver = { _, _ in relays }
        publisher.persist = { _ in }
        vm.post(publisher: publisher, keypair: author)
        for _ in 0..<300 {
            if vm.phase != .posting { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("NoteReview live: post phase=\(vm.phase)")
        var reply: NostrEvent? = vm.postedEvent
        if vm.phase == .postTimeout, let signed = vm.timeoutSignedEvent {
            // The timeout path holds the signed event; retry re-broadcasts it.
            published.append(signed)
            vm.retryPost(publisher: publisher)
            for _ in 0..<300 {
                if vm.phase != .posting { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            reply = vm.postedEvent ?? signed
        } else if let posted = vm.postedEvent {
            published.append(posted)
        }
        guard let reply else {
            Issue.record("no reply event: phase=\(vm.phase) postError=\(vm.postError)")
            await cleanup()
            return
        }
        #expect(vm.phase == .posted)
        #expect(reply.tags.contains { $0.count >= 4 && $0[0] == "e" && $0[1] == parent.id && $0[3] == "root" })
        #expect(reply.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == author.pubkey })
        #expect(!reply.content.contains(NoteReview.disclosureFooter), "comment mode defaults the footer off")

        // Phase 4 — verify the reply is served, then clean up both.
        let echoed = await RelayPool.query(
            relays: relays, filter: NostrFilter(kinds: [1], ids: [reply.id]), timeout: 15, waitForAllRelays: true
        )
        let found = echoed.first { $0.id == reply.id }
        #expect(found != nil, "defaults did not echo the reply \(reply.id)")
        if found != nil { for r in relays { seenOn.insert(r) } }
        print("NoteReview live: reply id=\(reply.id) verified=\(found != nil)")
        await cleanup()
    }
}
