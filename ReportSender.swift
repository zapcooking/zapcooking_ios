import Foundation
import Observation

/// What a NIP-56 report submission did, and therefore what the reporter is told.
///
/// `hidesReportedContent` lives on the outcome rather than at the call site so
/// the two can't drift. The reported content disappearing is what the reporter
/// reads as confirmation, so it may only disappear once a relay has taken the
/// event — hiding on a failure also removes the only thing left to retry from.
/// Port of Android `ReportOutcome`.
enum ReportOutcome: Equatable, Sendable {
    /// A relay accepted the signed event. Not a claim that a moderator has seen it.
    case sent
    /// Signing or the send failed. The reporter can try again.
    case failed
    /// The account holds no signing key. Distinct from `failed`: retrying as-is
    /// will not help.
    case needsKey

    var hidesReportedContent: Bool { self == .sent }

    static func of(hasSigner: Bool, relayAccepted: Bool) -> ReportOutcome {
        if !hasSigner { return .needsKey }
        if !relayAccepted { return .failed }
        return .sent
    }
}

/// Something the user can report: a note/recipe event, or a profile alone.
struct ReportTarget: Identifiable, Equatable, Hashable {
    var id: String
    var reportedPubkey: String
    var eventId: String?
    var coordinate: String?
    var groupId: String?

    static func event(_ event: NostrEvent, groupId: String? = nil) -> ReportTarget {
        let coordinate: String?
        if event.kind == 30023 || event.kind == 30024 {
            coordinate = RecipeRepository.coordinate(event)
        } else {
            coordinate = nil
        }
        return ReportTarget(
            id: "e:\(event.id)",
            reportedPubkey: event.pubkey,
            eventId: event.id,
            coordinate: coordinate,
            groupId: groupId
        )
    }

    static func profile(pubkey: String) -> ReportTarget {
        ReportTarget(
            id: "p:\(pubkey)",
            reportedPubkey: pubkey,
            eventId: nil,
            coordinate: nil,
            groupId: nil
        )
    }
}

/// Sheet host for a report in flight. One `@Observable` at `MainView` so
/// feed cards, recipe tiles, and profiles can present without anchoring a
/// sheet to a recyclable row (same reason `ComposePresenter` exists).
@Observable
@MainActor
final class ReportPresenter {
    static let shared = ReportPresenter()
    var target: ReportTarget?
    private init() {}

    func present(_ target: ReportTarget) {
        self.target = target
    }
}

/// Publishes a signed kind-1984 to the reporter's write relays union
/// `RelayDefaults.defaults` (not the indexer set — that hung ~1030s in 3.1).
@MainActor
enum ReportSender {

    /// Relays a live-write gate must target. Production and the opt-in live
    /// test share this so we cannot "pass" against a different set.
    static let publishRelays = RelayDefaults.defaults

    static func submit(
        target: ReportTarget,
        category: Nip56.ReportCategory,
        reason: String,
        keypair: Keypair?,
        extraRecipients: [String] = Nip56.pantryModAdmins,
        relays: [String]? = nil,
        publish: ((NostrEvent, [String]) async -> [String])? = nil
    ) async -> ReportOutcome {
        guard let keypair, !keypair.privkey.isEmpty,
              !NostrKey.isWatchOnly(pubkey: keypair.pubkey) else {
            return .needsKey
        }

        let tags = Nip56.buildReportTags(
            reportedPubkey: target.reportedPubkey,
            category: category,
            eventId: target.eventId,
            groupId: target.groupId,
            recipients: extraRecipients
        )
        let content = Nip56.reportContent(category: category, reason: reason)

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: Nip56.kindReport,
                tags: tags,
                content: content
            )
        } catch {
            return .failed
        }

        var dest = Set<String>()
        if let relays {
            dest.formUnion(relays)
        } else {
            dest.formUnion(Self.publishRelays)
            let writes = await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
            dest.formUnion(writes)
        }
        guard !dest.isEmpty else { return .failed }

        let accepted: [String]
        if let publish {
            accepted = await publish(event, Array(dest))
        } else {
            accepted = await RelayPool.publish(event: event, to: Array(dest), timeout: 8)
        }

        let outcome = ReportOutcome.of(hasSigner: true, relayAccepted: !accepted.isEmpty)
        if outcome.hidesReportedContent {
            ReportedContent.shared.hide(target)
        }
        return outcome
    }
}
