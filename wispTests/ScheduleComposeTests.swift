import Foundation
import Testing
@testable import wisp

// The composer's scheduling path. Publish is driven only with a schedule time
// set and a fake `ScheduleSubmitting`, so nothing here signs for real relays,
// reaches the network, or publishes anything. The private-reply rule is
// tested on `publishRoute`, which decides without sending.

/// Records what the composer asks for and answers from a script.
nonisolated final class FakeScheduleSubmitter: ScheduleSubmitting, @unchecked Sendable {
    struct SignCall: Sendable {
        let kind: Int
        let tags: [[String]]
        let content: String
        let publishAt: Int
        let pubkey: String
    }

    private let lock = NSLock()
    private let privkey: Data
    private let pubkey: String
    private var _signCalls: [SignCall] = []
    private var _sentIds: [String] = []
    private var signFailure: ScheduleFailure?
    private var sendFailures: [ScheduleFailure?]

    init(privkey: Data, pubkey: String, signFailure: ScheduleFailure? = nil, sendFailures: [ScheduleFailure?] = []) {
        self.privkey = privkey
        self.pubkey = pubkey
        self.signFailure = signFailure
        self.sendFailures = sendFailures
    }

    var signCalls: [SignCall] { lock.withLock { _signCalls } }
    var sentIds: [String] { lock.withLock { _sentIds } }

    func sign(kind: Int, tags: [[String]], content: String, publishAt: Int,
              keypair: Keypair) async -> Result<NostrEvent, ScheduleFailure> {
        let failure: ScheduleFailure? = lock.withLock {
            _signCalls.append(SignCall(kind: kind, tags: tags, content: content,
                                       publishAt: publishAt, pubkey: pubkey))
            return signFailure
        }
        if let failure { return .failure(failure) }
        do {
            return .success(try NostrEvent.sign(privkey32: privkey, pubkey: pubkey, kind: kind,
                                                createdAt: publishAt, tags: tags, content: content))
        } catch {
            return .failure(.signFailed)
        }
    }

    func send(_ event: NostrEvent, keypair: Keypair) async -> Result<ScheduleReceipt, ScheduleFailure> {
        let failure: ScheduleFailure? = lock.withLock {
            _sentIds.append(event.id)
            return sendFailures.isEmpty ? nil : sendFailures.removeFirst()
        }
        if let failure { return .failure(failure) }
        return .success(ScheduleReceipt(id: event.id, publishAt: event.createdAt, relayMode: .all,
                                        relays: [], status: .pending, alreadyScheduled: false))
    }
}

@MainActor
@Suite(.serialized)
struct ScheduleComposeTests {

    @MainActor private struct Fixture {
        let privkey: Data
        let keypair: Keypair
        var autosaveKey: String { "compose_autosave_new_\(keypair.pubkey)" }

