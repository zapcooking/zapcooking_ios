import Foundation

/// What a restore's publish did, relay by relay.
nonisolated struct LazarusPublishReport: Sendable {
    let event: NostrEvent
    /// The write relays success is judged on.
    let judgedOn: [String]
    let outcomes: [String: LazarusPublishOutcome]
    /// Other relays that answered the scan: they get the restore as a best
    /// effort that doesn't affect the result.
    let bestEffort: [String]

    var accepted: [String] { judgedOn.filter { outcomes[$0] == .accepted } }
    var notAccepted: [(relay: String, outcome: LazarusPublishOutcome)] {
        judgedOn.compactMap { relay in
            let outcome = outcomes[relay] ?? .failed
            return outcome == .accepted ? nil : (relay, outcome)
        }
    }
    /// A restore succeeds when at least one write relay accepted it.
    var succeeded: Bool { !accepted.isEmpty }
}

nonisolated enum LazarusRestoreFailure: Sendable {
    /// A view-only account: it can scan its history but not restore it.
    case cannotSign
    /// The version isn't this account's, or the active account changed.
    case wrongAccount
    /// No write relays to publish to or judge success on (the relay list
    /// couldn't be fetched).
    case noWriteRelays
    case signFailed
    /// No write relay accepted the event.
    case notAccepted(LazarusPublishReport)
}

nonisolated enum LazarusRestoreOutcome: Sendable {
    case published(LazarusPublishReport)
    /// A version newer than the reviewed one appeared: it becomes current,
    /// the delta is recomputed against it, and the user is asked again.
    case changed(current: NostrEvent, answers: [LazarusReadAnswer])
    /// No write relay answered the re-read: nothing was signed.
    case unconfirmed
    case failed(LazarusRestoreFailure)
}

/// Lazarus recovery publish: the one write path. Everything else in the
/// feature scans, ranks and drafts; this turns a draft into a signed event
/// on an explicit tap, then updates the app's own copy.
///
/// Spec safeguards ("Recover"), in order:
///  - the signing account must be the list's author, checked before the
///    re-read, again right before signing, and on the signed event;
///  - re-read the current version from this device's copy and every write
///    relay; a strictly newer version returns `.changed` so the UI
///    recomputes the delta and asks again; no write relay answering returns
///    `.unconfirmed` and nothing is signed, unless the user explicitly
///    overrides after a failed retry (`allowUnconfirmed`, never remembered);
///  - the event is dated `max(now, current.created_at + 1)`, current being
///    the version the delta was computed against;
///  - success is judged on the user's write relays (for a relay list, the
///    ones the restored version names); the other relays that answered the
///    scan get it as a best effort once it succeeded;
///  - the app's own copy is updated, so the next edit doesn't rebuild from
///    the clobbered version.
@MainActor
struct LazarusPublisher {

    struct Environment {
        /// Every write relay's answer to the re-read.
        var readCurrent: (_ kind: Int, _ pubkey: String, _ writeRelays: [String]) async -> [LazarusReadAnswer]
        /// This device's copy of the list (`LazarusLocalCopies.snapshot`).
        var localCopy: (_ kind: Int, _ pubkey: String) -> NostrEvent?
        /// The account active in the app right now.
        var activePubkey: () -> String?
        var now: () -> Int
        var sign: (_ keypair: Keypair, _ draft: LazarusRecoveryDraft) async throws -> NostrEvent
        var publish: (_ event: NostrEvent, _ relays: [String]) async -> [String: LazarusPublishOutcome]
        /// Fire-and-forget copies to the other relays that answered the scan.
        var publishBestEffort: (_ event: NostrEvent, _ relays: [String]) -> Void
        /// Update the app's own copy with the restored version.
        var adopt: (_ signed: NostrEvent, _ privateTags: [[String]]?) async -> Void

        static func production(engine: LazarusScanEngine, bestEffort: @escaping (NostrEvent, [String]) -> Void) -> Environment {
            Environment(
                readCurrent: { kind, pubkey, relays in
                    await engine.readCurrent(kind: kind, pubkey: pubkey, writeRelays: relays)
                },
                localCopy: { kind, pubkey in LazarusLocalCopies.snapshot(kind: kind, pubkey: pubkey) },
                activePubkey: { NostrKey.load()?.pubkey },
                now: { NostrClock.now() },
                sign: { keypair, draft in
                    try await Signer.sign(
                        keypair: keypair, kind: draft.kind, tags: draft.tags,
                        content: draft.content, createdAt: draft.createdAt
                    )
                },
                publish: { event, relays in await engine.publish(event, to: relays) },
                publishBestEffort: bestEffort,
                adopt: { signed, privateTags in await LazarusLocalCopies.adopt(signed, privateTags: privateTags) }
            )
        }
    }

