import Foundation
import Testing
@testable import wisp

/// The one live check of the scheduled-posts API: schedule a note two hours
/// out with a throwaway key, find it in the list, cancel it, and confirm it
/// reads cancelled. **It never posts**: the note is cancelled long before its
/// time, and a cancelled row is final. Nothing here touches a relay.
///
/// Off unless the operator opts in: `touch wispTests/.schedule_live_enable`
/// (git-ignored) or set `SCHEDULE_LIVE=1`. Same mechanism as
/// `Nip98LiveRoundTripTests`.
@MainActor
@Suite(.tags(.liveNetwork))
struct ScheduleLiveTests {

    nonisolated private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".schedule_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        return ProcessInfo.processInfo.environment["SCHEDULE_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: ScheduleLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.schedule_live_enable"
        )
    )
    func scheduleListCancel_neverPosts() async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = Hex.encode(try Schnorr.xonlyPubkey(privkey32: priv))
        let keypair = Keypair(privkey: Hex.encode(priv), pubkey: pub)
        let auth = LocalNip98Signer(keypair: keypair)
        let session = URLSession(configuration: .ephemeral)

        // Two hours out: an hour of margin over the one-hour minimum for a
        // live check, and nowhere near the sweep.
        let publishAt = NostrClock.now() + 2 * 3_600
        let event = try await ScheduleApi.sign(
            kind: 1, tags: [], content: "iOS schedule contract check. Cancelled before it posts.",
            publishAt: publishAt, signer: AccountScheduleSigner(keypair: keypair)
        ).get()
        #expect(event.createdAt == publishAt)

        let receipt = try await ScheduleApi.schedule(event: event, signer: auth, session: session).get()
        #expect(receipt.id == event.id)
        #expect(receipt.publishAt == publishAt)
        #expect(receipt.status == .pending)
        #expect(!receipt.alreadyScheduled)

        // Whatever the assertions below do, do not leave it pending.
        do {
            // The same signed event again: the earlier attempt landed.
            let again = try await ScheduleApi.schedule(event: event, signer: auth, session: session).get()
            #expect(again.alreadyScheduled)
            #expect(again.status == .pending)

            let pending = try await ScheduleApi.list(status: .pending, signer: auth, session: session).get()
            let row = try #require(pending.first(where: { $0.id == event.id }))
            #expect(row.status == .pending)
            #expect(row.publishAt == publishAt)
            #expect(row.event.id == event.id)
            #expect(row.event.sig == event.sig)
            #expect(row.event.hasValidSignature())
        } catch {
            _ = await ScheduleApi.cancel(id: event.id, signer: auth, session: session)
            throw error
        }

        let done = try await ScheduleApi.cancel(id: event.id, signer: auth, session: session).get()
        #expect(done == ScheduleCancellation(id: event.id, alreadyCancelled: false))

        let after = try await ScheduleApi.list(status: .cancelled, signer: auth, session: session).get()
        let row = try #require(after.first(where: { $0.id == event.id }))
        #expect(row.status == .cancelled)
        #expect(row.sentAt == nil)

        let stillPending = try await ScheduleApi.list(status: .pending, signer: auth, session: session).get()
        #expect(!stillPending.contains(where: { $0.id == event.id }))

        // Cancelling again is honest about it, and a dead row cannot be revived.
        let twice = try await ScheduleApi.cancel(id: event.id, signer: auth, session: session).get()
        #expect(twice.alreadyCancelled)
        let revived = await ScheduleApi.schedule(event: event, signer: auth, session: session)
        if case .failure(let failure) = revived {
            #expect(failure == .alreadyScheduled(status: .cancelled))
        } else {
            Issue.record("a cancelled event was accepted again")
        }
    }
}