        init() throws {
            privkey = Schnorr.randomPrivkey()
            let pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: privkey))
            keypair = Keypair(privkey: Hex.encode(privkey), pubkey: pubkey)
        }

        func submitter(signFailure: ScheduleFailure? = nil,
                       sendFailures: [ScheduleFailure?] = []) -> FakeScheduleSubmitter {
            FakeScheduleSubmitter(privkey: privkey, pubkey: keypair.pubkey,
                                  signFailure: signFailure, sendFailures: sendFailures)
        }

        func cleanUp() { UserDefaults.standard.removeObject(forKey: autosaveKey) }
    }

    /// A composer with text and a schedule time an hour out, wired to a fake.
    private func scheduledComposer(_ fixture: Fixture, _ submitter: FakeScheduleSubmitter,
                                   text: String = "Dinner at eight") -> (ComposeViewModel, Int) {
        let vm = ComposeViewModel(keypair: fixture.keypair)
        vm.scheduleSubmitter = submitter
        vm.updateContent(text)
        let publishAt = ((NostrClock.now() + 3_600) / 60) * 60
        vm.setSchedule(Date(timeIntervalSince1970: TimeInterval(publishAt)))
        return (vm, publishAt)
    }

    /// Tap Publish and wait for the pipeline to finish. Only ever called with
    /// a schedule time set, so the route is the fake and nothing is posted.
    private func publish(_ vm: ComposeViewModel) async throws {
        try #require(vm.scheduleAt != nil, "these tests only publish through the scheduler fake")
        if case .schedule = vm.publishRoute {} else {
            Issue.record("route is \(vm.publishRoute), not the scheduler")
            return
        }
        vm.publish()
        for _ in 0..<400 where vm.isPublishing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!vm.isPublishing)
    }

    private func reply(to keypair: Keypair) throws -> ComposeMode {
        let parentKey = Schnorr.randomPrivkey()
        let parentPub = Hex.encode(try Schnorr.xonlyPubkey(privkey32: parentKey))
        let parent = try NostrEvent.sign(privkey32: parentKey, pubkey: parentPub, kind: 1,
                                         createdAt: NostrClock.now() - 60, tags: [], content: "parent")
        return .reply(parent: parent, root: nil)
    }

    // MARK: - Scheduling through the API

    @Test func schedulesTheSignedPost_andFinishesLikeAPublish() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter()
        let (vm, publishAt) = scheduledComposer(fixture, submitter)
        vm.writeLocalAutosave()
        #expect(UserDefaults.standard.dictionary(forKey: fixture.autosaveKey) != nil)

        try await publish(vm)

        let call = try #require(submitter.signCalls.first)
        #expect(submitter.signCalls.count == 1)
        #expect(call.kind == 1)
        #expect(call.content == "Dinner at eight")
        #expect(call.publishAt == publishAt)
        // Signed once, sent once, and the composer reports that event.
        #expect(submitter.sentIds.count == 1)
        #expect(vm.publishedEventId == submitter.sentIds.first)
        #expect(vm.lastError == nil)
        // As the old path did: the autosave bucket is emptied.
        #expect(UserDefaults.standard.dictionary(forKey: fixture.autosaveKey) == nil)
    }

    /// A scheduled post has not been posted, and the toast must not say so.
    @Test func theToastSaysScheduledForTheTime_neverPosted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter()
        let (vm, publishAt) = scheduledComposer(fixture, submitter)
        let date = Date(timeIntervalSince1970: TimeInterval(publishAt))

        try await publish(vm)

        // Read after success, as the view does when `publishedEventId` lands.
        #expect(vm.publishedEventId != nil)
        #expect(vm.publishToastMessage == "Scheduled for " + date.formatted(date: .abbreviated, time: .shortened))
        #expect(vm.publishToastMessage.hasPrefix("Scheduled for "))
        #expect(!vm.publishToastMessage.contains("Posted"))
    }

    @Test func theToastForEveryScheduledKindSaysScheduled() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let at = Date(timeIntervalSince1970: TimeInterval(NostrClock.now() + 3_600))

        let poll = ComposeViewModel(keypair: fixture.keypair)
        poll.pollEnabled = true
        poll.setSchedule(at)
        #expect(poll.publishToastMessage == ComposeViewModel.scheduledToastMessage(for: at))

        let scheduledReply = ComposeViewModel(keypair: fixture.keypair, mode: try reply(to: fixture.keypair))
        scheduledReply.setSchedule(at)
        #expect(scheduledReply.publishToastMessage == ComposeViewModel.scheduledToastMessage(for: at))
    }

    @Test func theToastForAPostSentNowIsUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let note = ComposeViewModel(keypair: fixture.keypair)
        #expect(note.publishToastMessage == "Posted")
        note.pollEnabled = true
        #expect(note.publishToastMessage == "Poll posted")
        let sentReply = ComposeViewModel(keypair: fixture.keypair, mode: try reply(to: fixture.keypair))
        #expect(sentReply.publishToastMessage == "Reply sent")
    }

    @Test(arguments: [
        ScheduleFailure.network, .internal, .unknown, .authFailed, .notConfigured, .rateLimited,
        .quotaExceeded, .badRelays, .badRequest, .badRelayMode, .badSignature, .pubkeyMismatch,
        .badKind, .kindNotAllowedForRelayMode, .badPublishTime, .tooLarge, .pollClosesBeforePublish,
        .alreadyScheduled(status: .cancelled), .alreadyScheduled(status: .failed), .signedOut, .signFailed,
    ])
    func aFailedRequestKeepsTheComposerOpen_withTheTextAndPlainCopy(_ failure: ScheduleFailure) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter(sendFailures: [failure])
        let (vm, publishAt) = scheduledComposer(fixture, submitter)

        try await publish(vm)

        // Not dismissed, nothing lost, and told why.
        #expect(vm.publishedEventId == nil)
        #expect(vm.content == "Dinner at eight")
        #expect(vm.scheduleAt == Date(timeIntervalSince1970: TimeInterval(publishAt)))
        #expect(vm.lastError == failure.message)
        #expect(vm.canPublish)
    }

    @Test(arguments: [ScheduleFailure.signedOut, .signFailed, .signerChangedEvent, .badPublishTime])
    func aFailedSignKeepsTheComposerOpen_andSendsNothing(_ failure: ScheduleFailure) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter(signFailure: failure)
        let (vm, _) = scheduledComposer(fixture, submitter)

        try await publish(vm)

        #expect(submitter.sentIds.isEmpty)
        #expect(vm.publishedEventId == nil)
        #expect(vm.content == "Dinner at eight")
        #expect(vm.lastError == failure.message)
    }

    /// The contract: never re-sign to retry, or the post is scheduled twice.
    @Test func retryingAfterALostRequestSendsTheSameSignedEvent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter(sendFailures: [.network, nil])
        let (vm, _) = scheduledComposer(fixture, submitter)

        try await publish(vm)
        #expect(vm.lastError == ScheduleFailure.network.message)
        try await publish(vm)

        #expect(submitter.signCalls.count == 1)
        #expect(submitter.sentIds.count == 2)
        #expect(Set(submitter.sentIds).count == 1)
        #expect(vm.publishedEventId == submitter.sentIds.first)
        #expect(vm.lastError == nil)
    }

    @Test func retryingAfterAnEditSignsTheNewText() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter(sendFailures: [.network, nil])
        let (vm, _) = scheduledComposer(fixture, submitter)

        try await publish(vm)
        vm.updateContent("Dinner at nine")
        try await publish(vm)

        #expect(submitter.signCalls.map(\.content) == ["Dinner at eight", "Dinner at nine"])
        #expect(Set(submitter.sentIds).count == 2)
        #expect(vm.publishedEventId == submitter.sentIds.last)
    }

    @Test func retryingAfterTheServerJudgedTheEventSignsAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter(sendFailures: [.alreadyScheduled(status: .cancelled), nil])
        let (vm, _) = scheduledComposer(fixture, submitter)

        try await publish(vm)
        try await publish(vm)

        #expect(submitter.signCalls.count == 2)
    }

    @Test func aRetriedPollIsNotSignedTwiceBecauseItsOptionIdsRolled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter(sendFailures: [.network, nil])
        let (vm, _) = scheduledComposer(fixture, submitter, text: "Brisket or ribs?")
        vm.pollEnabled = true
        vm.pollOptions = ["Brisket", "Ribs"]

        try await publish(vm)
        try await publish(vm)

        #expect(submitter.signCalls.count == 1)
        #expect(Set(submitter.sentIds).count == 1)
    }

    @Test func isSamePost_comparesEverythingButPollOptionIds() throws {
        let fixture = try Fixture()
        let pollTags = [["option", "abc123xyz", "Brisket"], ["option", "def456uvw", "Ribs"], ["polltype", "singlechoice"]]
        let poll = try NostrEvent.sign(privkey32: fixture.privkey, pubkey: fixture.keypair.pubkey,
                                       kind: 1068, createdAt: 1_900_000_000, tags: pollTags, content: "q")
        let rolled = [["option", "zzz999yyy", "Brisket"], ["option", "qqq888www", "Ribs"], ["polltype", "singlechoice"]]
        func same(kind: Int = 1068, tags: [[String]], content: String = "q", at: Int = 1_900_000_000,
                  pubkey: String? = nil) -> Bool {
            ScheduleRetry.isSamePost(poll, kind: kind, tags: tags, content: content, publishAt: at,
                                     pubkey: pubkey ?? fixture.keypair.pubkey)
        }
        #expect(same(tags: rolled))
        #expect(!same(tags: [["option", "zzz999yyy", "Pork"], ["option", "qqq888www", "Ribs"], ["polltype", "singlechoice"]]))
        #expect(!same(tags: rolled, content: "other"))
        #expect(!same(tags: rolled, at: 1_900_000_060))
        #expect(!same(tags: rolled, pubkey: String(repeating: "a", count: 64)))
        #expect(!same(kind: 1, tags: rolled))

        // A note's tags are compared whole.
        let note = try NostrEvent.sign(privkey32: fixture.privkey, pubkey: fixture.keypair.pubkey,
                                       kind: 1, createdAt: 1, tags: [["option", "a", "b"]], content: "n")
        #expect(!ScheduleRetry.isSamePost(note, kind: 1, tags: [["option", "c", "b"]], content: "n",
                                          publishAt: 1, pubkey: fixture.keypair.pubkey))
    }

    // MARK: - Private replies

    @Test func turningOnPrivateClearsASetSchedule_andSaysSo() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vm = ComposeViewModel(keypair: fixture.keypair, mode: try reply(to: fixture.keypair))
        vm.updateContent("see you there")
        vm.setSchedule(Date(timeIntervalSince1970: TimeInterval(NostrClock.now() + 3_600)))
        #expect(vm.scheduleEnabled)

        vm.togglePrivate()

        #expect(vm.isPrivate)
        #expect(vm.scheduleAt == nil)
        #expect(!vm.scheduleEnabled)
        #expect(vm.scheduleNotice == ComposeViewModel.scheduleClearedForPrivateNotice)
        #expect(vm.publishRoute == .privateReply)

        // Turning private off again does not bring the time back.
        vm.togglePrivate()
        #expect(vm.scheduleAt == nil)
        #expect(vm.publishRoute == .now)
    }

    @Test func turningOnPrivateWithNoScheduleSaysNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vm = ComposeViewModel(keypair: fixture.keypair, mode: try reply(to: fixture.keypair))
        vm.togglePrivate()
        #expect(vm.isPrivate)
        #expect(vm.scheduleNotice == nil)
    }

    @Test func aScheduleCannotBeSetWhilePrivate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vm = ComposeViewModel(keypair: fixture.keypair, mode: try reply(to: fixture.keypair))
        vm.togglePrivate()

        vm.setSchedule(Date(timeIntervalSince1970: TimeInterval(NostrClock.now() + 3_600)))

        #expect(vm.scheduleAt == nil)
        #expect(vm.publishRoute == .privateReply)
    }

    /// The backstop: whatever put a private reply and a schedule time in the
    /// same composer, Publish does not send the reply now.
    @Test func aPrivateReplyWithAScheduleTimeIsNeverSentImmediately() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vm = ComposeViewModel(keypair: fixture.keypair, mode: try reply(to: fixture.keypair))
        vm.updateContent("see you there")
        vm.isPrivate = true
        vm.scheduleAt = Date(timeIntervalSince1970: TimeInterval(NostrClock.now() + 3_600))

        #expect(vm.publishRoute == .blocked(ComposeViewModel.privateScheduleConflictMessage))
        #expect(vm.publishRoute != .privateReply)
    }

    @Test func routes_forTheOtherCases() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vm = ComposeViewModel(keypair: fixture.keypair)
        #expect(vm.publishRoute == .now)
        let at = NostrClock.now() + 3_600
        vm.setSchedule(Date(timeIntervalSince1970: TimeInterval(at)))
        #expect(vm.publishRoute == .schedule(at: at))

        // A public reply schedules like any note.
        let publicReply = ComposeViewModel(keypair: fixture.keypair, mode: try reply(to: fixture.keypair))
        publicReply.setSchedule(Date(timeIntervalSince1970: TimeInterval(at)))
        #expect(publicReply.publishRoute == .schedule(at: at))
    }

    // MARK: - A restored schedule time

    private func restore(_ fixture: Fixture, scheduleAt: Int) -> ComposeViewModel {
        UserDefaults.standard.set(
            ["content": "Sunday roast", "scheduleAt": TimeInterval(scheduleAt)],
            forKey: fixture.autosaveKey
        )
        return ComposeViewModel(keypair: fixture.keypair)
    }

    @Test(arguments: [-86_400, -1, 0, 60, 180])
    func aSavedTimeThatHasPassedOrIsTooCloseIsDropped_andTheComposerSaysSo(_ offset: Int) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let vm = restore(fixture, scheduleAt: NostrClock.now() + offset)

        #expect(vm.content == "Sunday roast")
        #expect(vm.scheduleAt == nil)
        #expect(vm.scheduleNotice == ComposeViewModel.scheduleTimePassedNotice)
        #expect(vm.publishRoute == .now)
    }

    @Test func aSavedTimeStillAheadIsKept_withNoNotice() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let at = NostrClock.now() + 3_600

        let vm = restore(fixture, scheduleAt: at)

        #expect(vm.scheduleAt == Date(timeIntervalSince1970: TimeInterval(at)))
        #expect(vm.scheduleNotice == nil)
    }

    @Test func pickingANewTimeClearsTheNotice() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vm = restore(fixture, scheduleAt: NostrClock.now() - 60)
        #expect(vm.scheduleNotice != nil)

        vm.setSchedule(Date(timeIntervalSince1970: TimeInterval(NostrClock.now() + 3_600)))

        #expect(vm.scheduleNotice == nil)
        #expect(vm.scheduleEnabled)
    }

    // MARK: - Polls

    private func tagValue(_ tags: [[String]], _ name: String) -> String? {
        tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
    }

    @Test(arguments: [PollDurationPreset.oneHour, .oneDay, .sevenDays])
    func aScheduledPollsPresetCountsFromThePublishTime(_ preset: PollDurationPreset) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter()
        let (vm, _) = scheduledComposer(fixture, submitter, text: "Brisket or ribs?")
        // Three days out: a preset stamped from "now" would already be closed.
        let publishAt = ((NostrClock.now() + 3 * 86_400) / 60) * 60
        vm.setSchedule(Date(timeIntervalSince1970: TimeInterval(publishAt)))
        vm.pollEnabled = true
        vm.pollOptions = ["Brisket", "Ribs"]
        // What the editor does when a chip is tapped: stamp now + preset.
        vm.pollDurationPreset = preset
        vm.setPollEndsAt(NostrClock.now() + Int(preset.seconds))

        #expect(vm.pollEndsAtForPublish == publishAt + Int(preset.seconds))
        #expect(!vm.pollClosesBeforeScheduledPublish)
        try await publish(vm)

        let call = try #require(submitter.signCalls.first)
        #expect(call.kind == Nip88.kindPoll)
        #expect(call.publishAt == publishAt)
        #expect(tagValue(call.tags, "endsAt") == String(publishAt + Int(preset.seconds)))
    }

    @Test func aScheduledZapPollsPresetCountsFromThePublishTime() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter()
        let (vm, publishAt) = scheduledComposer(fixture, submitter, text: "Brisket or ribs?")
        vm.pollEnabled = true
        vm.pollOptions = ["Brisket", "Ribs"]
        vm.toggleZapPoll()
        vm.pollDurationPreset = .sixHours
        vm.setPollEndsAt(NostrClock.now() + 6 * 3_600)

        try await publish(vm)

        let call = try #require(submitter.signCalls.first)
        #expect(call.kind == Nip69.kindZapPoll)
        #expect(tagValue(call.tags, "closed_at") == String(publishAt + 6 * 3_600))
    }

    @Test func aScheduledPollWithNoEndHasNoCloseTag() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter()
        let (vm, _) = scheduledComposer(fixture, submitter, text: "Brisket or ribs?")
        vm.pollEnabled = true
        vm.pollOptions = ["Brisket", "Ribs"]
        vm.pollDurationPreset = nil
        vm.pollDurationIsCustom = false
        vm.setPollEndsAt(nil)

        #expect(vm.pollEndsAtForPublish == nil)
        try await publish(vm)

        let call = try #require(submitter.signCalls.first)
        #expect(tagValue(call.tags, "endsAt") == nil)
    }

    @Test(arguments: [-3_600, 0, 60])
    func aCustomEndNotMoreThanAMinuteAfterPublishIsBlockedLocally(_ offset: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter()
        let (vm, publishAt) = scheduledComposer(fixture, submitter, text: "Brisket or ribs?")
        vm.pollEnabled = true
        vm.pollOptions = ["Brisket", "Ribs"]
        vm.pollDurationIsCustom = true
        vm.pollDurationPreset = nil
        vm.setPollEndsAt(publishAt + offset)

        #expect(vm.pollClosesBeforeScheduledPublish)
        #expect(vm.publishBlocker == "Move the poll's closing time later.")
        #expect(!vm.canPublish)

        // Even if Publish is reached, nothing is signed or sent.
        vm.publish()
        #expect(vm.lastError == ComposeViewModel.pollClosesBeforePublishMessage)
        #expect(!vm.isPublishing)
        #expect(submitter.signCalls.isEmpty)
        #expect(submitter.sentIds.isEmpty)
    }

    @Test func aCustomEndMoreThanAMinuteAfterPublishIsKeptAsPicked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitter = fixture.submitter()
        let (vm, publishAt) = scheduledComposer(fixture, submitter, text: "Brisket or ribs?")
        vm.pollEnabled = true
        vm.pollOptions = ["Brisket", "Ribs"]
        vm.pollDurationIsCustom = true
        vm.pollDurationPreset = nil
        vm.setPollEndsAt(publishAt + 61)

        #expect(!vm.pollClosesBeforeScheduledPublish)
        #expect(vm.canPublish)
        try await publish(vm)

        let call = try #require(submitter.signCalls.first)
        #expect(tagValue(call.tags, "endsAt") == String(publishAt + 61))
    }

    /// Posted now, a poll's end is what it always was: the editor's stamp.
    @Test func anUnscheduledPollKeepsTheEditorsStamp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let vm = ComposeViewModel(keypair: fixture.keypair)
        vm.pollEnabled = true
        vm.pollDurationPreset = .oneDay
        vm.setPollEndsAt(1_900_000_000)

        #expect(vm.pollEndsAtForPublish == 1_900_000_000)
        #expect(!vm.pollClosesBeforeScheduledPublish)
    }

    // MARK: - The picker's limits

    @Test func thePickerOffersFiveMinutesToNinetyDays_onWholeMinutes() {
        let now = 1_800_000_017
        let range = ScheduleSheet.allowedRange(now: now)
        let lower = Int(range.lowerBound.timeIntervalSince1970)
        let upper = Int(range.upperBound.timeIntervalSince1970)

        #expect(lower % 60 == 0)
        #expect(upper % 60 == 0)
        // The first minute at least 5 minutes off…
        #expect(lower >= now + 300)
        #expect(lower - 60 < now + 300)
        // …to the last minute under 90 days off.
        #expect(upper < now + 90 * 86_400)
        #expect(upper + 60 >= now + 90 * 86_400)
        // Everything on offer passes the check `ScheduleApi.sign` makes.
        #expect(lower > now + ScheduleApi.signMinLeadSeconds)
        #expect(upper < now + ScheduleApi.maxLeadSeconds)
    }

    @Test func thePickerOpensOnTheSetTime_orFifteenMinutesOut() {
        let now = 1_800_000_017
        let range = ScheduleSheet.allowedRange(now: now)
        let set = Date(timeIntervalSince1970: TimeInterval(now + 7_200))
        #expect(ScheduleSheet.initialSelection(set, now: now) == set)

        let fallback = ScheduleSheet.initialSelection(nil, now: now)
        #expect(range.contains(fallback))
        #expect(Int(fallback.timeIntervalSince1970) % 60 == 0)
        #expect(Int(fallback.timeIntervalSince1970) - now >= 900)
        #expect(Int(fallback.timeIntervalSince1970) - now < 960)

        // A set time that is no longer on offer is not where it opens.
        let passed = Date(timeIntervalSince1970: TimeInterval(now - 60))
        #expect(ScheduleSheet.initialSelection(passed, now: now) == fallback)
        let tooFar = Date(timeIntervalSince1970: TimeInterval(now + 91 * 86_400))
        #expect(ScheduleSheet.initialSelection(tooFar, now: now) == fallback)
    }

    @Test func aPickIsHandedBackOnTheMinute() {
        let picked = Date(timeIntervalSince1970: 1_800_000_037.6)
        #expect(ScheduleSheet.onTheMinute(picked) == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(Int(ScheduleSheet.onTheMinute(picked).timeIntervalSince1970) % 60 == 0)
    }

    // MARK: - Copy

    @Test func everyFailureHasPlainCopy_inTheContractsWords() {
        let all: [ScheduleFailure] = [
            .authFailed, .badRequest, .badRelayMode, .badRelays, .badSignature, .pubkeyMismatch, .badKind,
            .kindNotAllowedForRelayMode, .badPublishTime, .tooLarge, .pollClosesBeforePublish,
            .alreadyScheduled(status: .cancelled), .quotaExceeded, .rateLimited, .badStatus, .notFound,
            .notCancellable(status: nil), .notCancellable(status: .publishing), .notCancellable(status: .sent),
            .notCancellable(status: .failed), .notConfigured, .internal, .signedOut, .signFailed,
            .signerChangedEvent, .network, .unknown,
        ]
        for failure in all {
            #expect(!failure.message.isEmpty)
            // Plain: no code names, no relay talk.
            #expect(!failure.message.contains("_"))
            #expect(!failure.message.lowercased().contains("relay") || failure == .badRelays
                    || failure == .kindNotAllowedForRelayMode)
        }
        #expect(ScheduleFailure.authFailed.message
                == "Couldn't verify your account. Check your device's date and time, then try again.")
        #expect(ScheduleFailure.badPublishTime.message
                == "Pick a time at least 5 minutes from now and within 90 days.")
        #expect(ScheduleFailure.pollClosesBeforePublish.message
                == "This poll would close before it's posted. Move the closing time later.")
        #expect(ScheduleFailure.quotaExceeded.message
                == "You have 50 posts scheduled, the most allowed. Cancel one, or wait for one to go out.")
        #expect(ScheduleFailure.rateLimited.message == "You've scheduled a lot in the last hour. Try again later.")
        #expect(ScheduleFailure.tooLarge.message == "This post is too long to schedule.")
        #expect(ScheduleFailure.notConfigured.message == "Scheduling is unavailable right now.")
        #expect(ScheduleFailure.notCancellable(status: .sent).message == "This post has already been published.")
        #expect(ScheduleFailure.notCancellable(status: .publishing).message
                == "This post is being published right now and can't be cancelled.")
        #expect(ScheduleFailure.notCancellable(status: .failed).message
                == "This post already failed and won't be sent.")
    }
}

