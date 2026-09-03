import Foundation
import Observation

/// Backs `CheffyView` — the member-gated Cheffy chat (Concern C-E, port of
/// Android `CheffyViewModel` / the web `cheffyChat` store: chat + hungry,
/// pure conversation).
///
/// **Stateless full-history**: the live thread lives here; every send maps
/// the resolved text/recipe turns to `{role, content}` and re-sends them
/// with the new prompt. Nothing is persisted (no DB, no Nostr) — "Start
/// over" clears it. The server caps history to 12 turns; mirrored
/// client-side (`Cheffy.maxHistoryTurns`).
///
/// **Gate** (build spec §4.3, message only): on open the account's
/// membership is read through the NIP-98 owner check. A verified
/// `owner: true` + inactive answer is the one definitive "not a member"
/// signal and renders the gate screen; a failed read leaves the composer
/// open and lets the server decide, where a bare 403 renders as
/// "unavailable" rather than a denial (a pantry outage is the same 403).
@Observable
@MainActor
final class CheffyViewModel {

    nonisolated enum Role: Equatable, Sendable { case user, cheffy }
    nonisolated enum Kind: Equatable, Sendable { case text, recipe, pending, error, gated }

    nonisolated struct Message: Identifiable, Equatable, Sendable {
        let id: Int
        let role: Role
        var content: String
        var kind: Kind
        var expression: Cheffy.Expression = .neutral
        var statusLine: String? = nil
    }

    /// Screen-level gate, decided once per open.
    nonisolated enum Gate: Equatable, Sendable {
        /// Watch-only account — cannot sign a NIP-98 header, nothing to send.
        case watchOnly
        /// Verified `owner: true` and no active membership.
        case notMember
        /// Member, or membership undetermined (read failed) — composer open.
        case open
    }

    private(set) var thread: [Message] = []
    private(set) var loading = false
    private(set) var gate: Gate = .open
    /// True once `checkGate` has an answer (or gave up). The view holds a
    /// spinner until then so a member never sees the gate flash and a
    /// non-member never sees the composer flash (the web waits the same way).
    private(set) var gateResolved = false
    private var gateChecked = false

    private var lastStatusLine = ""
    private var lastTurn: (prompt: String, mode: CheffyMode)?
    private var nextId = 0

    /// Test/production seams — production is the compute-client service
    /// and the NIP-98 owner check on the general client.
    private let sendTurn: (CheffyRequest, Nip98Signing) async throws -> String
    private let readMembership: (Nip98Signing) async throws -> MembershipStatus

    init(
        sendTurn: ((CheffyRequest, Nip98Signing) async throws -> String)? = nil,
        readMembership: ((Nip98Signing) async throws -> MembershipStatus)? = nil
    ) {
        self.sendTurn = sendTurn ?? { try await CheffyService().send($0, signer: $1) }
        self.readMembership = readMembership ?? { try await ZapCookingApi.checkMembershipStatus(signer: $0) }
    }

    // MARK: - Gate

    /// Decide the gate for this account. Idempotent per instance.
    func checkGate(keypair: Keypair) async {
        if gateChecked { return }
        gateChecked = true
        defer { gateResolved = true }
        if keypair.isWatchOnly {
            gate = .watchOnly
            return
        }
        do {
            let status = try await readMembership(LocalNip98Signer(keypair: keypair))
            gate = Self.gate(for: status)
        } catch {
            // Undetermined — never a denial. The server is the truth.
            gate = .open
        }
    }

    /// Pure mapping, unit-tested: only a verified owner read that says
    /// inactive is the gate. Anything less (no `owner`, found-but-unknown)
    /// leaves the composer open.
    nonisolated static func gate(for status: MembershipStatus) -> Gate {
        if status.owner && !status.isActive { return .notMember }
        return .open
    }

    // MARK: - History

    /// Map the visible thread to the API history shape, mirroring the web
    /// `buildHistory`: only resolved text/recipe turns, optionally dropping
    /// the trailing user turn (retry re-sends it as the fresh prompt),
    /// capped to the server's last-N turns.
    func buildHistory(excludeTrailingUser: Bool = false) -> [CheffyMessage] {
        Self.history(from: thread, excludeTrailingUser: excludeTrailingUser)
    }

    nonisolated static func history(from thread: [Message], excludeTrailingUser: Bool) -> [CheffyMessage] {
        var api = thread
            .filter { ($0.kind == .text || $0.kind == .recipe) && !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { CheffyMessage(role: $0.role == .cheffy ? "assistant" : "user", content: $0.content) }
        if excludeTrailingUser, api.last?.role == "user" {
            api.removeLast()
        }
        return Array(api.suffix(Cheffy.maxHistoryTurns))
    }

    // MARK: - Send

    /// Send a turn. For `.hungry`, `content` is ignored and the server
    /// supplies the prompt. The gate is enforced by the view (no composer),
    /// and again here so a stale tap can't slip through.
    func send(_ content: String, mode: CheffyMode, keypair: Keypair) {
        if loading || gate != .open { return }
        let text = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Cheffy.maxPromptChars))
        if mode != .hungry && text.isEmpty { return }

