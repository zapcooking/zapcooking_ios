import Foundation
import Testing
@testable import wisp

/// Lazarus's one write path: the author check, the pre-sign re-read and its
/// override, the recovery's timestamp, success judged on the write relays,
/// best-effort copies, and the local-copy update. Hermetic: every network
/// and store edge is an injected closure; signing uses a real ephemeral key.
/// Ported from the zap.cooking web suite (`lazarusPublish.test.ts`) and the
/// spec's "Recover" rules.
@MainActor
struct LazarusPublisherTests {

    private nonisolated static let now = 1_800_000_000
    private nonisolated static let writeRelays = ["wss://write-a.example", "wss://write-b.example"]

    final class Trace {
        var reads: [[String]] = []
        var signed: [NostrEvent] = []
        var published: [(event: NostrEvent, relays: [String])] = []
        var bestEffort: [(event: NostrEvent, relays: [String])] = []
        var adopted: [(event: NostrEvent, privateTags: [[String]]?)] = []
        var signCalls = 0
    }

    private struct Fixture {
        let keypair: Keypair
        let trace: Trace
        let publisher: LazarusPublisher
    }

    private func fixture(
        keypair: Keypair? = nil,
        answers: [LazarusReadAnswer]? = nil,
        local: NostrEvent? = nil,
        activeAfterSigning: String?? = .none,
        accepting: Set<String>? = nil,
        signThrows: Bool = false
    ) throws -> Fixture {
        let keypair = try keypair ?? LazarusFixture.keypair()
        let trace = Trace()
        let answers = answers ?? [LazarusReadAnswer(events: [], answered: true)]
        let env = LazarusPublisher.Environment(
            readCurrent: { _, _, relays in
                trace.reads.append(relays)
                return answers
            },
            localCopy: { _, _ in local },
            activePubkey: {
                if trace.signCalls > 0, case .some(let after) = activeAfterSigning { return after }
                return keypair.pubkey
            },
            now: { Self.now },
            sign: { signing, draft in
                trace.signCalls += 1
                struct Boom: Error {}
                if signThrows { throw Boom() }
                let event = try await Signer.sign(
                    keypair: signing, kind: draft.kind, tags: draft.tags,
                    content: draft.content, createdAt: draft.createdAt
                )
                trace.signed.append(event)
                return event
            },
            publish: { event, relays in
                trace.published.append((event, relays))
                return Dictionary(uniqueKeysWithValues: relays.map { relay in
                    (relay, (accepting ?? Set(relays)).contains(relay)
                        ? LazarusPublishOutcome.accepted
                        : .rejected(reason: "blocked: not today"))
                })
            },
            publishBestEffort: { event, relays in trace.bestEffort.append((event, relays)) },
            adopt: { event, tags in trace.adopted.append((event, tags)) }
        )
        return Fixture(keypair: keypair, trace: trace, publisher: LazarusPublisher(env: env))
    }

    private func followList(_ keypair: Keypair, _ count: Int, _ createdAt: Int) throws -> NostrEvent {
        try LazarusFixture.signed(keypair, kind: 3, createdAt: createdAt, tags: (0..<count).map { index in
            let hex = String(index, radix: 16)
            return ["p", String(repeating: "0", count: 64 - hex.count) + hex]
        })
    }

    private func request(
        _ f: Fixture,
        chosen: NostrEvent,
        reviewed: NostrEvent?,
        writeRelays: [String] = LazarusPublisherTests.writeRelays,
        answered: [String] = [],
        privateTags: [[String]]? = nil,
        override: Bool = false
    ) -> LazarusPublisher.Request {
        LazarusPublisher.Request(
            chosen: chosen, reviewedCurrent: reviewed, keypair: f.keypair,
            writeRelays: writeRelays, answeredRelays: answered, standIns: ["wss://default.example"],
            privateTags: privateTags, allowUnconfirmed: override
        )
    }

