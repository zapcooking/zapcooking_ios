import Foundation
import Testing
@testable import wisp

/// Live NIP-56 publish-verify-delete (Concern 4.1).
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.nip56_live_enable` or `NIP56_LIVE=1`).
/// Uses an ephemeral keypair — never a real nsec, never printed, never
/// written to disk. The key is held in memory until this test has published
/// the matching kind-5 and confirmed the event is gone from
/// `RelayDefaults.defaults`. Publish-without-delete is how the first 2.3
/// run left eight real recipes on primal / nos.lol (§7.13).
///
/// Target is `RelayDefaults.defaults` only — not the indexer union, which
/// hung ~1030s in 3.1.
@Suite(.tags(.liveNetwork))
struct Nip56LiveTests {

    private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".nip56_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        return ProcessInfo.processInfo.environment["NIP56_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: Nip56LiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.nip56_live_enable; run with -parallel-testing-enabled NO (see ZAPCOOKING_IOS_BUILD.md)"
        )
    )
    func publish_verify_delete_kind1984_onDefaults() async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
        let relays = ReportSender.publishRelays
        #expect(relays == RelayDefaults.defaults)

        let reportedPubkey = String(repeating: "0", count: 64)
        let reportedEventId = String(repeating: "1", count: 64)
        let tags = Nip56.buildReportTags(
            reportedPubkey: reportedPubkey,
            category: .other,
            eventId: reportedEventId,
            recipients: []
        )
        let content = Nip56.reportContent(
            category: .other,
            reason: "iOS 4.1 live-gate probe. Safe to ignore."
        )
        let event = try await Signer.sign(
            keypair: keypair,
            kind: Nip56.kindReport,
            tags: tags,
            content: content
        )
        #expect(event.kind == Nip56.kindReport)
        let parsed = try #require(Nip56.parseReport(event))
        #expect(parsed.reportedPubkey == reportedPubkey)
        #expect(parsed.reportedEventId == reportedEventId)
        #expect(parsed.categoryLabel == "Other")

        let accepted = await RelayPool.publish(event: event, to: relays, timeout: 8)
        #expect(
            !accepted.isEmpty,
            "no defaults relay accepted the report. targeted=\(relays) accepted=\(accepted)"
        )
        print("Nip56 live: published id=\(event.id) accepted=\(accepted)")

        let fetched = await RelayPool.query(
            relays: relays,
            filter: NostrFilter(kinds: [Nip56.kindReport], authors: [keypair.pubkey], ids: [event.id], limit: 5),
            timeout: 10,
            waitForAllRelays: true
        )
        let found = fetched.contains { $0.id == event.id && $0.kind == Nip56.kindReport }
        #expect(
            found,
            "defaults did not echo kind-1984. accepted=\(accepted) fetched=\(fetched.map { "\($0.kind):\($0.id.prefix(8))" })"
        )

        let deletion = try await Signer.sign(
            keypair: keypair,
            kind: Nip09.kindDeletion,
            tags: Nip09.deletionTagsForEvent(id: event.id, kind: Nip56.kindReport),
            content: "iOS 4.1 live-gate cleanup"
        )
        let delAccepted = await RelayPool.publish(event: deletion, to: relays, timeout: 8)
        #expect(
            !delAccepted.isEmpty,
            "no defaults relay accepted the delete. targeted=\(relays) — report remains live id=\(event.id)"
        )
        print("Nip56 live: delete accepted=\(delAccepted)")

        var leftover: [NostrEvent] = []
        for attempt in 1...3 {
            let after = await RelayPool.query(
                relays: relays,
                filter: NostrFilter(kinds: [Nip56.kindReport], authors: [keypair.pubkey], ids: [event.id], limit: 5),
                timeout: 10,
                waitForAllRelays: true
            )
            leftover = after.filter { $0.id == event.id && $0.kind == Nip56.kindReport }
            if leftover.isEmpty { break }
            if attempt < 3 {
                try await Task.sleep(for: .seconds(2))
            }
        }
        #expect(
            leftover.isEmpty,
            "defaults still serving kind-1984 after delete. leftover=\(leftover.map(\.id)) id=\(event.id)"
        )
    }
}
