import Foundation
import Testing
@testable import wisp

/// Lazarus relay I/O: relay-set assembly, the relay list lookup
/// (found / missing / unknown), per-relay outcomes, validation of what relays
/// return, paging, retry, and the pre-sign re-read. Hermetic: relays are a
/// scripted `LazarusRelayIO`; every event is really signed, so the engine's
/// signature checks run for real. Ported from the zap.cooking web suite
/// (`source.test.ts`) and the spec's reference suite ("relay queries").

/// Answers each request from a per-relay script. Unscripted relays answer
/// with nothing (EOSE).
nonisolated final class ScriptedRelayIO: LazarusRelayIO, @unchecked Sendable {
    typealias Script = @Sendable (LazarusFilter) -> LazarusRelayAnswer

    private let lock = NSLock()
    private var scripts: [String: Script] = [:]
    private var fallback: Script = { _ in LazarusRelayAnswer(events: [], outcome: .answered) }
    private var _queries: [(relay: String, filter: LazarusFilter)] = []
    private var publishOutcomes: [String: LazarusPublishOutcome] = [:]
    private var _published: [(relay: String, event: NostrEvent)] = []

    func script(_ relay: String, _ script: @escaping Script) {
        lock.lock(); scripts[relay] = script; lock.unlock()
    }

    func scriptAll(_ script: @escaping Script) {
        lock.lock(); fallback = script; lock.unlock()
    }

    func setPublishOutcome(_ relay: String, _ outcome: LazarusPublishOutcome) {
        lock.lock(); publishOutcomes[relay] = outcome; lock.unlock()
    }

    var queries: [(relay: String, filter: LazarusFilter)] { lock.lock(); defer { lock.unlock() }; return _queries }
    var published: [(relay: String, event: NostrEvent)] { lock.lock(); defer { lock.unlock() }; return _published }

    func query(relay: String, filter: LazarusFilter, timeout: TimeInterval) async -> LazarusRelayAnswer {
        let script = lock.withLock {
            _queries.append((relay, filter))
            return scripts[relay] ?? fallback
        }
        return script(filter)
    }

    func publish(event: NostrEvent, relay: String, timeout: TimeInterval) async -> LazarusPublishOutcome {
        lock.withLock {
            _published.append((relay, event))
            return publishOutcomes[relay] ?? .accepted
        }
    }

    func closeAll() async {}

    /// Serve `events` the way a relay does: newest first, honoring `until`
    /// (inclusive) and `limit`.
    static func history(_ events: [NostrEvent], honorUntil: Bool = true) -> Script {
        { filter in
            let served = events
                .filter { filter.kinds.contains($0.kind) }
                .filter { !honorUntil || filter.until == nil || $0.createdAt <= filter.until! }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(filter.limit)
            return LazarusRelayAnswer(events: Array(served), outcome: .answered)
        }
    }
}

struct LazarusScanEngineTests {

    private static let sets = LazarusRelaySets(
        defaults: ["wss://default.example"],
        standIns: ["wss://default.example"],
        archival: Lazarus.uniqueRelays(Lazarus.archivalRelays)
    )
    private static let history = "wss://hist.nostr.land"

    private func engine(_ io: ScriptedRelayIO) -> LazarusScanEngine {
        LazarusScanEngine(io: io, sets: Self.sets)
    }

    private func followList(_ keypair: Keypair, _ count: Int, _ createdAt: Int) throws -> NostrEvent {
        try LazarusFixture.signed(keypair, kind: 3, createdAt: createdAt, tags: (0..<count).map { ["p", "pk\($0)"] })
    }

    private func found(write: [String], read: [String] = []) -> LazarusUserRelays {
        LazarusUserRelays(read: read, write: write, status: .found)
    }

    private let follows = LazarusRegistry.profile(for: 3)!

    // MARK: - Relay set and relay list

