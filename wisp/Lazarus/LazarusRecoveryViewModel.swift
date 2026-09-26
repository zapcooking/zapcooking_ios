import Foundation
import Observation

/// The version under review and everything the review screen asks before a
/// restore. Confirmations reset whenever the comparison changes and after
/// every restore attempt, so nothing given for one attempt carries into the next.
struct LazarusReview {
    let candidateId: String
    /// What the delta is computed against: the scan's current version, or
    /// the newer one the pre-sign re-read found.
    var reviewedCurrent: NostrEvent?
    /// The list changed after the scan; the delta now compares against the newer version.
    var changedSinceReview = false
    var delta: LazarusDelta?
    /// Kind 0 only: every field and tag the restore would change.
    var profileChanges: [LazarusProfileChange]?
    /// The first tap of a shrinking restore arms the separate confirmation.
    var shrinkArmed = false
    /// Meaningful-empty kinds: the answer to the intent question.
    var intentConfirmed = false
    /// The explicit override after a failed retry. Never pre-selected.
    var overrideConfirmed = false
    /// Re-reads that got no write relay to answer, for this comparison.
    var unconfirmedAttempts = 0
    var status: Status = .ready
    /// The per-relay outcome when no write relay accepted the restore.
    var rejectedReport: LazarusPublishReport?

    enum Status: Equatable {
        case ready
        case working
        /// No write relay answered the re-read: nothing was signed.
        case unconfirmed
        case failed(String)
    }

    /// The override is offered only after a retry of the re-read failed too.
    var overrideOffered: Bool { unconfirmedAttempts >= 2 }
}

struct LazarusPublishedSummary {
    let profile: LazarusKindProfile
    let report: LazarusPublishReport
}

/// Settings → Data Recovery. Scans only on an explicit tap, shows every
/// version found, recommends only after a clobber, shows the delta before
/// any publish, and restores through the account's own key on an explicit
/// tap. Never automatic.
@Observable
@MainActor
final class LazarusRecoveryViewModel {

    enum Phase: Equatable {
        case idle
        case scanning
        case done
        /// No relay answered the scan and nothing arrived: an error with a
        /// retry, never "no versions found".
        case failed
    }

    let keypair: Keypair
    /// Local keys only in this app: a view-only account can scan its history
    /// but not restore it.
    let canSign: Bool
    let kinds = LazarusRegistry.ordered

    private(set) var selectedKind: Int
    private(set) var phase: Phase = .idle
    private(set) var scan: LazarusScanResult?
    private(set) var plan: LazarusScanPlan?
    /// Decrypted private items (NIP-51), keyed by event id.
    private(set) var privateTags: [String: [[String]]] = [:]
    /// Versions whose encrypted content didn't decrypt to a tag list.
    private(set) var undecryptable: Set<String> = []

    var sortOrder: LazarusSortOrder = .date
    var showPastEmpty = false
    var expandedGroups: Set<String> = []
    var showRelayOutcomes = false

    private(set) var loadingOlder = false
    /// Relays whose last page of older versions failed or timed out.
    private(set) var olderPageFailures = 0
    private(set) var retrying = false

    /// The version being reviewed; drives the pushed review screen.
    var reviewingId: String? {
        didSet { if reviewingId == nil, review?.status != .working { review = nil } }
    }
    private(set) var review: LazarusReview?
    private(set) var published: LazarusPublishedSummary?

    @ObservationIgnored private let io: any LazarusRelayIO
    @ObservationIgnored private let engine: LazarusScanEngine
    @ObservationIgnored private let decryptor: LazarusDecryptor?
    @ObservationIgnored private var publisher: LazarusPublisher!
    /// Bumped by every new scan and by `close()`, so late results are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var bestEffort: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    /// `io` and `customizePublisher` are test seams; production opens its own
    /// scan-scoped sockets and uses the app's stores.
    init(
        keypair: Keypair,
        initialKind: Int = 3,
        io: (any LazarusRelayIO)? = nil,
        sets: LazarusRelaySets = .production,
        customizePublisher: ((inout LazarusPublisher.Environment) -> Void)? = nil
    ) {
        self.keypair = keypair
        // A watch-only account's keypair carries an empty privkey, so the
        // 32-byte key check already answers false for it.
        let canSign = LazarusPublisher.canSign(keypair)
        self.canSign = canSign
        self.selectedKind = LazarusRegistry.profile(for: initialKind) != nil ? initialKind : 3
        let io = io ?? LazarusRelayClient(authSigner: canSign ? LazarusRelayClient.authSigner(for: keypair) : nil)
        self.io = io
        self.engine = LazarusScanEngine(io: io, sets: sets)
        self.decryptor = canSign ? LazarusDecryptor(keypair: keypair) : nil
        var environment = LazarusPublisher.Environment.production(engine: engine) { [weak self] event, relays in
            self?.startBestEffort(event, relays)
        }
        customizePublisher?(&environment)
        self.publisher = LazarusPublisher(env: environment)
    }