// The real submitter, on the request suite's stubbed session (same suite, so
// the two never script the stub at once).
extension ScheduleApiRequestTests {

    @Test func submitter_signsForThePublishTime_andSendsTheAuthorsWriteRelays() async throws {
        let privkey = Schnorr.randomPrivkey()
        let pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: privkey))
        let keypair = Keypair(privkey: Hex.encode(privkey), pubkey: pubkey)
        let asked = AskedPubkeys()
        let submitter = ScheduleSubmitter(session: ScheduleStubProtocol.session()) { pubkey in
            asked.note(pubkey)
            // The account's write list as kind 10002 has it: the floor relays,
            // a profile-only relay, an onion, and more than four of its own.
            return ["wss://nos.lol", "wss://one.example.com", "wss://purplepag.es", "wss://abc.onion",
                    "wss://two.example.com/", "wss://three.example.com", "wss://four.example.com",
                    "wss://five.example.com"]
        }
        let publishAt = NostrClock.now() + 3_600

        let event = try await submitter.sign(kind: 1, tags: [["t", "soup"]], content: "later",
                                             publishAt: publishAt, keypair: keypair).get()
        #expect(event.createdAt == publishAt)
        #expect(event.hasValidSignature())

        ScheduleStubProtocol.script([.http(201, """
        {"id":"\(event.id)","publish_at":\(publishAt),"relay_mode":"all","relays":[],"status":"pending"}
        """)])
        let receipt = try await submitter.send(event, keypair: keypair).get()

        #expect(receipt.id == event.id)
        #expect(asked.all == [pubkey])
        let request = try #require(ScheduleStubProtocol.requests.first)
        #expect(request.method == "POST")
        let body = try #require(request.body)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["relay_mode"] as? String == "all")
        #expect(object["relays"] as? [String] == [
            "wss://one.example.com", "wss://two.example.com", "wss://three.example.com", "wss://four.example.com",
        ])
    }

    @Test func submitter_withNoWriteRelaysOmitsTheField() async throws {
        let privkey = Schnorr.randomPrivkey()
        let pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: privkey))
        let keypair = Keypair(privkey: Hex.encode(privkey), pubkey: pubkey)
        let submitter = ScheduleSubmitter(session: ScheduleStubProtocol.session()) { _ in [] }
        let event = try await submitter.sign(kind: 1, tags: [], content: "later",
                                             publishAt: NostrClock.now() + 3_600, keypair: keypair).get()
        ScheduleStubProtocol.script([.http(201, """
        {"id":"\(event.id)","publish_at":\(event.createdAt),"relay_mode":"all","relays":[],"status":"pending"}
        """)])

        _ = try await submitter.send(event, keypair: keypair).get()

        let body = try #require(ScheduleStubProtocol.requests.first?.body)
        #expect(body == "{\"event\":\(event.toJSON()),\"relay_mode\":\"all\"}")
    }
}

nonisolated final class AskedPubkeys: @unchecked Sendable {
    private let lock = NSLock()
    private var pubkeys: [String] = []
    func note(_ pubkey: String) { lock.withLock { pubkeys.append(pubkey) } }
    var all: [String] { lock.withLock { pubkeys } }
}
