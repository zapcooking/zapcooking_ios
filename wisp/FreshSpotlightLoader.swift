import Foundation

/// Keeps one topic spotlight ready for the Fresh list, ported from web
/// `specialsLoader.ts` (spotlight half) and `specialsFlow.ts` (ZapCooking
/// e4a71d6b). The list (S3) takes the ready card for a slot, and the loader
/// starts on the next one at once.
///
/// A spotlight is built from the relay's anonymous topic preview
/// (`FreshRelayClient.topicPreview`): REQ and CLOSE on Fresh's own socket,
/// no login, no signer. Topics come from `FreshTopicList` (NIP-11). With no
/// topic list there are no spotlights, and nothing is shown as an error.
///
/// One build tries up to `maxTopicTries` topics, picked by
/// `FreshSpecials.pickTopic`:
/// - **answered:** the reader's filters, then `spotlightPosts`. Too few posts
///   (thin) marks the topic used for the session, and the next one is tried.
///   Enough posts makes the card, and its topic is used too.
/// - **`invalid:`** (the relay doesn't know the slug): used for the session,
///   next topic (Seth, 2026-11-11). ≠ web, which returns null and can pick
///   the same dead slug again.
/// - **refused** (`auth-required:`, or `restricted:`): the preview hold
///   starts, 60 s doubling per refusal in a row up to 10 min (web
///   `previewHoldLeftMs`). Nothing is marked used; the build stops.
/// - **failed or timed out:** the build stops; nothing is marked.
///
/// After a build that left nothing ready, the next one is scheduled: when
/// the hold ends (plus 50 ms), else after `emptyRetrySeconds` (web
/// `SpecialsFlow`). When every topic is used the type is out for the
/// session and nothing more is asked. While `enabled` is false (the flag)
/// nothing is asked at all.
///
/// The session (used topics, last parent group) lives as long as the
/// loader: one per Fresh view model, kept across refreshes (web
/// `SpecialsSession` per tab).
@MainActor
final class FreshSpotlightLoader {
    struct Dependencies {
        /// The relay's topic preview for a slug.
        var preview: (String) async -> FreshAnswer
        /// The topic groups; [] = no list (no spotlights).
        var topics: () async -> [FreshTopicGroup]
        /// The reader's filters (mutes, blocks, reports, hellthreads, deletions).
        var accept: (NostrEvent) -> Bool
        /// Posts this account has been shown in cards (`FreshSpecialsStore`).
        var shown: () -> Set<String>
        /// Posts already on screen: the feed and the other cards.
        var exclude: () -> Set<String>
        /// Slug → when last shown (`FreshSpecialsStore`).
        var topicHistory: () -> [String: Int]
        var rng: FreshRandom = { Double.random(in: 0..<1) }
        /// Seconds on any monotonic-enough clock (the hold).
        var clock: () -> TimeInterval = { Date().timeIntervalSince1970 }
        /// Runs `work` after `seconds`; returns a cancel. Tests fire it by hand.
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = FreshSpotlightLoader.taskTimer
        /// A card became ready, or a build ended without one (the list
        /// decides its slots again).
        var onChange: () -> Void = {}
        var enabled: () -> Bool = { FeatureFlags.freshSpecialsEnabled }
    }

    /// The ready card (`FreshSpecial.spotlight`), or nil.
    private(set) var ready: FreshSpecial?
    /// Every topic is used for this session: no more spotlights.
    private(set) var isOut = false
    /// A build is running.
    private(set) var isBuilding = false
    /// `kick()` was called and its build hasn't started yet.
    private var isStarting = false
    /// Topics used this session (shown, thin, or `invalid:`).
    private(set) var usedTopics: Set<String> = []
    /// The parent group of the last spotlight made ready.
    private(set) var lastParent: String?

    private var deps: Dependencies
    private var previewRefusedAt: TimeInterval?
    private var previewRefusals = 0
    private var cancelRetry: (() -> Void)?
    private var disposed = false

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// A retry is scheduled (tests).
    var hasPendingRetry: Bool { cancelRetry != nil }

    // MARK: - The rotation's question

    /// May the rotation give this slot to a spotlight? Near the screen
    /// (`strict` false) only when one is ready. Far below (`strict` true)
    /// also while a build is running, so the slot waits for it. Otherwise
    /// the turn goes to a recipe-box card (Seth, 2026-11-11): with nothing
    /// that can fill it, `FreshRotation.choose` lets recipe repeat.
    func isAvailable(strict: Bool) -> Bool {
        guard deps.enabled(), !isOut else { return false }
        return ready != nil || (strict && (isBuilding || isStarting))
    }

    // MARK: - Preview hold

