import Foundation
import Testing
@testable import wisp

/// Poll arrivals have to reach the effect path, not just appear in the
/// effect table.
///
/// `NotificationEffectPlan` gained `.pollVote` and `.pollEnded`, and the
/// unit tests on that plan passed — but neither kind reached `fireEffects`
/// in the live repository: votes return early from `ingest`'s
/// consolidated-row branch, and `insertPollEnded` never called it at all.
/// Both stayed silent. This drives the real methods instead of the plan.
///
/// One test, not several: `effectProbe` lives on a singleton, so two tests
/// installing their own probe race and whichever loses reads an empty log.
@MainActor
struct PollNotificationEffectsTests {

    @Test func bothPollPaths_reachTheEffectPath() {
        let repo = NotificationRepository.shared
        let me = String(repeating: "a", count: 64)
        let votedPollId = "poll_voted_" + UUID().uuidString
        let endedPoll = event(kind: 1068, pubkey: me, id: "poll_ended_" + UUID().uuidString)

        let savedSelfIds = repo.selfEventIds
        var seen: [FlatNotificationItem] = []
        repo.effectProbe = { seen.append($0) }
        defer {
            repo.effectProbe = nil
            repo.selfEventIds = savedSelfIds
        }

        repo.bind(activePubkey: me)
        // `classifyPollVote` only notifies for polls we authored.
        repo.selfEventIds = [votedPollId]

        let vote = event(
            kind: Nip88.kindPollResponse,
            pubkey: "voter_" + UUID().uuidString,
            tags: [["e", votedPollId], ["p", me], ["response", "opt1"]]
        )
        _ = repo.ingest(vote, relayUrl: "", persist: false)
        _ = repo.insertPollEnded(pollEvent: endedPoll,
                                 endedAt: Int(Date().timeIntervalSince1970))

        #expect(seen.contains { $0.kind == .pollVote && $0.referencedEventId == votedPollId },
                "a poll vote must reach the effect path")
        #expect(seen.contains { $0.kind == .pollEnded && $0.referencedEventId == endedPoll.id },
                "a poll end must reach the effect path")
    }

    // Duplicate suppression is deliberately not asserted here. Both paths
    // guard it — the vote branch only fires `if changed`, and
    // `insertPollEnded` returns early on `insertSeen` — but `seenEventIds`
    // is a bounded FIFO on a singleton, so under parallel suites a fixture
    // can be evicted between two calls and the "the second one is a
    // duplicate" premise stops holding. A test that alternates is worse
    // than no test.

    private func event(
        kind: Int, pubkey: String, tags: [[String]] = [], id: String = UUID().uuidString
    ) -> NostrEvent {
        NostrEvent(id: id, pubkey: pubkey, kind: kind,
                   createdAt: Int(Date().timeIntervalSince1970),
                   tags: tags, content: "", sig: "")
    }
}
