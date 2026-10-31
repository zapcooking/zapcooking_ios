import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// State machine for the NIP-46 login screen.
///
/// Two paths share one screen:
///   1. **Bunker** — user pastes a `bunker://` URI obtained from their signer
///      (Amber, Primal). We perform `connect` + `get_public_key` and finish.
///   2. **Nostrconnect** — we generate an ephemeral `nostrconnect://` URI and
///      a QR code; the user scans it into their signer, or opens it in a
///      signer app on this device. We listen on relays for the signer's
///      `connect` response, then `get_public_key`.
@MainActor
@Observable
final class Nip46LoginViewModel {

    enum Mode: String, CaseIterable, Identifiable {
        case nostrconnect
        case bunker
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nostrconnect: return "Connect"
            case .bunker: return "Bunker link"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case connecting(String)         // human-readable progress
        case awaitingApproval           // nostrconnect URI shown
        case error(String)
        case connected(pubkey: String)
    }

    /// Recorded with the account this screen saves (the tap that opened it
    /// was the agreement — see `PendingAgreement`).
    let acceptance: TermsAcceptance

    var mode: Mode = .nostrconnect
    var bunkerURIInput: String = ""
    var status: Status = .idle

    /// nostrconnect URI we display as a QR code while waiting for the signer.
    /// Cleared when the handshake finishes or aborts.
    var pendingURI: String?

    private var pendingHandshake: Nip46Manager.NostrConnectPending?
    private var handshakeTask: Task<Void, Never>?

    init(acceptance: TermsAcceptance, initialBunkerURI: String? = nil) {
        self.acceptance = acceptance
        if let initialBunkerURI {
            mode = .bunker
            bunkerURIInput = initialBunkerURI
        }
    }

    var isWorking: Bool {
        if case .connecting = status { return true }
        if case .awaitingApproval = status { return true }
        return false
    }

    var displayError: String? {
        if case .error(let s) = status { return s } else { return nil }
    }

    // MARK: - Bunker

    /// Submit the pasted bunker URI. Triggers `connect` + `get_public_key`
    /// against the signer; on success, persists the session, marks the
    /// active account as remote, and sets `status = .connected(pubkey:)`.
    func submitBunker() async {
        let trimmed = bunkerURIInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.bunkerInputProblem(trimmed) {
            status = .error(problem)
            return
        }
        status = .connecting("Approve the connection in your signer app…")
        do {
            let keypair = try await Self.logIn(bunkerURI: trimmed, acceptance: acceptance)
            status = .connected(pubkey: keypair.pubkey)
        } catch {
            status = .error(Self.message(for: error))
        }
    }

    // MARK: - Nostrconnect

    /// Generate the URI and start listening. The view should display
    /// `pendingURI` as a QR + copy button while `isWorking` is true.
    func startNostrConnect() {
        cancelPendingHandshake()
        do {
            let pending = try Nip46Manager.shared.prepareNostrConnect()
            self.pendingHandshake = pending
            self.pendingURI = pending.uri
            self.status = .awaitingApproval

            handshakeTask = Task { [weak self] in
                guard let self else { return }
                await self.runHandshake(pending: pending)
            }
        } catch {
            status = .error(Self.message(for: error))
        }
    }

    private func runHandshake(pending: Nip46Manager.NostrConnectPending) async {
        do {
            let userPubkey = try await Nip46Manager.shared.awaitNostrConnectHandshake(pending)
            // The handshake task may have been cancelled (e.g. user backed out).
            if Task.isCancelled { return }
            NostrKey.saveRemote(pubkey: userPubkey, acceptance: acceptance)
            status = .connected(pubkey: userPubkey)
            pendingURI = nil
            pendingHandshake = nil
        } catch {
            if Task.isCancelled { return }
            status = .error(Self.message(for: error))
            pendingURI = nil
            pendingHandshake = nil
        }
    }

    /// Cancel any in-flight handshake (e.g. user dismisses the sheet).
    func cancelPendingHandshake() {
        handshakeTask?.cancel()
        handshakeTask = nil
        pendingHandshake = nil
        pendingURI = nil
    }

    // MARK: - Misc

    func copyURIToPasteboard() {
        guard let uri = pendingURI else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = uri
        #endif
    }

    /// Hand the pending `nostrconnect://` URI to a signer app on this device
    /// (iOS routes the scheme to whichever installed app claims it). The
    /// handshake listener keeps running while the user approves there.
    /// Returns false when no installed app handles the link.
    func openInSignerApp() async -> Bool {
        #if canImport(UIKit)
        guard let uri = pendingURI, let url = URL(string: uri) else { return false }
        return await UIApplication.shared.open(url)
        #else
        return false
        #endif
    }

    // MARK: - Shared with the login sheets

    /// True for anything the login field should route here instead of the
    /// nsec parser.
    static func isSignerURI(_ input: String) -> Bool {
        let lower = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("bunker://") || lower.hasPrefix("nostrconnect://")
    }

    /// Why `input` can't be used as a bunker link, or nil if it can.
    static func bunkerInputProblem(_ input: String) -> String? {
        let lower = input.lowercased()
        if lower.hasPrefix("nostrconnect://") {
            // A nostrconnect:// link is made BY a client FOR a signer — it
            // carries the other app's key, not a way to reach a signer.
            return "That's a nostrconnect:// link, which goes into a signer app, not here. Paste the bunker:// link from your signer, or use Connect to show a code your signer can scan."
        }
        guard let parsed = Nip46.parseBunker(input) else {
            return "That bunker link isn't valid. It should look like bunker://<key>?relay=wss://…"
        }
        if parsed.relays.isEmpty {
            return "That bunker link has no relay. Copy it again from your signer — it should include relay=wss://…"
        }
        return nil
    }

    /// Connect a `bunker://` link and save the account. Used by this screen
    /// and by the login sheets when a bunker link is pasted or scanned
    /// straight into their key field.
    static func logIn(bunkerURI: String, acceptance: TermsAcceptance) async throws -> Keypair {
        let pubkey = try await Nip46Manager.shared.connectBunker(uri: bunkerURI)
        NostrKey.saveRemote(pubkey: pubkey, acceptance: acceptance)
        return Keypair(privkey: "", pubkey: pubkey)
    }

    static func message(for error: Error) -> String {
        if let e = error as? Nip46.NipError { return e.description }
        if let e = error as? Signer.SignerError { return e.description }
        return error.localizedDescription
    }
}
