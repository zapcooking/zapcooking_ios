import Foundation
import Testing
@testable import wisp

/// Byte-level port of Android `Nip56.kt` — category vocabulary, tag shape,
/// content encoding, and parse. Do not invent a second report-type list.
@MainActor
struct Nip56Tests {

    @Test func categories_matchAndroidVocabulary() {
        let expected: [(Nip56.ReportCategory, String, String)] = [
            (.childSafety, "illegal", "Child Safety / CSAM"),
            (.spam, "spam", "Spam"),
            (.harassment, "other", "Harassment"),
            (.illegal, "illegal", "Illegal content"),
            (.other, "other", "Other"),
        ]
        #expect(Nip56.ReportCategory.allCases.count == expected.count)
        for (category, type, label) in expected {
            #expect(category.nip56Type == type)
            #expect(category.label == label)
        }
    }

    @Test func standardReportTypes_areTheNip56Set() {
        #expect(Nip56.reportTypes == [
            "nudity", "malware", "profanity", "illegal", "spam", "impersonation", "other",
        ])
    }

    @Test func buildReportTags_typesPAndE_andDoesNotDuplicateReportedInRecipients() {
        let tags = Nip56.buildReportTags(
            reportedPubkey: "alice",
            category: .spam,
            eventId: "evt1",
            groupId: "room-a",
            recipients: ["alice", "mod1", "mod1", ""]
        )
        #expect(tags == [
            ["p", "alice", "spam"],
            ["e", "evt1", "spam"],
            ["h", "room-a"],
            ["p", "mod1"],
        ])
    }

    @Test func buildReportTags_profileOnly_omitsEAndH() {
        let tags = Nip56.buildReportTags(
            reportedPubkey: "bob",
            category: .childSafety
        )
        #expect(tags == [["p", "bob", "illegal"]])
    }

    @Test func reportContent_labelOnlyWhenReasonBlank() {
        #expect(Nip56.reportContent(category: .spam, reason: "  ") == "[Spam]")
        #expect(Nip56.reportContent(category: .illegal, reason: "stolen") == "[Illegal content] stolen")
    }

    @Test func parseReport_readsTypedP_andBracketedContent() throws {
        let event = NostrEvent(
            id: "rid",
            pubkey: "reporter",
            kind: Nip56.kindReport,
            createdAt: 10,
            tags: [
                ["p", "mod", "wss://hint"],
                ["p", "alice", "spam"],
                ["e", "evt1", "spam"],
                ["h", "room-a"],
            ],
            content: "[Spam] too many links",
            sig: ""
        )
        let parsed = try #require(Nip56.parseReport(event))
        #expect(parsed.reportedPubkey == "alice")
        #expect(parsed.reporterPubkey == "reporter")
        #expect(parsed.categoryLabel == "Spam")
        #expect(parsed.reason == "too many links")
        #expect(parsed.reportedEventId == "evt1")
        #expect(parsed.groupId == "room-a")
    }

    @Test func parseReport_childSafetyKeepsPreciseLabel() throws {
        let event = NostrEvent(
            id: "rid",
            pubkey: "reporter",
            kind: Nip56.kindReport,
            createdAt: 1,
            tags: [["p", "alice", "illegal"]],
            content: "[Child Safety / CSAM]",
            sig: ""
        )
        let parsed = try #require(Nip56.parseReport(event))
        #expect(parsed.categoryLabel == "Child Safety / CSAM")
        #expect(parsed.reason.isEmpty)
    }

    @Test func parseReport_fallsBackToFirstP_whenNoTypedReportType() throws {
        // Android fallback: untyped / hint-only p tags still parse. Do not
        // require a standard NIP-56 type here — that would diverge.
        let event = NostrEvent(
            id: "rid",
            pubkey: "reporter",
            kind: Nip56.kindReport,
            createdAt: 1,
            tags: [["p", "alice", "wss://hint.example"]],
            content: "[Spam]",
            sig: ""
        )
        let parsed = try #require(Nip56.parseReport(event))
        #expect(parsed.reportedPubkey == "alice")
        #expect(parsed.categoryLabel == "Spam")
    }

    @Test func parseReport_rejectsNon1984() {
        let event = NostrEvent(
            id: "x", pubkey: "r", kind: 1, createdAt: 0,
            tags: [["p", "alice", "spam"]], content: "[Spam]", sig: ""
        )
        #expect(Nip56.parseReport(event) == nil)
    }

    @Test func reportOutcome_hidesOnlyOnSent() {
        #expect(ReportOutcome.of(hasSigner: false, relayAccepted: true) == .needsKey)
        #expect(ReportOutcome.of(hasSigner: true, relayAccepted: false) == .failed)
        #expect(ReportOutcome.of(hasSigner: true, relayAccepted: true) == .sent)
        #expect(ReportOutcome.sent.hidesReportedContent)
        #expect(!ReportOutcome.failed.hidesReportedContent)
        #expect(!ReportOutcome.needsKey.hidesReportedContent)
    }

    @Test func reportTarget_eventCapturesRecipeCoordinate() {
        let recipe = NostrEvent(
            id: "eid",
            pubkey: String(repeating: "a", count: 64),
            kind: 30023,
            createdAt: 1,
            tags: [["d", "ragu"]],
            content: "",
            sig: ""
        )
        let target = ReportTarget.event(recipe)
        #expect(target.eventId == "eid")
        #expect(target.coordinate == RecipeRepository.coordinate(recipe))
        #expect(ReportTarget.profile(pubkey: "bob").eventId == nil)
    }
}