    @Test func scansEveryUserRelayReadAndWriteTheDefaultsAndTheArchivalSet() async throws {
        let keypair = try LazarusFixture.keypair()
        let appCopy = Lazarus.userRelays(
            read: ["wss://hist.nostr.land/", "wss://r1.example/"],
            write: (1...6).map { "wss://w\($0).example/" },
            standIns: Self.sets.standIns
        )
        let plan = await engine(ScriptedRelayIO()).plan(pubkey: keypair.pubkey, appCopy: appCopy)
        #expect(plan.user.status == .found)
        // Past the first few write relays, and read relays too.
        for expected in ["wss://w6.example", "wss://r1.example", "wss://default.example"] {
            #expect(plan.relays.contains(expected))
        }
        for relay in Lazarus.archivalRelays { #expect(plan.relays.contains(relay)) }
        // A user relay that is also archival is scanned once.
        #expect(plan.relays.filter { $0 == "wss://hist.nostr.land" }.count == 1)
        #expect(Set(plan.relays).count == plan.relays.count)
    }

    @Test func looksTheRelayListUpWhenTheAppHasNoneTakingTheNewest() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let old = try LazarusFixture.signed(keypair, kind: 10002, createdAt: 1000, tags: [["r", "wss://old.example", "write"]])
        let new = try LazarusFixture.signed(keypair, kind: 10002, createdAt: 2000, tags: [["r", "wss://new.example", "write"]])
        io.script("wss://default.example") { _ in LazarusRelayAnswer(events: [old], outcome: .answered) }
        io.script(Self.history) { _ in LazarusRelayAnswer(events: [new], outcome: .answered) }
        let plan = await engine(io).plan(pubkey: keypair.pubkey, appCopy: nil)
        #expect(plan.user.status == .found)
        #expect(plan.write == ["wss://new.example"])
        #expect(io.queries.allSatisfy { $0.filter.kinds == [10002] && $0.filter.limit == 1 })
    }

    @Test func letsTheDefaultsStandInWhenRelaysAnsweredWithoutARelayList() async throws {
        let keypair = try LazarusFixture.keypair()
        let plan = await engine(ScriptedRelayIO()).plan(pubkey: keypair.pubkey, appCopy: nil)
        #expect(plan.user.status == .missing)
        #expect(plan.write == ["wss://default.example"])
        #expect(plan.relays.contains(Self.history))
    }