        // Capture history BEFORE adding this user turn (mirrors the web order).
        let history = buildHistory()
        let display = mode == .hungry ? Cheffy.surpriseMeLabel : text
        thread.append(Message(id: mintId(), role: .user, content: display, kind: .text))
        let promptForApi = mode == .hungry ? "" : text
        lastTurn = (promptForApi, mode)
        let expectRecipe = mode == .hungry || Cheffy.looksLikeRecipeRequest(text)
        dispatch(prompt: promptForApi, mode: mode, history: history, expectRecipe: expectRecipe, keypair: keypair)
    }

    /// Re-send the last turn after an error. Only the trailing error bubble
    /// (the one whose Try again was tapped) is dropped — an error resolves
    /// the pending bubble in place, so it is always the last message; earlier
    /// errors stay in the scrollback as context.
    func retry(keypair: Keypair) {
        guard !loading, gate == .open, let last = lastTurn else { return }
        if thread.last?.kind == .error {
            thread.removeLast()
        }
        let history = buildHistory(excludeTrailingUser: true)
        let expectRecipe = last.mode == .hungry || Cheffy.looksLikeRecipeRequest(last.prompt)
        dispatch(prompt: last.prompt, mode: last.mode, history: history, expectRecipe: expectRecipe, keypair: keypair)
    }

    private func dispatch(
        prompt: String, mode: CheffyMode, history: [CheffyMessage],
        expectRecipe: Bool, keypair: Keypair
    ) {
        loading = true
        let statusLine = Cheffy.pickLine(expectRecipe ? Cheffy.cookingLines : Cheffy.thinkingLines, avoid: lastStatusLine)
        lastStatusLine = statusLine
        let pendingId = mintId()
        thread.append(Message(
            id: pendingId, role: .cheffy, content: "", kind: .pending,
            expression: expectRecipe ? .cooking : .thinking, statusLine: statusLine
        ))
        let request = CheffyRequest(prompt: prompt, mode: mode, messages: history)
        let signer = LocalNip98Signer(keypair: keypair)
        Task {
            let resolved: Message
            do {
                let output = try await sendTurn(request, signer)
                let isRecipe = Cheffy.looksLikeStructuredRecipe(output)
                resolved = Message(
                    id: pendingId, role: .cheffy, content: output,
                    kind: isRecipe ? .recipe : .text,
                    expression: isRecipe ? .happy : .neutral
                )
            } catch let error as ZapCookingApiError {
                resolved = Self.bubble(for: error, id: pendingId)
            } catch is CancellationError {
                thread.removeAll { $0.id == pendingId }
                loading = false
                return
            } catch {
                resolved = Self.bubble(for: .transport(error.localizedDescription), id: pendingId)
            }
            if let i = thread.firstIndex(where: { $0.id == pendingId }) {
                thread[i] = resolved
            }
            loading = false
        }
    }

    /// The 0.7a taxonomy → a bubble. Pure, unit-tested per class. Branches on
    /// the typed error (which itself dispatched on the body `code` first),
    /// never on a raw status.
    nonisolated static func bubble(for error: ZapCookingApiError, id: Int) -> Message {
        switch error {
        case .membersOnly:
            // `code: NOT_MEMBER` — not emitted by /api/zappy today, mapped for
            // the day it is. Message only (§4.3).
            return Message(id: id, role: .cheffy, content: Cheffy.membersOnlyMessage, kind: .gated)
        case .apiRejected(let code, _) where code == nil:
            // The bare 403 (and a defensive 200-with-ok:false). Not a flat
            // denial: a pantry outage is the same 403. The server's message
            // ("… available to Cook+ members.") is deliberately not shown —
            // it reads as the denial this bubble must not be.
            return Message(
                id: id, role: .cheffy, content: Cheffy.unavailableMessage, kind: .error,
                expression: .concerned
            )
        case .apiRejected(_, let message):
            return Message(
                id: id, role: .cheffy, content: message ?? Cheffy.networkErrorMessage, kind: .error,
                expression: .concerned, statusLine: Cheffy.pickLine(Cheffy.errorLines)
            )
        case .notSignedIn:
            return Message(
                id: id, role: .cheffy, content: Cheffy.signatureRejectedMessage, kind: .error,
                expression: .concerned, statusLine: Cheffy.pickLine(Cheffy.errorLines)
            )
        case .rateLimited(let retryAfter):
            var line = Cheffy.rateLimitedMessage
            if let retryAfter, retryAfter > 0 {
                line += " Try again in about \(Cheffy.formatRetryAfter(retryAfter))."
            }
            return Message(id: id, role: .cheffy, content: line, kind: .error, expression: .concerned)
        case .requestFailed(let status, _):
            return Message(
                id: id, role: .cheffy, content: "Cheffy could not respond (\(status)).", kind: .error,
                expression: .concerned, statusLine: Cheffy.pickLine(Cheffy.errorLines)
            )
        case .transport(let message) where message == ZapCookingApi.timedOutTransportMessage:
            return Message(id: id, role: .cheffy, content: Cheffy.timedOutMessage, kind: .error, expression: .concerned)
        case .transport, .encoding, .decoding, .badRequest:
            return Message(
                id: id, role: .cheffy, content: Cheffy.networkErrorMessage, kind: .error,
                expression: .concerned, statusLine: Cheffy.pickLine(Cheffy.errorLines)
            )
        }
    }

    func startOver() {
        if loading { return }
        thread = []
        lastTurn = nil
    }

    private func mintId() -> Int {
        nextId += 1
        return nextId
    }
}