@Suite(.serialized)
@MainActor
struct ReportedContentTests {

    private func isolated(_ body: () async throws -> Void) async throws {
        let pk = "reported-test-\(UUID().uuidString)"
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

    @Test func hide_postHidesEventNotAuthor() async throws {
        try await isolated {
            let event = NostrEvent(
                id: "post-1", pubkey: "alice", kind: 1, createdAt: 1,
                tags: [], content: "hi", sig: ""
            )
            ReportedContent.shared.hide(.event(event))
            #expect(ReportedContent.shared.isHidden(eventId: "post-1"))
            #expect(!ReportedContent.shared.isHidden(pubkey: "alice"))
            #expect(ReportedContent.shared.isHidden(event))
        }
    }

    @Test func hide_profileHidesAuthor() async throws {
        try await isolated {
            ReportedContent.shared.hide(.profile(pubkey: "ALICE"))
            #expect(ReportedContent.shared.isHidden(pubkey: "alice"))
            let theirPost = NostrEvent(
                id: "p2", pubkey: "alice", kind: 1, createdAt: 1,
                tags: [], content: "x", sig: ""
            )
            #expect(ReportedContent.shared.isHidden(theirPost))
        }
    }

    @Test func hide_recipeHidesCoordinate() async throws {
        try await isolated {
            let author = String(repeating: "b", count: 64)
            let event = NostrEvent(
                id: "rec-1", pubkey: author, kind: 30023, createdAt: 1,
                tags: [["d", "ragu"]], content: "", sig: ""
            )
            ReportedContent.shared.hide(.event(event))
            #expect(ReportedContent.shared.isHidden(coordinate: RecipeRepository.coordinate(event)))
            #expect(!ReportedContent.shared.isHidden(pubkey: author))
        }
    }

    @Test func submit_needsKeyWhenWatchOnly() async {
        let outcome = await ReportSender.submit(
            target: .profile(pubkey: "alice"),
            category: .spam,
            reason: "",
            keypair: nil,
            publish: { _, _ in ["wss://nos.lol"] }
        )
        #expect(outcome == .needsKey)
        #expect(!outcome.hidesReportedContent)
    }

    @Test func submit_signedEventIsKind1984_andHidesOnAccept() async throws {
        try await isolated {
            let priv = Schnorr.randomPrivkey()
            let pub = try Schnorr.xonlyPubkey(privkey32: priv)
            let kp = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
            let target = ReportTarget.event(NostrEvent(
                id: "note-9", pubkey: "carol", kind: 1, createdAt: 1,
                tags: [], content: "bad", sig: ""
            ))

            var published: NostrEvent?
            let outcome = await ReportSender.submit(
                target: target,
                category: .harassment,
                reason: "mean",
                keypair: kp,
                extraRecipients: ["mod-a"],
                relays: ["wss://nos.lol"],
                publish: { event, relays in
                    published = event
                    #expect(relays == ["wss://nos.lol"])
                    return relays
                }
            )
            #expect(outcome == .sent)
            let event = try #require(published)
            #expect(event.kind == Nip56.kindReport)
            #expect(event.tags.contains(["p", "carol", "other"]))
            #expect(event.tags.contains(["e", "note-9", "other"]))
            #expect(event.tags.contains(["p", "mod-a"]))
            #expect(event.content == "[Harassment] mean")
            #expect(Schnorr.verify(
                sig64: Hex.decode(event.sig)!,
                messageId32: Hex.decode(event.id)!,
                xonlyPubkey32: pub
            ))
            #expect(ReportedContent.shared.isHidden(eventId: "note-9"))
        }
    }

    @Test func submit_failedDoesNotHide() async throws {
        try await isolated {
            let priv = Schnorr.randomPrivkey()
            let pub = try Schnorr.xonlyPubkey(privkey32: priv)
            let kp = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
            let outcome = await ReportSender.submit(
                target: .event(NostrEvent(
                    id: "note-fail", pubkey: "dave", kind: 1, createdAt: 1,
                    tags: [], content: "x", sig: ""
                )),
                category: .spam,
                reason: "",
                keypair: kp,
                relays: ["wss://nos.lol"],
                publish: { _, _ in [] }
            )
            #expect(outcome == .failed)
            #expect(!ReportedContent.shared.isHidden(eventId: "note-fail"))
        }
    }
}
