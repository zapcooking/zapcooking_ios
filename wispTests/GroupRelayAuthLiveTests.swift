import Foundation
import Testing
@testable import wisp

/// Issue #6 live gates — `GroupRelayPool`'s NIP-42 state machine against the
/// real `wss://pantry.zap.cooking` (khatru + member-relay policies). Run on the
/// gate VM by hand, `-parallel-testing-enabled NO`.
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.group_auth_live_enable` or
/// `GROUP_AUTH_LIVE=1`).
///
/// Keys: gates 1–2 mint ephemeral throwaway keys in memory — never a real
/// nsec, never printed, never written to disk. Gate 3 needs an actual pantry
/// member key, supplied ONLY via the `ZC_MEMBER_NSEC` environment variable on
/// the VM (the gate skips when unset); it is never committed, logged, or
/// echoed — the frame log truncates frames and the key never appears in one.
///
/// What each gate would fail on if the fix were wrong:
///  1. an unbounded replay loop (pre-fix F-6) never reaches the terminal
///     `.notMember`, and the 60s ceiling trips;
///  2. a pre-emptive account-type refusal would emit `.authUnavailable`
///     before the relay challenged; a silent-empty regression never emits it;
///  3. marking authed on send (not `OK`) leaves the machine `.pending` or the
///     ordering REQ→AUTH→OK→REQ absent from the wire log; a reconnect that
///     replays before AUTH settles breaks the same ordering on connection 2.
@Suite(.tags(.liveNetwork))
@MainActor
struct GroupRelayAuthLiveTests {

    private static let pantry = RelayDefaults.members.first ?? "wss://pantry.zap.cooking"

    nonisolated private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".group_auth_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["GROUP_AUTH_LIVE"] == "1"
            || env["TEST_RUNNER_GROUP_AUTH_LIVE"] == "1"
    }

    /// Trait-safe presence check; the key itself is parsed inside the test.
    nonisolated private static var memberNsecSet: Bool {
        let env = ProcessInfo.processInfo.environment
        let nsec = env["ZC_MEMBER_NSEC"] ?? env["TEST_RUNNER_ZC_MEMBER_NSEC"]
        return !(nsec ?? "").isEmpty
    }

    private static var memberKeypair: Keypair? {
        let env = ProcessInfo.processInfo.environment
        guard let nsec = env["ZC_MEMBER_NSEC"] ?? env["TEST_RUNNER_ZC_MEMBER_NSEC"],
              !nsec.isEmpty else { return nil }
        return NostrKey.parseNsec(nsec)
    }

    /// A filter pantry's `rejectFilterPolicy` auth-gates for everyone but the
    /// pinned author: kind 30078 by a pubkey that is not ours and not the
    /// Nourish service.
    private static func memberGatedFilter() throws -> NostrFilter {
        let stranger = try Schnorr.xonlyPubkey(privkey32: Schnorr.randomPrivkey())
        var filter = NostrFilter()
        filter.kinds = [30078]
        filter.authors = [Hex.encode(stranger)]
        filter.limit = 1
        return filter
    }

    /// True when `patterns` occur in `log` in order (each match strictly after
    /// the previous one).
    private static func ordered(_ log: [String], _ patterns: [String]) -> Bool {
        var from = log.startIndex
        for pattern in patterns {
            guard let found = log[from...].firstIndex(where: { $0.contains(pattern) }) else {
                return false
            }
            from = log.index(after: found)
        }
        return true
    }

    @discardableResult
    private static func eventually(timeout: TimeInterval,
                                   _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }

    // MARK: - Gate 1: throwaway key → terminal restricted state, not a loop

    @Test(
        .tags(.liveNetwork),
        .enabled(if: GroupRelayAuthLiveTests.isDeliberatelyEnabled,
                 "Opt in: touch wispTests/.group_auth_live_enable")
    )
    func throwawayKey_memberGatedRead_terminatesNotMember() async throws {
        let priv = Schnorr.randomPrivkey()
        let keypair = Keypair(privkey: Hex.encode(priv),
                              pubkey: Hex.encode(try Schnorr.xonlyPubkey(privkey32: priv)))
        let pool = GroupRelayPool()
        await pool.ensureRelay(Self.pantry, keypair: keypair)
        defer { Task { await pool.shutdownAll() } }

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: Self.pantry,
                                          filter: try Self.memberGatedFilter(),
                                          subId: "gate1-\(Int(Date().timeIntervalSince1970))")
        let recorder = box.record(stream)
        defer { recorder.cancel() }

        // Pre-fix this looped at RTT rate and never terminated.
        #expect(await Self.eventually(timeout: 60) { box.finished },
                "stream must reach a terminal state, not loop")
        guard case .notMember(let reason)? = box.items.last else {
            Issue.record("expected terminal .notMember, got \(box.items)")
            return
        }
        #expect(reason.lowercased().hasPrefix("restricted"))
        // The throwaway key CAN auth — it fails on membership, after acceptance.
        #expect(await pool.authState(relayUrl: Self.pantry) == .authenticated)

        let log = await pool.frameLogForTesting(relayUrl: Self.pantry)
        #expect(Self.ordered(log, [
            "-> [\"REQ\"",   // optimistic REQ provokes…
            "<- [\"AUTH\"",  // …the challenge
            "-> [\"AUTH\"",  // our kind-22242
            "<- [\"OK\"",    // the relay's verdict
            "-> [\"REQ\"",   // replay only after settle
        ]), "wire order REQ→AUTH→AUTH→OK→REQ not found in: \(log)")
    }

    // MARK: - Gate 2: watch-only → explicit .authUnavailable on challenge

    @Test(
        .tags(.liveNetwork),
        .enabled(if: GroupRelayAuthLiveTests.isDeliberatelyEnabled,
                 "Opt in: touch wispTests/.group_auth_live_enable")
    )
    func watchOnly_memberGatedRead_terminatesAuthUnavailable() async throws {
        let pub = try Schnorr.xonlyPubkey(privkey32: Schnorr.randomPrivkey())
        let keypair = Keypair(privkey: "", pubkey: Hex.encode(pub))
        let pool = GroupRelayPool()
        await pool.ensureRelay(Self.pantry, keypair: keypair)
        defer { Task { await pool.shutdownAll() } }

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: Self.pantry,
                                          filter: try Self.memberGatedFilter(),
                                          subId: "gate2-\(Int(Date().timeIntervalSince1970))")
        let recorder = box.record(stream)
        defer { recorder.cancel() }

        #expect(await Self.eventually(timeout: 60) { box.finished })
        guard case .authUnavailable? = box.items.last else {
            Issue.record("expected terminal .authUnavailable, got \(box.items)")
            return
        }
        #expect(await pool.authState(relayUrl: Self.pantry) == .unavailable)
        // The state came from the relay's challenge, not account-type
        // pre-emption: a REQ and the relay's AUTH frame precede it, and no
        // AUTH event was ever sent.
        let log = await pool.frameLogForTesting(relayUrl: Self.pantry)
        #expect(Self.ordered(log, ["-> [\"REQ\"", "<- [\"AUTH\""]))
        #expect(!log.contains { $0.hasPrefix("-> [\"AUTH\"") })
    }

    // MARK: - Gate 3: member key → events flow; reconnect repeats the ordering

    @Test(
        .tags(.liveNetwork),
        .enabled(if: GroupRelayAuthLiveTests.isDeliberatelyEnabled,
                 "Opt in: touch wispTests/.group_auth_live_enable"),
        .enabled(if: GroupRelayAuthLiveTests.memberNsecSet,
                 "Set ZC_MEMBER_NSEC in the VM environment (never committed)")
    )
    func memberKey_subscribeSurvivesAuth_andReconnectReordersCorrectly() async throws {
        let keypair = try #require(Self.memberKeypair)
        let pool = GroupRelayPool()
        await pool.ensureRelay(Self.pantry, keypair: keypair)
        defer { Task { await pool.shutdownAll() } }

        // Own app-data: auth-gated for everyone else, allowed for self once authed.
        var filter = NostrFilter()
        filter.kinds = [30078]
        filter.authors = [keypair.pubkey]
        filter.limit = 5

        let box = SubEventBox()
        let stream = await pool.subscribe(relayUrl: Self.pantry, filter: filter,
                                          subId: "gate3-\(Int(Date().timeIntervalSince1970))")
        let recorder = box.record(stream)
        defer { recorder.cancel() }

        #expect(await Self.eventually(timeout: 30) {
            await pool.authState(relayUrl: Self.pantry) == .authenticated
        }, "member AUTH must settle authenticated (on the relay's OK, not on send)")
        #expect(!box.finished, "member subscribe must stay open after AUTH")

        let log1 = await pool.frameLogForTesting(relayUrl: Self.pantry)
        #expect(Self.ordered(log1, [
            "-> [\"REQ\"", "<- [\"AUTH\"", "-> [\"AUTH\"", "<- [\"OK\"", "-> [\"REQ\"",
        ]), "connection 1 wire order not found in: \(log1)")

        // Kill the socket mid-subscription; the reconnect must repeat the
        // exact ordering on the fresh connection (reader first, optimistic
        // REQ, replay only after the new OK).
        let framesBefore = log1.count
        await pool.dropConnectionForTesting(relayUrl: Self.pantry)

        #expect(await Self.eventually(timeout: 45) {
            await pool.authState(relayUrl: Self.pantry) == .authenticated
        }, "reconnect must re-authenticate")
        #expect(!box.finished, "subscription must survive the reconnect")

        let log2 = await pool.frameLogForTesting(relayUrl: Self.pantry)
        let tail = Array(log2.dropFirst(framesBefore))
        #expect(Self.ordered(tail, [
            "-> [\"REQ\"", "<- [\"AUTH\"", "-> [\"AUTH\"", "<- [\"OK\"", "-> [\"REQ\"",
        ]), "post-reconnect wire order not found in: \(tail)")
    }
}
