import Foundation
import Testing
@testable import wisp

/// The Data Recovery screen's state rules: nothing scans until the user taps
/// Scan, the current and past empty versions offer no restore, a newer
/// version found before signing becomes current and re-arms every
/// confirmation, the override appears only after a retry of the re-read
/// failed and is never pre-selected or carried into the next attempt, and a
/// view-only account can review but not restore. Relays are a scripted
/// `LazarusRelayIO`; the account's key signs for real.
@MainActor
struct LazarusRecoveryViewModelTests {

    private static let writeRelay = "wss://w1.example"
    private static let historyRelay = "wss://hist.example"
    private static let sets = LazarusRelaySets(
        defaults: ["wss://default.example"],
        standIns: ["wss://default.example"],
        archival: [historyRelay]
    )

    final class Adopted {
        var events: [NostrEvent] = []
    }

    private func model(
        keypair: Keypair,
        io: ScriptedRelayIO,
        kind: Int = 3,
        adopted: Adopted = Adopted()
    ) -> LazarusRecoveryViewModel {
        let pubkey = keypair.pubkey
        return LazarusRecoveryViewModel(keypair: keypair, initialKind: kind, io: io, sets: Self.sets) { env in
            env.activePubkey = { pubkey }
            env.localCopy = { _, _ in nil }
            env.adopt = { event, _ in adopted.events.append(event) }
        }
    }

    /// A relay serving `events` for whichever kind is asked, ending in `outcome`.
    private func serve(
        _ io: ScriptedRelayIO, _ relay: String, _ events: [NostrEvent], outcome: LazarusRelayOutcome = .answered
    ) {
        let history = ScriptedRelayIO.history(events)
        io.script(relay) { filter in
            LazarusRelayAnswer(events: history(filter).events, outcome: outcome)
        }
    }

    /// The account's relay list names the write relay; the history relay holds
    /// a clobber (40 follows, then 3).
    private func clobberedFollows(_ keypair: Keypair, writeRelayAnswers: Bool = true)
        throws -> (io: ScriptedRelayIO, full: NostrEvent, clobbered: NostrEvent) {
        let io = ScriptedRelayIO()
        let relayList = try LazarusFixture.signed(keypair, kind: 10002, createdAt: 500, tags: [["r", Self.writeRelay]])
        let full = try LazarusFixture.signed(keypair, kind: 3, createdAt: 1000, tags: (0..<40).map { ["p", "pk\($0)"] })
        let clobbered = try LazarusFixture.signed(keypair, kind: 3, createdAt: 2000, tags: (0..<3).map { ["p", "pk\($0)"] })
        serve(io, "wss://default.example", [relayList])
        serve(io, Self.historyRelay, [full, clobbered])
        serve(io, Self.writeRelay, [clobbered], outcome: writeRelayAnswers ? .answered : .failed)
        return (io, full, clobbered)
    }

    private func settle(timeout: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func scanned(_ model: LazarusRecoveryViewModel) async throws {
        model.startScan()
        try #require(await settle { model.phase == .done || model.phase == .failed })
    }

    // MARK: - Scanning

    @Test func choosingAKindNeverScans() throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let model = model(keypair: keypair, io: io)
        model.selectKind(10000)
        #expect(model.selectedKind == 10000)
        #expect(model.phase == .idle)
        #expect(io.queries.isEmpty)
    }

    @Test func scansOnATapAndRecommendsTheVersionFromBeforeTheClobber() async throws {
        let keypair = try LazarusFixture.keypair()
        let (io, full, clobbered) = try clobberedFollows(keypair)
        let model = model(keypair: keypair, io: io)
        try await scanned(model)
        #expect(model.plan?.write == [Self.writeRelay])
        #expect(model.scan?.currentConfirmed == true)
        #expect(model.scan?.current?.id == clobbered.id)
        #expect(model.scan?.recommended?.id == full.id)
    }