    var pubkey: String { keypair.pubkey }
    var profile: LazarusKindProfile { LazarusRegistry.profile(for: selectedKind) ?? kinds[0] }
    var standIns: [String] { engine.sets.standIns }
    var isBusy: Bool { phase == .scanning || review?.status == .working }

    // MARK: - Kind and scan

    func selectKind(_ kind: Int) {
        guard kind != selectedKind, !isBusy, LazarusRegistry.profile(for: kind) != nil else { return }
        selectedKind = kind
        generation += 1
        resetResults()
        phase = .idle
    }

    /// Scan relay history for the selected kind. Only ever on an explicit tap.
    func startScan() {
        guard !closed, !isBusy else { return }
        generation += 1
        let token = generation
        let profile = self.profile
        let pubkey = self.pubkey
        let engine = self.engine
        let decryptor = self.decryptor
        let appCopy = LazarusLocalCopies.relayList(pubkey: pubkey, standIns: engine.sets.standIns)
        resetResults()
        phase = .scanning
        track(Task {
            let plan = await engine.plan(pubkey: pubkey, appCopy: appCopy)
            let page = await engine.fetch(kind: profile.kind, pubkey: pubkey, relays: plan.relays)
            let prepared = await Task.detached(priority: .userInitiated) {
                let decrypted = Self.decrypt(page.tagged.map(\.event), with: decryptor, profile: profile, known: [:], failed: [])
                let result = Lazarus.scanResult(
                    profile, page: page, writeRelays: plan.write, relayList: plan.user.status,
                    privateTags: decrypted.tags
                )
                return (decrypted, result)
            }.value
            guard token == self.generation else { return }
            self.plan = plan
            self.privateTags = prepared.0.tags
            self.undecryptable = prepared.0.failed
            self.scan = prepared.1
            self.phase = Lazarus.isFailedScan(page) ? .failed : .done
        })
    }

    /// Page further back on the relays whose last answer filled a page.
    func loadOlder() {
        guard let scan, !scan.olderCursors.isEmpty, !loadingOlder, !closed else { return }
        loadingOlder = true
        let token = generation
        let profile = self.profile
        let cursors = scan.olderCursors
        let relays = cursors.keys.sorted()
        track(Task {
            let page = await engine.fetch(kind: profile.kind, pubkey: pubkey, relays: relays, cursors: cursors)
            await self.merge(page, token: token) { current, tags in
                Lazarus.mergeOlder(profile, current, page: page, privateTags: tags)
            }
            guard token == self.generation else { return }
            self.olderPageFailures = relays.filter { page.outcomes[$0] != .answered }.count
            self.loadingOlder = false
        })
    }

    /// Relays that failed or timed out, which the user can retry without
    /// repeating the whole scan.
    var unreachableRelays: [String] {
        guard let scan, let outcomes = scan.relayOutcomes else { return [] }
        return scan.queriedRelays.filter { outcomes[$0] != .answered }
    }

    func retryUnreachable() {
        let relays = unreachableRelays
        guard let plan, !relays.isEmpty, !retrying, !isBusy, !closed else { return }
        retrying = true
        let token = generation
        let profile = self.profile
        track(Task {
            let page = await engine.fetch(kind: profile.kind, pubkey: pubkey, relays: relays)
            await self.merge(page, token: token) { current, tags in
                Lazarus.mergeRetry(profile, current, page: page, writeRelays: plan.write, privateTags: tags)
            }
            guard token == self.generation else { return }
            self.retrying = false
            self.refreshReviewComparison()
        })
    }

    /// Decrypt a fetched page's new versions off the main actor, then merge
    /// it into the latest scan.
    private func merge(
        _ page: LazarusFetchPage,
        token: Int,
        _ combine: @escaping @Sendable (LazarusScanResult, [String: [[String]]]) -> LazarusScanResult
    ) async {
        let decryptor = self.decryptor
        let profile = self.profile
        let known = privateTags
        let failed = undecryptable
        let decrypted = await Task.detached(priority: .userInitiated) {
            Self.decrypt(page.tagged.map(\.event), with: decryptor, profile: profile, known: known, failed: failed)
        }.value
        guard token == generation, let current = scan else { return }
        let tags = privateTags.merging(decrypted.tags) { old, _ in old }
        privateTags = tags
        undecryptable.formUnion(decrypted.failed)
        scan = combine(current, tags)
    }