    @Test func neverSubstitutesTheDefaultsWhenNoRelayAnsweredTheLookup() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        io.scriptAll { _ in LazarusRelayAnswer(events: [], outcome: .failed) }
        let plan = await engine(io).plan(pubkey: keypair.pubkey, appCopy: nil)
        #expect(plan.user.status == .unknown)
        #expect(plan.write.isEmpty)
        // The default and archival sets are still scanned.
        #expect(plan.relays.contains("wss://default.example"))
        #expect(plan.relays.contains(Self.history))
    }

    /// A lookup's timed-out relay isn't "no relay list" either.
    @Test func treatsALookupThatOnlyTimedOutAsUnknown() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        io.scriptAll { _ in LazarusRelayAnswer(events: [], outcome: .timedOut) }
        #expect(await engine(io).userRelays(pubkey: keypair.pubkey, appCopy: nil).status == .unknown)
    }

    @Test func aFetchedRelayListNamingNoWriteRelaysCountsAsMissing() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let readOnly = try LazarusFixture.signed(keypair, kind: 10002, createdAt: 1000, tags: [["r", "wss://inbox.example", "read"]])
        io.script("wss://default.example") { _ in LazarusRelayAnswer(events: [readOnly], outcome: .answered) }
        let relays = await engine(io).userRelays(pubkey: keypair.pubkey, appCopy: nil)
        #expect(relays.status == .missing)
        #expect(relays.write == ["wss://default.example"])
        #expect(relays.read == ["wss://inbox.example"])
    }

    @Test func ignoresAForgedRelayListInTheLookup() async throws {
        let keypair = try LazarusFixture.keypair()
        let someoneElse = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let foreign = try LazarusFixture.signed(someoneElse, kind: 10002, createdAt: 5000, tags: [["r", "wss://evil.example"]])
        io.script("wss://default.example") { _ in LazarusRelayAnswer(events: [foreign], outcome: .answered) }
        let relays = await engine(io).userRelays(pubkey: keypair.pubkey, appCopy: nil)
        #expect(relays.status == .missing)
        #expect(!relays.write.contains("wss://evil.example"))
    }

    // MARK: - Fetch, outcomes, validation

    @Test func pagesBackFromRelaysThatFilledAPage() async throws {
        let keypair = try LazarusFixture.keypair()
        let history = try (0..<70).map { try followList(keypair, 10, 1000 + $0) }
        let io = ScriptedRelayIO()
        io.script(Self.history, ScriptedRelayIO.history(history))
        let relays = [Self.history, "wss://default.example"]
        let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: relays)
        var scan = Lazarus.scanResult(follows, page: page, writeRelays: ["wss://default.example"], relayList: .found)
        #expect(scan.candidates.count == 50)
        #expect(scan.olderCursors == [Self.history: 1020])

        let older = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: [Self.history], cursors: scan.olderCursors)
        #expect(io.queries.last?.filter.until == 1020)
        scan = Lazarus.mergeOlder(follows, scan, page: older, privateTags: [:])
        #expect(scan.candidates.count == 70)
        #expect(scan.olderCursors.isEmpty)
        #expect(scan.queriedRelays == relays)
    }

    @Test func stopsPagingARelayThatIgnoresUntil() async throws {
        let keypair = try LazarusFixture.keypair()
        let history = try (0..<70).map { try followList(keypair, 10, 1000 + $0) }
        let io = ScriptedRelayIO()
        io.script(Self.history, ScriptedRelayIO.history(history, honorUntil: false))
        let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: [Self.history])
        var scan = Lazarus.scanResult(follows, page: page, writeRelays: [], relayList: .found)
        let older = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: [Self.history], cursors: scan.olderCursors)
        scan = Lazarus.mergeOlder(follows, scan, page: older, privateTags: [:])
        #expect(scan.candidates.count == 50)
        #expect(scan.olderCursors.isEmpty)
    }

    @Test func recordsHowEachRelayEndedKeepingVersionsSentBeforeAFailure() async throws {
        let keypair = try LazarusFixture.keypair()
        let partial = try followList(keypair, 5, 1000)
        let io = ScriptedRelayIO()
        // Sends a version, then its connection drops before EOSE.
        io.script(Self.history) { _ in LazarusRelayAnswer(events: [partial], outcome: .failed) }
        io.script("wss://w1.example") { _ in LazarusRelayAnswer(events: [], outcome: .failed) }
        io.script("wss://slow.example") { _ in LazarusRelayAnswer(events: [], outcome: .timedOut) }
        let plan = await engine(io).plan(pubkey: keypair.pubkey, appCopy: found(write: ["wss://w1.example"], read: ["wss://slow.example"]))
        let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: plan.relays)
        let scan = Lazarus.scanResult(follows, page: page, writeRelays: plan.write, relayList: plan.user.status)
        #expect(scan.candidates.map(\.id) == [partial.id])
        #expect(scan.relayOutcomes?[Self.history] == .failed)
        #expect(scan.relayOutcomes?["wss://w1.example"] == .failed)
        #expect(scan.relayOutcomes?["wss://slow.example"] == .timedOut)
        #expect(scan.relayOutcomes?["wss://default.example"] == .answered)
        // The only write relay failed, so current is unconfirmed.
        #expect(!scan.currentConfirmed)
        #expect(!Lazarus.reachedNoRelay(scan))
    }

    @Test func recommendsNothingWhileNoWriteRelayAnswered() async throws {
        let keypair = try LazarusFixture.keypair()
        let full = try followList(keypair, 40, 1000)
        let clobbered = try followList(keypair, 3, 2000)
        func scan(writeRelayAnswers: Bool) async -> LazarusScanResult {
            let io = ScriptedRelayIO()
            io.script(Self.history) { _ in LazarusRelayAnswer(events: [full, clobbered], outcome: .answered) }
            io.script("wss://w1.example") { _ in
                LazarusRelayAnswer(events: [], outcome: writeRelayAnswers ? .answered : .failed)
            }
            let plan = await engine(io).plan(pubkey: keypair.pubkey, appCopy: found(write: ["wss://w1.example"]))
            let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: plan.relays)
            return Lazarus.scanResult(follows, page: page, writeRelays: plan.write, relayList: plan.user.status)
        }
        #expect(await scan(writeRelayAnswers: true).recommended?.id == full.id)
        let unconfirmed = await scan(writeRelayAnswers: false)
        #expect(!unconfirmed.currentConfirmed)
        #expect(unconfirmed.recommended == nil)
    }

    @Test func showsVersionsThatArrivedEvenWhenNoRelayAnswered() async throws {
        let keypair = try LazarusFixture.keypair()
        let partial = try followList(keypair, 5, 1000)
        let io = ScriptedRelayIO()
        io.scriptAll { _ in LazarusRelayAnswer(events: [], outcome: .failed) }
        io.script(Self.history) { _ in LazarusRelayAnswer(events: [partial], outcome: .failed) }
        let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: [Self.history, "wss://default.example"])
        #expect(!Lazarus.isFailedScan(page))
        let scan = Lazarus.scanResult(follows, page: page, writeRelays: [], relayList: .unknown)
        #expect(scan.candidates.map(\.id) == [partial.id])
        #expect(Lazarus.reachedNoRelay(scan))
    }

    @Test func failsAScanNoRelayAnsweredWithNothingToShow() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        io.scriptAll { _ in LazarusRelayAnswer(events: [], outcome: .timedOut) }
        let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: [Self.history, "wss://default.example"])
        #expect(Lazarus.isFailedScan(page))
        #expect(page.outcomes.values.allSatisfy { $0 == .timedOut })
    }

    /// Only valid versions count as candidates, as relays that returned
    /// versions, and for paging: a full page of forged versions moves nothing.
    @Test func countsOnlyValidVersionsOfTheListFromEachRelay() async throws {
        let keypair = try LazarusFixture.keypair()
        let someoneElse = try LazarusFixture.keypair()
        let valid = try followList(keypair, 5, 1000)
        let foreign = try followList(someoneElse, 9, 1001)
        let wrongKind = try LazarusFixture.signed(keypair, kind: 10000, createdAt: 1002, tags: [["p", "x"]])
        let forged = try (0..<50).map { i -> NostrEvent in
            let real = try followList(keypair, 5, 900 + i)
            return NostrEvent(id: real.id, pubkey: real.pubkey, kind: 3, createdAt: real.createdAt,
                              tags: real.tags + [["p", "injected"]], content: "", sig: real.sig)
        }
        let io = ScriptedRelayIO()
        io.script(Self.history) { _ in LazarusRelayAnswer(events: [valid, foreign, wrongKind], outcome: .answered) }
        io.script("wss://nos.lol") { _ in LazarusRelayAnswer(events: forged, outcome: .answered) }
        let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: [Self.history, "wss://nos.lol"])
        #expect(page.tagged.map(\.event.id) == [valid.id])
        #expect(page.respondingRelays == [Self.history])
        #expect(page.olderCursors.isEmpty)
        #expect(page.outcomes["wss://nos.lol"] == .answered)
    }

    @Test func countsARelayThatAnsweredWithOnlyForeignEventsAsHavingNothing() async throws {
        let keypair = try LazarusFixture.keypair()
        let someoneElse = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let foreign = try followList(someoneElse, 9, 1001)
        io.script("wss://hostile.example") { _ in LazarusRelayAnswer(events: [foreign], outcome: .answered) }
        let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: ["wss://hostile.example"])
        #expect(page.tagged.isEmpty)
        #expect(page.respondingRelays.isEmpty)
        #expect(page.outcomes["wss://hostile.example"] == .answered)
    }

    @Test func asksEveryRelayForTheScannedKindAndAuthorWithALimitOfFifty() async throws {
        let pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: Schnorr.randomPrivkey()))
        let io = ScriptedRelayIO()
        _ = await engine(io).fetch(kind: 10000, pubkey: pubkey, relays: ["wss://a.example", "wss://b.example"])
        let queries = io.queries
        #expect(queries.count == 2)
        #expect(queries.allSatisfy {
            $0.filter.kinds == [10000] && $0.filter.authors == [pubkey] && $0.filter.limit == 50 && $0.filter.until == nil
        })
    }

    // MARK: - Retry

    @Test func retriesOnlyTheRelaysThatFailedAndConfirmsCurrentWhenAWriteRelayAnswers() async throws {
        let keypair = try LazarusFixture.keypair()
        let full = try followList(keypair, 40, 1000)
        let clobbered = try followList(keypair, 3, 2000)
        let io = ScriptedRelayIO()
        io.script(Self.history) { _ in LazarusRelayAnswer(events: [full, clobbered], outcome: .answered) }
        io.script("wss://w1.example") { _ in LazarusRelayAnswer(events: [], outcome: .timedOut) }
        let plan = await engine(io).plan(pubkey: keypair.pubkey, appCopy: found(write: ["wss://w1.example"]))
        let page = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: plan.relays)
        let scan = Lazarus.scanResult(follows, page: page, writeRelays: plan.write, relayList: plan.user.status)
        let unreachable = scan.queriedRelays.filter { scan.relayOutcomes?[$0] != .answered }
        #expect(unreachable == ["wss://w1.example"])

        io.script("wss://w1.example") { _ in LazarusRelayAnswer(events: [clobbered], outcome: .answered) }
        let before = io.queries.count
        let retry = await engine(io).fetch(kind: 3, pubkey: keypair.pubkey, relays: unreachable)
        #expect(io.queries.count == before + 1)
        let merged = Lazarus.mergeRetry(follows, scan, page: retry, writeRelays: plan.write, privateTags: [:])
        #expect(merged.currentConfirmed)
        #expect(merged.relayOutcomes?["wss://w1.example"] == .answered)
        #expect(merged.recommended?.id == full.id)
        #expect(merged.candidates.first { $0.id == clobbered.id }?.foundOn.contains("wss://w1.example") == true)
    }

    // MARK: - Re-read before signing

    @Test func readsEveryWriteRelayBeforeARestoreTellingFailedReadsFromEmptyOnes() async throws {
        let keypair = try LazarusFixture.keypair()
        let someoneElse = try LazarusFixture.keypair()
        let newer = try followList(keypair, 6, 2000)
        let foreign = try followList(someoneElse, 6, 3000)
        let io = ScriptedRelayIO()
        io.script("wss://w1.example") { _ in LazarusRelayAnswer(events: [foreign], outcome: .answered) }
        io.script("wss://w2.example") { _ in LazarusRelayAnswer(events: [newer], outcome: .answered) }
        io.script("wss://w3.example") { _ in LazarusRelayAnswer(events: [], outcome: .failed) }
        let answers = await engine(io).readCurrent(
            kind: 3, pubkey: keypair.pubkey, writeRelays: ["wss://w1.example", "wss://w2.example", "wss://w3.example"]
        )
        #expect(answers.map(\.answered) == [true, true, false])
        #expect(answers.map { $0.events.map(\.id) } == [[], [newer.id], []])
        #expect(answers.map(\.relay) == ["wss://w1.example", "wss://w2.example", "wss://w3.example"])
        #expect(io.queries.allSatisfy { $0.filter.limit == 1 })
    }

    @Test func publishesToEachRelayAndReportsEachOutcome() async throws {
        let keypair = try LazarusFixture.keypair()
        let event = try followList(keypair, 3, 1000)
        let io = ScriptedRelayIO()
        io.setPublishOutcome("wss://no.example", .rejected(reason: "blocked: not allowed"))
        io.setPublishOutcome("wss://slow.example", .timedOut)
        let outcomes = await engine(io).publish(event, to: ["wss://ok.example", "wss://no.example", "wss://slow.example"])
        #expect(outcomes == [
            "wss://ok.example": .accepted,
            "wss://no.example": .rejected(reason: "blocked: not allowed"),
            "wss://slow.example": .timedOut,
        ])
    }

    /// Connection budget: a long relay list isn't asked all at once.
    @Test func boundsHowManyRelaysAreAskedAtOnce() async throws {
        let keypair = try LazarusFixture.keypair()
        let gauge = ConcurrencyGauge()
        let io = GaugedRelayIO(gauge: gauge)
        let relays = (0..<40).map { "wss://r\($0).example" }
        let page = await LazarusScanEngine(io: io, sets: Self.sets, maxConcurrent: 5)
            .fetch(kind: 3, pubkey: keypair.pubkey, relays: relays)
        #expect(page.outcomes.count == 40)
        #expect(gauge.peak <= 5)
        #expect(gauge.peak >= 2)
    }
}

nonisolated final class ConcurrencyGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var _peak = 0
    func enter() { lock.lock(); current += 1; _peak = max(_peak, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return _peak }
}

nonisolated final class GaugedRelayIO: LazarusRelayIO, @unchecked Sendable {
    let gauge: ConcurrencyGauge
    init(gauge: ConcurrencyGauge) { self.gauge = gauge }

    func query(relay: String, filter: LazarusFilter, timeout: TimeInterval) async -> LazarusRelayAnswer {
        gauge.enter()
        try? await Task.sleep(for: .milliseconds(20))
        gauge.leave()
        return LazarusRelayAnswer(events: [], outcome: .answered)
    }

    func publish(event: NostrEvent, relay: String, timeout: TimeInterval) async -> LazarusPublishOutcome { .accepted }
    func closeAll() async {}
}
