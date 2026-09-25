import Foundation

/// `CaseIterable` so the effect-table tests can assert every kind is
/// covered — a new kind that nobody wired into `NotificationEffectPlan`
/// should fail a test, not fall silently through the switch.
enum NotificationKind: String, Hashable, CaseIterable {
    case reply
    case reaction
    case repost
    case zap
    case quote
    case mention
    case dm
    case pollVote
    case pollEnded
}

struct FlatNotificationItem: Identifiable, Hashable {
    let id: String
    let kind: NotificationKind
    /// Mutable so a consolidated poll row can re-point at its most-recent
    /// voter as new votes fold in. Required (no default) in the memberwise init.
    var actorPubkey: String
    let referencedEventId: String
    /// Mutable so a consolidated poll row floats to its newest vote's time.
    var timestamp: Int
    var emoji: String? = nil
    var emojiUrl: String? = nil
    var zapSats: Int64 = 0
    var zapMessage: String = ""
    var isPrivateZap: Bool = false
    /// True when this row was materialized from a gift-wrapped rumor (private
    /// reply or private reaction). Drives the lock-icon overlay in
    /// `NotificationRowView`. Independent of `isPrivateZap`, which only flags
    /// zap receipts routed through DM relays.
    var isPrivate: Bool = false
    var quoteEventId: String? = nil
    var actorEventId: String? = nil
    var dmPeerPubkey: String? = nil
    var dmConversationKey: String? = nil
    var dmUnread: Int = 0
    var relayHints: [String] = []
    /// For `.reply` rows: whether `referencedEventId` (the immediate parent the
    /// actor replied to) is one of my own notes. Drives the caption — "replying
    /// to your note" vs "replying in your thread" when the parent is someone
    /// else's reply nested under my note. Defaults `true` (direct-reply wording).
    var replyTargetIsMine: Bool = true
    /// For `.reply` rows created from a kind-1111 comment: the immediate
    /// parent's kind, read from the lowercase `k` tag. Nil for kind-1 replies
    /// and for comments whose parent is an external identifier.
    ///
    /// Carried so the caption can say "replying to your comment" rather than
    /// "replying to your note" — the distinction Sidecar draws
    /// (dmnyc/sidecar#326), and one you cannot recover later because the
    /// parent event may not be in the cache. It deliberately does NOT change
    /// the row's `kind`: a comment is still a reply for filtering, counting
    /// and sound purposes, only the wording differs.
    var parentKind: Int? = nil
    /// Option ids chosen by a kind-1018 poll voter (for `.pollVote` items).
    /// On a consolidated poll row this holds the most-recent voter's choice,
    /// used for the collapsed-row hint.
    var voteOptionIds: [String] = []
    /// Consolidated poll-vote state: voterPubkey -> their latest vote.
    /// Latest-wins by timestamp so a re-vote updates rather than stacks.
    /// Empty on every non-poll item. A `.pollVote` row aggregates every
    /// voter on one poll here instead of spawning a row per vote — that keeps
    /// a busy poll from evicting itself out of the capped flat buffer.
    var pollVotes: [String: PollVoteRecord] = [:]
    /// Index of the option zapped on a kind-6969 zap poll (annotates `.zap` items
    /// whose target is one of our zap polls).
    var zapPollOptionIndex: Int? = nil
    /// Additional zaps from the same actor against the same referenced event,
    /// folded into this row so a spammer can't push everything else off-screen.
    /// Populated by the view model at display time; always empty on freshly
    /// classified items in the repository.
    var mergedZaps: [FlatNotificationItem] = []

    /// Total sats across the primary zap and every merged duplicate. Used by
    /// the row + bolt-icon label so the displayed amount reflects the full
    /// contribution from this actor on this note.
    var totalZapSats: Int64 {
        mergedZaps.reduce(zapSats) { $0 + $1.zapSats }
    }

    /// Distinct voters folded into a consolidated poll row.
    var pollVoterCount: Int { pollVotes.count }

    /// optionId -> number of voters currently picking it (consolidated rows).
    /// Reflects latest-wins state, so a voter who changed their pick only
    /// counts toward their current choice.
    var pollVoteCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for record in pollVotes.values {
            for id in record.optionIds { counts[id, default: 0] += 1 }
        }
        return counts
    }
}

/// One voter's latest choice on a poll, tracked inside a consolidated
/// `.pollVote` notification row.
struct PollVoteRecord: Hashable {
    let timestamp: Int
    let optionIds: [String]
}

struct NotificationSummary: Hashable {
    var replyCount: Int = 0
    var reactionCount: Int = 0
    var zapCount: Int = 0
    var zapSats: Int64 = 0
    var repostCount: Int = 0
    var mentionCount: Int = 0
    var quoteCount: Int = 0
    var dmCount: Int = 0
    var pollVoteCount: Int = 0
    var pollEndedCount: Int = 0
}

/// Set-based filter: each type independently toggleable. Mirrors Android.
extension FlatNotificationItem {
    /// Caption under a reply row.
    ///
    /// Three cases, because a NIP-22 comment can answer a note or another
    /// comment and calling both "your note" is wrong: in a mixed thread the
    /// same person may own the root note and a comment three levels down.
    /// Sidecar labels these separately for the same reason.
    var replyCaption: String {
        guard replyTargetIsMine else { return "replying in your thread" }
        return parentKind == Nip22.kindComment ? "replying to your comment" : "replying to your note"
    }
}

enum NotificationFilter: String, CaseIterable, Hashable {
    case replies
    case reactions
    case zaps
    case reposts
    case mentions
    case dms
    case votes

    /// Map a `NotificationKind` to its filter bucket.
    /// Quote+mention collapse to .mentions; pollVote and pollEnded → .votes.
    static func bucket(for kind: NotificationKind) -> NotificationFilter {
        switch kind {
        case .reply:               .replies
        case .reaction:            .reactions
        case .zap:                 .zaps
        case .repost:              .reposts
        case .quote, .mention:     .mentions
        case .pollVote, .pollEnded: .votes
        case .dm:                  .dms
        }
    }

    var label: String {
        switch self {
        case .replies:   "Replies"
        case .reactions: "Reactions"
        case .zaps:      "Zaps"
        case .reposts:   "Reposts"
        case .mentions:  "Mentions"
        case .votes:     "Votes"
        case .dms:       "DMs"
        }
    }
}