    /// Decrypt every encrypted version not tried yet. With a local key this
    /// is plain compute (no signer prompts), so every version is decrypted
    /// and ranking uses exact counts wherever it can, as the spec requires.
    nonisolated private static func decrypt(
        _ events: [NostrEvent],
        with decryptor: LazarusDecryptor?,
        profile: LazarusKindProfile,
        known: [String: [[String]]],
        failed: Set<String>
    ) -> (tags: [String: [[String]]], failed: Set<String>) {
        guard let decryptor, profile.privateItemTypes != nil else { return ([:], []) }
        var tags: [String: [[String]]] = [:]
        var newlyFailed = Set<String>()
        for event in events where LazarusPrivateItems.encryption(of: event.content) != nil {
            guard known[event.id] == nil, tags[event.id] == nil,
                  !failed.contains(event.id), !newlyFailed.contains(event.id) else { continue }
            if let decrypted = decryptor.privateTags(of: event) {
                tags[event.id] = decrypted
            } else {
                newlyFailed.insert(event.id)
            }
        }
        return (tags, newlyFailed)
    }

    // MARK: - List

    var listItems: [LazarusListItem] {
        guard let scan else { return [] }
        if sortOrder == .size && profile.ranking == .count {
            // The optional size order: flat, largest first, newer first on ties.
            return Lazarus.sorted(scan.candidates, by: .size)
                .filter { showPastEmpty || !Lazarus.isPastEmptyVersion($0, profile: profile) }
                .map { .version($0) }
        }
        return Lazarus.group(scan, profile: profile, hidePastEmpty: !showPastEmpty)
    }

    var pastEmptyCount: Int {
        scan?.candidates.filter { Lazarus.isPastEmptyVersion($0, profile: profile) }.count ?? 0
    }

    var answeredRelayCount: Int {
        scan?.relayOutcomes?.values.filter { $0 == .answered }.count ?? 0
    }

