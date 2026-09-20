import Foundation
import Testing
@testable import wisp

/// Guideline 1.2 in NIP-29 rooms (#135): a report reaches the room's relay
/// and hides the message, a block hides the author's messages, and the
/// admin's remove & ban is a well-formed kind 9001. Hermetic — publishing is
/// injected.
@Suite(.serialized)
@MainActor
struct GroupModerationTests {

    private func message(_ id: String, from pubkey: String) -> GroupMessage {
        GroupMessage(id: id, senderPubkey: pubkey, content: "hi", createdAt: 1)
    }

    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    /// Same isolation as `ReportedContentTests`: a throwaway account, its
    /// three UserDefaults keys removed, the filter snapshot reset.
    private func isolated(_ body: () async throws -> Void) async throws {
        let pk = "group-moderation-test-\(UUID().uuidString)"
        ReportedContent.shared.bind(activePubkey: pk)
        defer {
            UserDefaults.standard.removeObject(forKey: ReportedContent.eventIdsKey(pk))
            UserDefaults.standard.removeObject(forKey: ReportedContent.coordinatesKey(pk))
            UserDefaults.standard.removeObject(forKey: ReportedContent.pubkeysKey(pk))
            ReportedContent.shared.unbind()
            SafetyFilter.shared.install(.empty)
        }
        try await body()
    }

    // MARK: - What the room shows

    @Test func removingHidden_dropsReportedMessages_andBlockedAuthors_keepsTheRest() {
        let list = [message("m1", from: "alice"), message("m2", from: "BOB"), message("m3", from: "carol")]
        let kept = list.removingHidden(eventIds: ["m1"], pubkeys: ["bob"])
        #expect(kept.map(\.id) == ["m3"])
        #expect(list.removingHidden(eventIds: [], pubkeys: []) == list)
    }

    // MARK: - Report

    @Test func groupMessageTarget_carriesTheRoom_itsRelay_andItsAdmins() {
        let target = ReportTarget.groupMessage(
            id: "m1", senderPubkey: "alice", groupId: "bakers",
            relayUrl: "wss://pantry.zap.cooking", admins: ["adm1", "adm2"]
        )
        #expect(target.id == "e:m1")
        #expect(target.eventId == "m1")
        #expect(target.reportedPubkey == "alice")
        #expect(target.coordinate == nil)
        #expect(target.groupId == "bakers")
        #expect(target.groupRelayUrl == "wss://pantry.zap.cooking")
        #expect(target.groupAdmins == ["adm1", "adm2"])
    }

    /// The room relay is where the operator reads reports, so its accept
    /// alone is `.sent` (and hides the message) even when the default relays
    /// took nothing; the event carries the room's `h` tag and its admins.
    @Test func submit_groupReport_reachesTheRoomRelay_andItsAcceptAloneHides() async throws {
        try await isolated {
            let reporter = freshKeypair()
            let target = ReportTarget.groupMessage(
                id: "m1", senderPubkey: "alice", groupId: "bakers",
                relayUrl: "wss://pantry.zap.cooking", admins: ["adm1"]
            )
            var roomPublish: (event: NostrEvent, relay: String)?
            let outcome = await ReportSender.submit(
                target: target, category: .harassment, reason: "", keypair: reporter,
                relays: ["wss://a.example"],
                publish: { _, _ in [] },
                groupPublish: { event, relay in roomPublish = (event, relay); return true }
            )
            #expect(outcome == .sent)
            let sent = try #require(roomPublish)
            #expect(sent.relay == "wss://pantry.zap.cooking")
            #expect(sent.event.kind == Nip56.kindReport)
            #expect(sent.event.pubkey == reporter.pubkey)
            #expect(sent.event.tags.contains(["h", "bakers"]))
            #expect(sent.event.tags.contains(["p", "adm1"]))
            #expect(sent.event.tags.contains { $0.count >= 3 && $0[0] == "p" && $0[1] == "alice" })
            #expect(sent.event.tags.contains { $0.count >= 2 && $0[0] == "e" && $0[1] == "m1" })
            #expect(ReportedContent.shared.isHidden(eventId: "m1"))
            #expect(!ReportedContent.shared.isHidden(pubkey: "alice"), "a message report hides the message, not the author")
        }
    }

    @Test func submit_groupReport_bothRelaysRefuse_isFailed_andHidesNothing() async throws {
        try await isolated {
            let target = ReportTarget.groupMessage(
                id: "m2", senderPubkey: "alice", groupId: "bakers",
                relayUrl: "wss://pantry.zap.cooking", admins: []
            )
            let outcome = await ReportSender.submit(
                target: target, category: .spam, reason: "", keypair: freshKeypair(),
                relays: ["wss://a.example"],
                publish: { _, _ in [] },
                groupPublish: { _, _ in false }
            )
            #expect(outcome == .failed)
            #expect(!ReportedContent.shared.isHidden(eventId: "m2"))
        }
    }

    /// A target that isn't a room report never touches the room path.
    @Test func submit_plainReport_neverCallsTheRoomPublish() async throws {
        try await isolated {
            var roomCalls = 0
            let event = NostrEvent(id: "n1", pubkey: "alice", kind: 1, createdAt: 1, tags: [], content: "", sig: "")
            let outcome = await ReportSender.submit(
                target: .event(event), category: .spam, reason: "", keypair: freshKeypair(),
                relays: ["wss://a.example"],
                publish: { _, relays in relays },
                groupPublish: { _, _ in roomCalls += 1; return true }
            )
            #expect(outcome == .sent)
            #expect(roomCalls == 0)
        }
    }

    // MARK: - Remove & ban

    @Test func removeUser_isKind9001_withGroupThenTarget() throws {
        let admin = freshKeypair()
        let event = try Nip29.buildRemoveUser(
            privkey32: Hex.decode(admin.privkey)!, pubkey: admin.pubkey,
            groupId: "bakers", targetPubkey: "alice"
        )
        #expect(event.kind == Nip29.kindRemoveUser)
        #expect(event.kind == 9001)
        #expect(event.tags == [["h", "bakers"], ["p", "alice"]])
        #expect(event.content.isEmpty)
    }

    @Test func adminErrors_readAsSentences() {
        #expect(GroupRoomViewModel.describe(.rejected(message: "not an admin")).contains("not an admin"))
        #expect(!GroupRoomViewModel.describe(.rejected(message: "")).isEmpty)
        #expect(!GroupRoomViewModel.describe(.timeout).isEmpty)
        #expect(!GroupRoomViewModel.describe(.network).isEmpty)
        #expect(!GroupRoomViewModel.describe(.notAuthenticated).isEmpty)
    }
}
