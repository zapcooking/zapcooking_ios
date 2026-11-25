import Foundation

/// What the composer needs to schedule a post: sign it for its publish time,
/// then hand the signed event to the scheduler. Two steps, so the composer
/// can keep the signed event and send the *same one* again after a failed
/// request (the contract: never re-sign to retry, or the post is scheduled
/// twice). `ScheduleSubmitter` is the real thing; tests stand in a fake.
nonisolated protocol ScheduleSubmitting: Sendable {
    func sign(kind: Int, tags: [[String]], content: String, publishAt: Int,
              keypair: Keypair) async -> Result<NostrEvent, ScheduleFailure>
    func send(_ event: NostrEvent, keypair: Keypair) async -> Result<ScheduleReceipt, ScheduleFailure>
}

/// Schedules through `ScheduleApi` with the author's own write relays.
nonisolated struct ScheduleSubmitter: ScheduleSubmitting {
    let session: URLSession
    /// The author's NIP-65 write relays, in their kind-10002 order, `[]` when
    /// unknown. Unfiltered: `ScheduleApi.pickRelays` does that.
    let writeRelays: @Sendable (String) async -> [String]

    /// The app's own: the general HTTP client, and the *write* half of the
    /// account's relay list. Not `getWriteRelays`, which falls back to read
    /// relays, and not `RelayScoreBoard`, which ranks the relays the
    /// account's follows write to.
    @MainActor static var live: ScheduleSubmitter {
        ScheduleSubmitter(session: HttpClientFactory.generalClient) { pubkey in
            await RelayListRepository.shared.readWriteSplit(pubkey).write
        }
    }

    func sign(kind: Int, tags: [[String]], content: String, publishAt: Int,
              keypair: Keypair) async -> Result<NostrEvent, ScheduleFailure> {
        await ScheduleApi.sign(
            kind: kind, tags: tags, content: content, publishAt: publishAt,
            signer: AccountScheduleSigner(keypair: keypair)
        )
    }

    func send(_ event: NostrEvent, keypair: Keypair) async -> Result<ScheduleReceipt, ScheduleFailure> {
        // Recipients' inbox relays are deliberately not added for a reply or
        // a quote (the contract's known limitation): the four places go to
        // the author's own relays.
        let relays = await writeRelays(event.pubkey)
        return await ScheduleApi.schedule(
            event: event, relayMode: .all, relays: relays,
            signer: LocalNip98Signer(keypair: keypair), session: session
        )
    }
}

extension ScheduleFailure {

    /// Plain wording for a person. The contract's suggested copy
    /// (`docs/schedule-contract.md`), as web's `scheduleErrorCopy` has it.
    /// Total over the cases, so a new one cannot ship without copy.
    nonisolated var message: String {
        switch self {
        case .authFailed:
            return "Couldn't verify your account. Check your device's date and time, then try again."
        case .badRequest, .badRelayMode:
            return "Couldn't schedule this post. Please try again."
        case .badRelays:
            return "Couldn't schedule this post to your relays. Please try again."
        case .badSignature:
            return "Your signer returned a post we couldn't verify. Please try again."
        case .pubkeyMismatch:
            return "This post was signed by a different account. Sign in again and retry."
        case .badKind:
            return "This kind of post can't be scheduled."
        case .kindNotAllowedForRelayMode:
            return "This kind of post can't be scheduled to the members' relay."
        case .badPublishTime:
            return "Pick a time at least 5 minutes from now and within 90 days."
        case .tooLarge:
            return "This post is too long to schedule."
        case .pollClosesBeforePublish:
            return "This poll would close before it's posted. Move the closing time later."
        case .alreadyScheduled:
            return "This post was already scheduled and then cancelled or failed, so it won't be sent. Schedule it again to retry."
        case .quotaExceeded:
            return "You have 50 posts scheduled, the most allowed. Cancel one, or wait for one to go out."
        case .rateLimited:
            return "You've scheduled a lot in the last hour. Try again later."
        case .badStatus:
            return "Couldn't load your scheduled posts. Please try again."
        case .notFound:
            return "This scheduled post no longer exists."
        case .notCancellable(let status):
            switch status {
            case .publishing: return "This post is being published right now and can't be cancelled."
            case .sent: return "This post has already been published."
            case .failed: return "This post already failed and won't be sent."
            default: return "This post can't be cancelled any more."
            }
        case .notConfigured:
            return "Scheduling is unavailable right now."
        case .internal, .unknown:
            return "Something went wrong. Please try again."
        case .signedOut:
            return "Sign in to schedule posts."
        case .signFailed:
            return "Your signer didn't sign the post. Check your signer and try again."
        case .signerChangedEvent:
            return "Your signer changed this post's time, so it can't be scheduled. Try a different signer, or post it now instead."
        case .network:
            return "Couldn't reach Zap Cooking. Check your connection and try again."
        }
    }

    /// After this failure, is the signed event still the one to send on the
    /// next try? True when the request failed around the event (it may even
    /// have been stored and the answer lost); false when the server judged
    /// the event itself, so a fresh one has to be signed.
    nonisolated var keepsSignedEvent: Bool {
        switch self {
        case .network, .internal, .unknown, .authFailed, .notConfigured,
             .rateLimited, .quotaExceeded, .badRelays, .signFailed, .signedOut:
            return true
        case .badRequest, .badRelayMode, .badSignature, .pubkeyMismatch, .badKind,
             .kindNotAllowedForRelayMode, .badPublishTime, .tooLarge, .pollClosesBeforePublish,
             .alreadyScheduled, .badStatus, .notFound, .notCancellable, .signerChangedEvent:
            return false
        }
    }
}

nonisolated enum ScheduleRetry {
    /// Is `event` the post the composer is about to schedule again? Same
    /// author, kind, text and time, and the same tags. A poll's option ids
    /// are minted fresh each time its tags are built, so they are left out
    /// of the comparison: the same poll must not be signed, and scheduled,
    /// a second time because its ids rolled.
    static func isSamePost(_ event: NostrEvent, kind: Int, tags: [[String]], content: String,
                           publishAt: Int, pubkey: String) -> Bool {
        event.pubkey.lowercased() == pubkey.lowercased()
            && event.kind == kind
            && event.createdAt == publishAt
            && event.content == content
            && comparable(event.tags, kind: kind) == comparable(tags, kind: kind)
    }

    private static func comparable(_ tags: [[String]], kind: Int) -> [[String]] {
        guard kind == Nip88.kindPoll else { return tags }
        return tags.map { tag in
            guard tag.count >= 3, tag[0] == "option" else { return tag }
            var copy = tag
            copy.remove(at: 1)
            return copy
        }
    }
}