    func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
    }

    /// Review is offered for every version but the current one, and never for
    /// a past empty version: a clobbered state can't be put back by accident.
    func canReview(_ candidate: LazarusCandidate) -> Bool {
        !candidate.isCurrent && !Lazarus.isPastEmptyVersion(candidate, profile: profile)
    }

    // MARK: - Review

    func openReview(_ candidate: LazarusCandidate) {
        guard let scan, canReview(candidate), !isBusy else { return }
        published = nil
        review = LazarusReview(candidateId: candidate.id, reviewedCurrent: scan.current?.event)
        refreshReviewComparison()
        reviewingId = candidate.id
    }

    var reviewCandidate: LazarusCandidate? {
        guard let id = review?.candidateId else { return nil }
        return scan?.candidates.first { $0.id == id }
    }

    /// Where the restore would go: the write relays it's judged on, and the
    /// best-effort extras.
    var reviewTargets: (judged: [String], extra: [String])? {
        guard let candidate = reviewCandidate, let plan, let scan else { return nil }
        return Lazarus.publishRelays(
            currentWrite: plan.write, answeredRelays: answeredRelays(of: scan),
            restoring: candidate.event, standIns: standIns
        )
    }

    private func answeredRelays(of scan: LazarusScanResult) -> [String] {
        let answered = scan.queriedRelays.filter { scan.relayOutcomes?[$0] == .answered }
        return answered + scan.respondingRelays
    }

    private func refreshReviewComparison() {
        guard var review, let candidate = reviewCandidate else { return }
        if candidate.event.kind == 0 {
            review.profileChanges = Lazarus.profileChanges(chosen: candidate.event, current: review.reviewedCurrent)
            review.delta = nil
        } else {
            review.delta = Lazarus.delta(
                chosen: candidate.event, current: review.reviewedCurrent, privateTags: privateTags
            )
            review.profileChanges = nil
        }
        self.review = review
    }

    func armShrinkConfirmation(_ armed: Bool) {
        review?.shrinkArmed = armed
    }

    func setIntentConfirmed(_ value: Bool) {
        review?.intentConfirmed = value
    }

    func setOverrideConfirmed(_ value: Bool) {
        guard review?.overrideOffered == true else { return }
        review?.overrideConfirmed = value
    }

    /// Restore the version under review. The override applies only when it
    /// was offered (a retry of the re-read failed) and explicitly confirmed,
    /// and it is cleared for the next attempt either way.
    func restore(override: Bool = false) {
        guard canSign, !closed, var review, review.status != .working,
              let candidate = reviewCandidate, let plan, let scan else { return }
        let allowUnconfirmed = override && review.overrideOffered && review.overrideConfirmed
        review.status = .working
        review.overrideConfirmed = false
        review.rejectedReport = nil
        self.review = review
        let token = generation
        let request = LazarusPublisher.Request(
            chosen: candidate.event,
            reviewedCurrent: review.reviewedCurrent,
            keypair: keypair,
            writeRelays: plan.write,
            answeredRelays: answeredRelays(of: scan),
            standIns: standIns,
            privateTags: privateTags[candidate.id],
            allowUnconfirmed: allowUnconfirmed
        )
        let publisher = self.publisher!
        let profile = self.profile
        track(Task {
            let outcome = await publisher.restore(request)
            guard token == self.generation, self.review?.candidateId == candidate.id else { return }
            await self.handle(outcome, profile: profile, token: token)
        })
    }

    private func handle(_ outcome: LazarusRestoreOutcome, profile: LazarusKindProfile, token: Int) async {
        guard var review else { return }
        review.shrinkArmed = false
        switch outcome {
        case .published(let report):
            published = LazarusPublishedSummary(profile: profile, report: report)
            self.review = nil
            reviewingId = nil
        case .changed(let newer, let answers):
            // The newer version becomes current. A relay's copy joins the
            // list (everything found is shown); this device's copy is only a
            // comparison base.
            if !LazarusLocalCopies.isLocalCopy(newer) {
                let tagged = answers.filter { answer in answer.events.contains { $0.id == newer.id } }
                    .map { LazarusTaggedEvent(event: newer, relayUrl: $0.relay) }
                let decryptor = self.decryptor
                let decrypted = await Task.detached(priority: .userInitiated) {
                    Self.decrypt([newer], with: decryptor, profile: profile, known: [:], failed: [])
                }.value
                guard token == generation, self.review?.candidateId == review.candidateId,
                      let scan = self.scan else { return }
                privateTags.merge(decrypted.tags) { old, _ in old }
                undecryptable.formUnion(decrypted.failed)
                self.scan = Lazarus.merge(profile, scan, adding: tagged, privateTags: privateTags)
            }
            review.reviewedCurrent = newer
            review.changedSinceReview = true
            review.intentConfirmed = false
            review.overrideConfirmed = false
            review.unconfirmedAttempts = 0
            review.status = .ready
            self.review = review
            refreshReviewComparison()
        case .unconfirmed:
            review.unconfirmedAttempts += 1
            review.status = .unconfirmed
            self.review = review
        case .failed(let failure):
            review.status = .failed(Self.message(for: failure))
            if case .notAccepted(let report) = failure { review.rejectedReport = report }
            self.review = review
        }
    }

    private static func message(for failure: LazarusRestoreFailure) -> String {
        switch failure {
        case .cannotSign:
            return "This account is view-only, so it can scan its history but not restore it."
        case .wrongAccount:
            return "The active account changed, so nothing was restored. Switch back to this account to restore its list."
        case .noWriteRelays:
            return "Your relay list couldn't be fetched, so there are no write relays to publish to. Scan again when your connection is back."
        case .signFailed:
            return "Signing failed, so nothing was published."
        case .notAccepted:
            return "None of your write relays accepted the restore, so it didn't take effect. Nothing changed on your write relays."
        }
    }

    // MARK: - Lifecycle

    func dismissPublished() {
        published = nil
    }

    /// The screen went away: drop late results and release every socket once
    /// the best-effort copies of a restore have gone out.
    func close() {
        guard !closed else { return }
        closed = true
        generation += 1
        for task in tasks { task.cancel() }
        tasks = []
        let io = self.io
        let pending = bestEffort
        Task.detached {
            if let pending { await pending.value }
            await io.closeAll()
        }
    }

    private func track(_ task: Task<Void, Never>) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
    }

    private func startBestEffort(_ event: NostrEvent, _ relays: [String]) {
        let engine = self.engine
        let previous = bestEffort
        bestEffort = Task {
            if let previous { await previous.value }
            _ = await engine.publish(event, to: relays)
        }
    }

    private func resetResults() {
        scan = nil
        plan = nil
        privateTags = [:]
        undecryptable = []
        sortOrder = .date
        showPastEmpty = false
        expandedGroups = []
        showRelayOutcomes = false
        loadingOlder = false
        olderPageFailures = 0
        retrying = false
        review = nil
        reviewingId = nil
        published = nil
    }
}