    @Test func aScanNoRelayAnsweredIsAnErrorNotAnEmptyResult() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        io.scriptAll { _ in LazarusRelayAnswer(events: [], outcome: .failed) }
        let model = model(keypair: keypair, io: io)
        try await scanned(model)
        #expect(model.phase == .failed)
        #expect(model.scan?.relayList == .unknown)
    }

    @Test func retryingTheUnreachableRelaysConfirmsCurrentAndRecommends() async throws {
        let keypair = try LazarusFixture.keypair()
        let (io, full, clobbered) = try clobberedFollows(keypair, writeRelayAnswers: false)
        let model = model(keypair: keypair, io: io)
        try await scanned(model)
        #expect(model.unreachableRelays == [Self.writeRelay])
        #expect(model.scan?.recommended == nil)

        serve(io, Self.writeRelay, [clobbered])
        model.retryUnreachable()
        try #require(await settle { !model.retrying })
        #expect(model.scan?.currentConfirmed == true)
        #expect(model.scan?.recommended?.id == full.id)
        #expect(model.unreachableRelays.isEmpty)
    }

    // MARK: - Review

    @Test func offersNoRestoreForTheCurrentVersionOrAPastEmptyOne() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let full = try LazarusFixture.signed(keypair, kind: 3, createdAt: 1000, tags: [["p", "a"], ["p", "b"]])
        let emptied = try LazarusFixture.signed(keypair, kind: 3, createdAt: 1500)
        let current = try LazarusFixture.signed(keypair, kind: 3, createdAt: 2000, tags: [["p", "a"]])
        serve(io, Self.historyRelay, [full, emptied, current])
        let model = model(keypair: keypair, io: io)
        try await scanned(model)
        let scan = try #require(model.scan)
        #expect(!model.canReview(try #require(scan.current)))
        #expect(!model.canReview(try #require(scan.candidates.first { $0.id == emptied.id })))
        #expect(model.canReview(try #require(scan.candidates.first { $0.id == full.id })))
    }

    /// Meaningful-empty kinds: an empty version is a valid option, and the
    /// intent question is never pre-answered.
    @Test func anEmptyKeyListCanBeReviewedAndTheIntentQuestionStartsUnanswered() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let emptied = try LazarusFixture.signed(keypair, kind: 10044, createdAt: 1000)
        let keys = try LazarusFixture.signed(keypair, kind: 10044, createdAt: 2000, tags: [["n", String(repeating: "a", count: 64)]])
        serve(io, Self.historyRelay, [emptied, keys])
        let model = model(keypair: keypair, io: io, kind: 10044)
        try await scanned(model)
        let emptyVersion = try #require(model.scan?.candidates.first { $0.id == emptied.id })
        #expect(model.canReview(emptyVersion))
        #expect(model.scan?.recommended == nil)
        model.openReview(emptyVersion)
        #expect(model.review?.intentConfirmed == false)
    }

    @Test func aNewerVersionFoundBeforeSigningBecomesCurrentAndReArmsTheReview() async throws {
        let keypair = try LazarusFixture.keypair()
        let (io, full, _) = try clobberedFollows(keypair)
        let model = model(keypair: keypair, io: io)
        try await scanned(model)
        // Another device edited the list after the scan.
        let newer = try LazarusFixture.signed(keypair, kind: 3, createdAt: 3000, tags: [["p", "pk0"], ["p", "zz"]])
        serve(io, Self.writeRelay, [newer])

        model.openReview(try #require(model.scan?.candidates.first { $0.id == full.id }))
        model.armShrinkConfirmation(true)
        model.restore()
        try #require(await settle { model.review?.status == .ready && model.review?.changedSinceReview == true })
        #expect(model.review?.reviewedCurrent?.id == newer.id)
        #expect(model.review?.shrinkArmed == false)
        // Everything found is shown: the newer version joins the list as current.
        #expect(model.scan?.current?.id == newer.id)
        #expect(io.published.isEmpty)
        #expect(model.review?.delta?.removed == [["p", "zz"]])
    }

    /// Spec "Recover": no write relay answering stops the restore with a
    /// retry; only after the retry fails is the override offered, unselected,
    /// and it never carries into the next attempt.
    @Test func offersTheOverrideOnlyAfterAFailedRetryAndNeverCarriesItOver() async throws {
        let keypair = try LazarusFixture.keypair()
        let adopted = Adopted()
        let (io, full, clobbered) = try clobberedFollows(keypair)
        let model = model(keypair: keypair, io: io, adopted: adopted)
        try await scanned(model)
        serve(io, Self.writeRelay, [], outcome: .timedOut)
        model.openReview(try #require(model.scan?.candidates.first { $0.id == full.id }))

        model.restore()
        try #require(await settle { model.review?.status == .unconfirmed })
        #expect(model.review?.unconfirmedAttempts == 1)
        #expect(model.review?.overrideOffered == false)
        model.setOverrideConfirmed(true)
        #expect(model.review?.overrideConfirmed == false)

        model.restore()
        try #require(await settle { model.review?.status == .unconfirmed && model.review?.unconfirmedAttempts == 2 })
        #expect(model.review?.overrideOffered == true)
        #expect(model.review?.overrideConfirmed == false)

        // A plain retry with the box ticked doesn't use it, and clears it.
        model.setOverrideConfirmed(true)
        model.restore()
        try #require(await settle { model.review?.status == .unconfirmed && model.review?.unconfirmedAttempts == 3 })
        #expect(model.review?.overrideConfirmed == false)
        #expect(io.published.isEmpty)

        model.setOverrideConfirmed(true)
        model.restore(override: true)
        try #require(await settle { model.published != nil })
        let event = try #require(model.published?.report.event)
        #expect(event.createdAt > clobbered.createdAt)
        #expect(event.tags == full.tags)
        #expect(adopted.events.map(\.id) == [event.id])
        #expect(model.review == nil)
        #expect(model.reviewingId == nil)
    }

    @Test func aViewOnlyAccountCanReviewButNotRestore() async throws {
        let keypair = try LazarusFixture.keypair()
        let viewOnly = Keypair(privkey: "", pubkey: keypair.pubkey)
        let (io, full, _) = try clobberedFollows(keypair)
        let model = model(keypair: viewOnly, io: io)
        #expect(!model.canSign)
        try await scanned(model)
        model.openReview(try #require(model.scan?.candidates.first { $0.id == full.id }))
        #expect(model.review != nil)
        let queriesBefore = io.queries.count
        model.restore()
        #expect(model.review?.status == .ready)
        #expect(io.queries.count == queriesBefore)
        #expect(io.published.isEmpty)
    }
}