    private func report(_ outcome: LazarusRestoreOutcome) -> LazarusPublishReport? {
        if case .published(let report) = outcome { return report }
        return nil
    }

    private func changed(_ outcome: LazarusRestoreOutcome) -> NostrEvent? {
        if case .changed(let current, _) = outcome { return current }
        return nil
    }

    private func isUnconfirmed(_ outcome: LazarusRestoreOutcome) -> Bool {
        if case .unconfirmed = outcome { return true }
        return false
    }

    private func failure(_ outcome: LazarusRestoreOutcome) -> LazarusRestoreFailure? {
        if case .failed(let failure) = outcome { return failure }
        return nil
    }

    // MARK: - Re-read and dating

    /// The clobber was published elsewhere and the write relays still hold an
    /// older version: no edit since the review, and the restore is dated
    /// after the reviewed (future-dated) clobber.
    @Test func restoresOverAnOlderCopyDatedAfterTheReviewedVersion() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now + 3600)
        let olderCopy = try followList(keypair, 38, Self.now - 3600)
        let f = try fixture(keypair: keypair, answers: [LazarusReadAnswer(events: [olderCopy], answered: true)])
        let published = try #require(report(await f.publisher.restore(request(f, chosen: healthy, reviewed: clobbered))))
        let event = published.event
        #expect(event.createdAt == clobbered.createdAt + 1)
        #expect(event.tags == healthy.tags)
        #expect(event.content == healthy.content)
        #expect(event.kind == 3)
        #expect(event.pubkey == keypair.pubkey)
        #expect(Lazarus.hasValidSignature(event))
        #expect(f.trace.reads == [Self.writeRelays])
    }

    @Test func datesTheRestoreNowWhenTheReplacedVersionIsOlder() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let current = try followList(keypair, 3, Self.now - 60)
        let f = try fixture(keypair: keypair, answers: [LazarusReadAnswer(events: [current], answered: true)])
        let published = try #require(report(await f.publisher.restore(request(f, chosen: healthy, reviewed: current))))
        #expect(published.event.createdAt == Self.now)
    }

    @Test func asksAgainWhenANewerVersionAppearedThenRestoresOnTheRetry() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now + 3600)
        let newer = try followList(keypair, 5, Self.now + 7200)
        let answers = [LazarusReadAnswer(events: [newer], answered: true, relay: Self.writeRelays[0])]
        let f = try fixture(keypair: keypair, answers: answers)
        #expect(changed(await f.publisher.restore(request(f, chosen: healthy, reviewed: clobbered)))?.id == newer.id)
        #expect(f.trace.signCalls == 0)
        // The retry passes the version the delta was recomputed against.
        let retry = try #require(report(await f.publisher.restore(request(f, chosen: healthy, reviewed: newer))))
        #expect(retry.event.createdAt == newer.createdAt + 1)
    }

    @Test func treatsAVersionFoundWhenNoneWasReviewedAsAChange() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let found = try followList(keypair, 10, Self.now - 60)
        let f = try fixture(keypair: keypair, answers: [LazarusReadAnswer(events: [found], answered: true)])
        #expect(changed(await f.publisher.restore(request(f, chosen: healthy, reviewed: nil)))?.id == found.id)
    }

    @Test func aNewerCopyOnThisDeviceIsAChange() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now - 3600)
        let local = NostrEvent(id: "local-3-\(Self.now - 60)", pubkey: keypair.pubkey, kind: 3,
                               createdAt: Self.now - 60, tags: [["p", "x"]], content: "", sig: "")
        let f = try fixture(keypair: keypair, local: local)
        #expect(changed(await f.publisher.restore(request(f, chosen: healthy, reviewed: clobbered)))?.id == local.id)
        #expect(f.trace.signCalls == 0)
    }

    @Test func abortsBeforeSigningWhenNoWriteRelayAnswersTheReRead() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now + 3600)
        let f = try fixture(keypair: keypair, answers: [
            LazarusReadAnswer(events: [], answered: false),
            LazarusReadAnswer(events: [], answered: false),
        ])
        #expect(isUnconfirmed(await f.publisher.restore(request(f, chosen: healthy, reviewed: clobbered))))
        #expect(f.trace.signCalls == 0)
        #expect(f.trace.published.isEmpty)
        #expect(f.trace.adopted.isEmpty)
    }

    /// Spec 0.6 override: explicit, after a failed retry, dated after the
    /// reviewed version (the only one the delta was computed against).
    @Test func restoresUnderTheExplicitOverrideDatedAfterTheReviewedVersion() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now + 3600)
        let f = try fixture(keypair: keypair, answers: [LazarusReadAnswer(events: [], answered: false)])
        let published = try #require(report(await f.publisher.restore(
            request(f, chosen: healthy, reviewed: clobbered, override: true)
        )))
        #expect(published.event.createdAt == clobbered.createdAt + 1)
        #expect(f.trace.signCalls == 1)
    }

    @Test func theOverrideStillStopsForANewerVersion() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now - 3600)
        let newer = try followList(keypair, 5, Self.now - 60)
        // A relay that sent the newer version and then failed still shows the edit.
        let f = try fixture(keypair: keypair, answers: [LazarusReadAnswer(events: [newer], answered: false)])
        #expect(changed(await f.publisher.restore(
            request(f, chosen: healthy, reviewed: clobbered, override: true)
        ))?.id == newer.id)
        #expect(f.trace.signCalls == 0)
    }

    // MARK: - Publish and success

    @Test func reportsOnlyTheWriteRelaysThatAcceptedTheRestore() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now - 3600)
        let f = try fixture(keypair: keypair, accepting: [Self.writeRelays[1]])
        let published = try #require(report(await f.publisher.restore(request(f, chosen: healthy, reviewed: clobbered))))
        #expect(published.succeeded)
        #expect(published.accepted == [Self.writeRelays[1]])
        #expect(published.notAccepted.map(\.relay) == [Self.writeRelays[0]])
        #expect(published.notAccepted.first?.outcome == .rejected(reason: "blocked: not today"))
        #expect(f.trace.published.map(\.relays) == [Self.writeRelays])
    }

    /// Whatever other relays did, no write relay accepting is a failure.
    @Test func aRestoreNoWriteRelayAcceptedFailsAndLeavesTheLocalCopyAlone() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now - 3600)
        let f = try fixture(keypair: keypair, accepting: [])
        let outcome = await f.publisher.restore(request(f, chosen: healthy, reviewed: clobbered, answered: ["wss://hist.nostr.land"]))
        guard case .notAccepted(let report) = try #require(failure(outcome)) else {
            Issue.record("expected notAccepted")
            return
        }
        #expect(!report.succeeded)
        #expect(f.trace.adopted.isEmpty)
        #expect(f.trace.bestEffort.isEmpty)
    }

    @Test func sendsBestEffortCopiesAndUpdatesTheLocalCopyAfterSuccess() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try LazarusFixture.signed(keypair, kind: 10000, createdAt: Self.now - 86_400, content: "")
        let clobbered = try LazarusFixture.signed(keypair, kind: 10000, createdAt: Self.now - 3600)
        let decrypted = [["p", String(repeating: "c", count: 64)], ["word", "spoilers"]]
        let f = try fixture(keypair: keypair)
        let published = try #require(report(await f.publisher.restore(request(
            f, chosen: healthy, reviewed: clobbered,
            answered: ["wss://hist.nostr.land", Self.writeRelays[0]], privateTags: decrypted
        ))))
        #expect(published.bestEffort == ["wss://hist.nostr.land"])
        #expect(f.trace.bestEffort.map(\.relays) == [["wss://hist.nostr.land"]])
        #expect(f.trace.adopted.map(\.event.id) == [published.event.id])
        #expect(f.trace.adopted.first?.privateTags == decrypted)
    }

    /// Spec 0.6: a relay list restore is judged on the write relays the
    /// restored version names; the current ones still get it as a best effort.
    @Test func judgesARelayListRestoreOnTheWriteRelaysTheRestoredVersionNames() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try LazarusFixture.signed(keypair, kind: 10002, createdAt: Self.now - 86_400, tags: [
            ["r", "wss://alive.example/", "write"], ["r", "wss://inbox.example/", "read"],
        ])
        let clobbered = try LazarusFixture.signed(keypair, kind: 10002, createdAt: Self.now - 3600, tags: [
            ["r", "wss://dead.example"],
        ])
        let f = try fixture(keypair: keypair)
        let published = try #require(report(await f.publisher.restore(request(
            f, chosen: healthy, reviewed: clobbered, writeRelays: ["wss://dead.example"]
        ))))
        #expect(published.judgedOn == ["wss://alive.example"])
        #expect(f.trace.published.map(\.relays) == [["wss://alive.example"]])
        #expect(published.bestEffort == ["wss://dead.example"])
        // The re-read still asks the current write relays.
        #expect(f.trace.reads == [["wss://dead.example"]])
    }

    // MARK: - Who may restore

    @Test func refusesToRestoreAnotherAccountsVersion() async throws {
        let keypair = try LazarusFixture.keypair()
        let someoneElse = try LazarusFixture.keypair()
        let theirs = try followList(someoneElse, 40, Self.now - 86_400)
        let f = try fixture(keypair: keypair)
        let outcome = await f.publisher.restore(request(f, chosen: theirs, reviewed: nil))
        guard case .wrongAccount = try #require(failure(outcome)) else {
            Issue.record("expected wrongAccount")
            return
        }
        #expect(f.trace.reads.isEmpty)
        #expect(f.trace.signCalls == 0)
    }

    /// An account switch while signing must not publish under the old review.
    @Test func stopsWhenTheActiveAccountChangedWhileSigning() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now - 3600)
        let f = try fixture(keypair: keypair, activeAfterSigning: .some("someone-else"))
        let outcome = await f.publisher.restore(request(f, chosen: healthy, reviewed: clobbered))
        guard case .wrongAccount = try #require(failure(outcome)) else {
            Issue.record("expected wrongAccount")
            return
        }
        #expect(f.trace.published.isEmpty)
        #expect(f.trace.adopted.isEmpty)
    }

    @Test func aViewOnlyAccountCannotRestore() async throws {
        let keypair = try LazarusFixture.keypair()
        let viewOnly = Keypair(privkey: "", pubkey: keypair.pubkey)
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let f = try fixture(keypair: viewOnly)
        let outcome = await f.publisher.restore(request(f, chosen: healthy, reviewed: nil))
        guard case .cannotSign = try #require(failure(outcome)) else {
            Issue.record("expected cannotSign")
            return
        }
        #expect(f.trace.reads.isEmpty)
    }

    /// An unknown relay list leaves no write relays: nowhere to confirm
    /// current or judge success, so nothing is attempted.
    @Test func hasNothingToPublishToWithoutWriteRelays() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let f = try fixture(keypair: keypair)
        let outcome = await f.publisher.restore(request(f, chosen: healthy, reviewed: nil, writeRelays: []))
        guard case .noWriteRelays = try #require(failure(outcome)) else {
            Issue.record("expected noWriteRelays")
            return
        }
        #expect(f.trace.reads.isEmpty)
    }

    @Test func publishesNothingWhenSigningFails() async throws {
        let keypair = try LazarusFixture.keypair()
        let healthy = try followList(keypair, 40, Self.now - 86_400)
        let clobbered = try followList(keypair, 3, Self.now - 3600)
        let f = try fixture(keypair: keypair, signThrows: true)
        let outcome = await f.publisher.restore(request(f, chosen: healthy, reviewed: clobbered))
        guard case .signFailed = try #require(failure(outcome)) else {
            Issue.record("expected signFailed")
            return
        }
        #expect(f.trace.published.isEmpty)
    }
}