    /// Seconds until a refused preview may be asked for again (0 = now).
    func previewHoldLeft() -> TimeInterval {
        guard let previewRefusedAt else { return 0 }
        let wait = min(
            Double(FreshSpecialsConfig.previewRetrySeconds) * pow(2, Double(max(0, previewRefusals - 1))),
            Double(FreshSpecialsConfig.previewRetryMaxSeconds)
        )
        return max(0, previewRefusedAt + wait - deps.clock())
    }

    /// A refused preview: hold, with a growing wait. Refusals during one
    /// hold count once.
    private func refusedPreview() {
        if previewRefusedAt != nil && previewHoldLeft() > 0 { return }
        previewRefusedAt = deps.clock()
        previewRefusals += 1
    }

    private func previewServed() {
        previewRefusedAt = nil
        previewRefusals = 0
    }

    /// The relay refused the preview: `auth-required:` (`.floor`) or
    /// `restricted:`. Never "no content".
    nonisolated static func isRefusal(_ outcome: FreshOutcome) -> Bool {
        switch outcome {
        case .floor: return true
        case .failed(let reason): return reason.hasPrefix("restricted:")
        case .answered, .invalid, .timedOut: return false
        }
    }

    // MARK: - Building

    /// One spotlight: up to `maxTopicTries` topics, or nil (see the type's
    /// notes for what each answer does).
    func build() async -> FreshSpecial? {
        guard deps.enabled(), !disposed, !isOut, previewHoldLeft() == 0 else { return nil }
        let groups = await deps.topics()
        guard !disposed, !groups.isEmpty else { return nil }
        if FreshSpecials.pickTopic(groups, used: usedTopics, lastParent: nil, history: [:]) == nil {
            isOut = true
            return nil
        }
        var tried: Set<String> = []
        for _ in 0..<FreshSpecialsConfig.maxTopicTries {
            guard let topic = FreshSpecials.pickTopic(
                groups, used: usedTopics, tried: tried, lastParent: lastParent,
                history: deps.topicHistory(), rng: deps.rng
            ) else { return nil }
            tried.insert(topic.slug)
            let answer = await deps.preview(topic.slug)
            guard !disposed, deps.enabled() else { return nil }
            if Self.isRefusal(answer.outcome) {
                refusedPreview()
                return nil
            }
            switch answer.outcome {
            case .invalid:
                usedTopics.insert(topic.slug)
                continue
            case .failed, .timedOut, .floor:
                return nil
            case .answered:
                break
            }
            previewServed()
            usedTopics.insert(topic.slug)
            guard let posts = FreshSpecials.spotlightPosts(
                answer.events.filter(deps.accept), shown: deps.shown(), exclude: deps.exclude()
            ) else { continue }  // thin for this reader
            return .spotlight(topic, posts: posts)
        }
        return nil
    }

    /// Keep one spotlight ready. A build that leaves nothing ready is tried
    /// again later: when the hold ends, else after the empty retry. Out of
    /// topics, disabled or disposed: no retry.
    func prepare() async {
        guard deps.enabled(), !disposed, ready == nil, !isBuilding, !isOut else { return }
        cancelRetry?()
        cancelRetry = nil
        guard previewHoldLeft() == 0 else {
            scheduleRetry()
            return
        }
        isBuilding = true
        let built = await build()
        isBuilding = false
        guard !disposed else { return }
        if case .spotlight(let topic, _) = built {
            ready = built
            lastParent = topic.parent
        }
        deps.onChange()
        if ready == nil { scheduleRetry() }
    }

    /// Start `prepare()` without waiting (the list's call).
    func kick() {
        guard deps.enabled(), !disposed, !isOut else { return }
        isStarting = true
        Task {
            self.isStarting = false
            await self.prepare()
        }
    }

    /// The ready card, if its posts are still all eligible (≠ web: a post
    /// that reached the feed since, through the pill or paging, or that the
    /// reader hid, isn't shown twice; the card is dropped and its topic stays
    /// used). The next build starts at once.
    func take() -> FreshSpecial? {
        guard let card = ready else { return nil }
        ready = nil
        defer { kick() }
        guard case .spotlight(_, let posts) = card else { return nil }
        let shown = deps.shown()
        let exclude = deps.exclude()
        let stillGood = posts.allSatisfy { deps.accept($0) && !shown.contains($0.id) && !exclude.contains($0.id) }
        return stillGood ? card : nil
    }

    /// Leaving for good (the view model goes away): no more timers or builds.
    func dispose() {
        disposed = true
        cancelRetry?()
        cancelRetry = nil
    }

    private func scheduleRetry() {
        guard !disposed, !isOut, deps.enabled() else { return }
        cancelRetry?()
        let hold = previewHoldLeft()
        let delay = hold > 0 ? hold + 0.05 : Double(FreshSpecialsConfig.emptyRetrySeconds)
        cancelRetry = deps.schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelRetry = nil
            self.kick()
        }
    }

    /// The live timer: a task that sleeps, then runs `work` on the main actor.
    static func taskTimer(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            work()
        }
        return { task.cancel() }
    }
}