    struct Request {
        /// The chosen version, verbatim.
        let chosen: NostrEvent
        /// The version the reviewed delta was computed against: the scan's
        /// current, or the newer one a `.changed` result returned.
        let reviewedCurrent: NostrEvent?
        let keypair: Keypair
        /// The user's current write relays (or the stand-ins, labeled as such).
        let writeRelays: [String]
        /// Relays that answered the scan or returned versions before failing.
        let answeredRelays: [String]
        let standIns: [String]
        /// The chosen version's decrypted private items, for the local copy.
        let privateTags: [[String]]?
        /// The explicit override after a failed retry.
        let allowUnconfirmed: Bool
    }

    let env: Environment

    /// Whether this key can sign at all: local keys only in this app, so a
    /// view-only account (empty private key) can't.
    nonisolated static func canSign(_ keypair: Keypair) -> Bool {
        Hex.decode(keypair.privkey)?.count == 32
    }

    func restore(_ request: Request) async -> LazarusRestoreOutcome {
        let pubkey = request.keypair.pubkey
        guard Self.canSign(request.keypair) else { return .failed(.cannotSign) }
        guard request.chosen.pubkey == pubkey, env.activePubkey() == pubkey else {
            return .failed(.wrongAccount)
        }
        // Same checks the scan applies before anything becomes a candidate.
        // The scan path always runs them, but this is the signing surface:
        // whatever reaches here must be a real, signed version of this
        // account's list, or restoring it would republish forged content
        // under the user's own signature.
        guard Lazarus.isVersion(request.chosen, kind: request.chosen.kind, pubkey: pubkey) else {
            return .failed(.wrongAccount)
        }
        let targets = Lazarus.publishRelays(
            currentWrite: request.writeRelays,
            answeredRelays: request.answeredRelays,
            restoring: request.chosen,
            standIns: request.standIns
        )
        guard !targets.judged.isEmpty else { return .failed(.noWriteRelays) }

        // Re-read immediately before signing: an edit from another device or
        // client since the review would otherwise be dropped silently.
        let answers = await env.readCurrent(request.chosen.kind, pubkey, request.writeRelays)
        let local = env.localCopy(request.chosen.kind, pubkey)
        switch Lazarus.checkCurrent(reviewed: request.reviewedCurrent, local: local, answers: answers) {
        case .changed(let newer):
            return .changed(current: newer, answers: answers)
        case .unconfirmed where !request.allowUnconfirmed:
            return .unconfirmed
        case .unconfirmed, .proceed:
            break
        }

        // The screen went away (or the account switched) while the re-read
        // ran: stop before signing. Nothing has been published yet.
        guard !Task.isCancelled, env.activePubkey() == pubkey else { return .failed(.wrongAccount) }

        // Dated after the version the delta was computed against, never an
        // older copy the re-read found.
        let draft = Lazarus.draft(chosen: request.chosen, current: request.reviewedCurrent, now: env.now())
        guard env.activePubkey() == pubkey else { return .failed(.wrongAccount) }
        let signed: NostrEvent
        do {
            signed = try await env.sign(request.keypair, draft)
        } catch {
            return .failed(.signFailed)
        }
        // Restoring one account's list as another's is forbidden, including
        // when the account changed while signing.
        guard signed.pubkey == pubkey, env.activePubkey() == pubkey else { return .failed(.wrongAccount) }
        guard signed.kind == draft.kind, signed.createdAt == draft.createdAt,
              Lazarus.hasValidSignature(signed) else { return .failed(.signFailed) }

        let outcomes = await env.publish(signed, targets.judged)
        let report = LazarusPublishReport(
            event: signed, judgedOn: targets.judged, outcomes: outcomes, bestEffort: targets.extra
        )
        guard report.succeeded else { return .failed(.notAccepted(report)) }

        // Past this point the restore took effect on at least one write
        // relay, so the local copy is updated even if the screen is gone:
        // the next edit here must not rebuild from the clobbered version.
        if !targets.extra.isEmpty { env.publishBestEffort(signed, targets.extra) }
        await env.adopt(signed, request.privateTags)
        return .published(report)
    }
}
