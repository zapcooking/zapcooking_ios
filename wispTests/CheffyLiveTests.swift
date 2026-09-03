import Foundation
import Testing
@testable import wisp

/// Concern C-E live gates — Cheffy chat against the real
/// `https://zap.cooking/api/zappy`. Run on the gate VM by hand,
/// `-parallel-testing-enabled NO`.
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.cheffy_live_enable` or
/// `CHEFFY_LIVE=1`).
///
/// Keys: the gated-state check mints an ephemeral throwaway key in memory —
/// never a real nsec, never printed, never written to disk. The round-trip
/// and save-hand-off gates need a key pantry has granted an active tier,
/// supplied via the `ZC_MEMBER_NSEC` environment variable or — hosted test
/// runs don't deliver `TEST_RUNNER_` env forwarding — the git-ignored file
/// `wispTests/.zc_member_nsec` (trimmed); those gates skip when neither is
/// present. The key is never committed, logged, or echoed.
///
/// **No live writes.** Chat is read-only against the backend and nothing
/// here touches a relay; the save hand-off is proven up to the prefilled
/// compose form (the publish path is `RecipePublisher`, live-proven in
/// 2.3/2.4 and exercised by hand in GATE.md).
@Suite(.tags(.liveNetwork))
@MainActor
struct CheffyLiveTests {

    nonisolated private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".cheffy_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["CHEFFY_LIVE"] == "1" || env["TEST_RUNNER_CHEFFY_LIVE"] == "1"
    }

    /// The member nsec: `ZC_MEMBER_NSEC` env var, else the git-ignored file
    /// `wispTests/.zc_member_nsec` (trimmed). Never committed, logged, or echoed.
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

    // MARK: - Gate 3, gated half: a verified non-member

    /// An ephemeral key signs a valid NIP-98 header and is not a member.
    /// Two things must hold: the owner check says so definitively (the
    /// screen gate), and the chat endpoint's 403 carries no `code`, so the
    /// taxonomy hands the view model `apiRejected(code: nil)` — the
    /// "unavailable" bubble, never `.membersOnly`.
    @Test(
        .tags(.liveNetwork),
        .enabled(if: CheffyLiveTests.isDeliberatelyEnabled,
                 "Opt in: touch wispTests/.cheffy_live_enable (see GATE.md)")
    )
    func nonMember_isGatedByOwnerCheck_andChatIsBare403() async throws {
        let keypair = try Self.ephemeralKeypair()
        let signer = LocalNip98Signer(keypair: keypair)

        let status = try await ZapCookingApi.checkMembershipStatus(signer: signer)
        #expect(status.owner, "acceptance is owner:true — the NIP-98 byte contract")
        #expect(!status.isActive)
        #expect(CheffyViewModel.gate(for: status) == .notMember)

        let request = CheffyRequest(prompt: "hi", mode: .chat, messages: [])
        do {
            let output = try await CheffyService().send(request, signer: signer)
            Issue.record("a non-member got an answer: \(output.prefix(80))")
        } catch let error as ZapCookingApiError {
            guard case .apiRejected(let code, let message) = error else {
                Issue.record("expected apiRejected(code: nil), got \(error)")
                return
            }
            #expect(code == nil, "the members-only 403 carries no code today; a new code means the taxonomy needs a case")
            #expect(message == "Cheffy is available to Cook+ members.")
            let bubble = CheffyViewModel.bubble(for: error, id: 1)
            #expect(bubble.kind == .error && bubble.content == Cheffy.unavailableMessage)
        }
    }

    // MARK: - Gate 2 + Gate 3 ungated half: a member round-trips a conversation

    @Test(
        .tags(.liveNetwork),
        .enabled(if: CheffyLiveTests.isDeliberatelyEnabled,
                 "Opt in: touch wispTests/.cheffy_live_enable (see GATE.md)"),
        .enabled(if: CheffyLiveTests.memberNsecSet,
                 "Supply the member key: ZC_MEMBER_NSEC env var, or the file wispTests/.zc_member_nsec (git-ignored, never committed)")
    )
    func member_roundTripsAMultiTurnConversation() async throws {
        let keypair = try Self.memberKeypair()
        let signer = LocalNip98Signer(keypair: keypair)

        let status = try await ZapCookingApi.checkMembershipStatus(signer: signer)
        #expect(status.owner && status.isActive, "the member key must hold an active tier on pantry")
        #expect(CheffyViewModel.gate(for: status) == .open)

        let service = CheffyService()
        let t0 = Date()
        let first = try await service.send(
            CheffyRequest(prompt: "Can I substitute yogurt for sour cream?", mode: .chat, messages: []),
            signer: signer
        )
        let firstLatency = Date().timeIntervalSince(t0)
        print("[CheffyLive] turn 1 latency=\(String(format: "%.1f", firstLatency))s chars=\(first.count)")
        #expect(!first.isEmpty)
        #expect(firstLatency < 75, "over the compute client's ceiling")

        // Second turn carries the thread — the server is stateless.
        let t1 = Date()
        let second = try await service.send(
            CheffyRequest(
                prompt: "And in a baked cheesecake?",
                mode: .chat,
                messages: [
                    CheffyMessage(role: "user", content: "Can I substitute yogurt for sour cream?"),
                    CheffyMessage(role: "assistant", content: first),
                ]
            ),
            signer: signer
        )
        let secondLatency = Date().timeIntervalSince(t1)
        print("[CheffyLive] turn 2 latency=\(String(format: "%.1f", secondLatency))s chars=\(second.count)")
        #expect(!second.isEmpty)
    }

    // MARK: - Gate 4: a structured recipe reply prefills the compose form

    @Test(
        .tags(.liveNetwork),
        .enabled(if: CheffyLiveTests.isDeliberatelyEnabled,
                 "Opt in: touch wispTests/.cheffy_live_enable (see GATE.md)"),
        .enabled(if: CheffyLiveTests.memberNsecSet,
                 "Supply the member key: ZC_MEMBER_NSEC env var, or the file wispTests/.zc_member_nsec (git-ignored, never committed)")
    )
    func member_hungryReplyIsAStructuredRecipe_thatPrefillsCompose() async throws {
        let keypair = try Self.memberKeypair()
        let signer = LocalNip98Signer(keypair: keypair)

        let t0 = Date()
        let output = try await CheffyService().send(
            CheffyRequest(prompt: "", mode: .hungry, messages: []),
            signer: signer
        )
        let latency = Date().timeIntervalSince(t0)
        print("[CheffyLive] hungry latency=\(String(format: "%.1f", latency))s chars=\(output.count)")
        #expect(Cheffy.looksLikeStructuredRecipe(output), "hungry did not return the strict format:\n\(output.prefix(400))")

        // The Save hand-off: the same seam Sous Chef's Edit uses.
        let store = RecipeComposeViewModel()
        store.prefillFromMarkdown(output)
        #expect(!store.title.isEmpty && store.title != "Untitled")
        #expect(!store.ingredients.map(\.text).filter { !$0.isEmpty }.isEmpty, "ingredients did not parse")
        #expect(!store.directions.map(\.text).filter { !$0.isEmpty }.isEmpty, "directions did not parse")
    }
}
