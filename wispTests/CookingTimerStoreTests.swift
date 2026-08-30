import Foundation
import Testing
@testable import wisp

/// Concern 1.8a — Gadgets timers. `endsAt` is the source of truth;
/// `remainingSeconds` must not exist. Android's ViewModel decrements an
/// integer and cannot reconstruct after process death; these cases lock
/// the reconstruction contract that replaces it.
@MainActor
struct CookingTimerStoreTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Harness

    private func harness(
        auth: CookingTimerAuthorization = .authorized,
        suite: String = UUID().uuidString
    ) -> (
        store: CookingTimerStore,
        clock: ControllableCookingTimerClock,
        scheduler: RecordingCookingTimerScheduler,
        authorizer: ControllableCookingTimerAuthorizer,
        defaults: UserDefaults
    ) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let clock = ControllableCookingTimerClock(t0)
        let scheduler = RecordingCookingTimerScheduler()
        let authorizer = ControllableCookingTimerAuthorizer(authorization: auth)
        let store = CookingTimerStore(
            clock: clock,
            scheduler: scheduler,
            authorizer: authorizer,
            defaults: defaults
        )
        return (store, clock, scheduler, authorizer, defaults)
    }

    private func authorizedStore() async -> (
        store: CookingTimerStore,
        clock: ControllableCookingTimerClock,
        scheduler: RecordingCookingTimerScheduler
    ) {
        let h = harness(auth: .authorized)
        await h.store.prepareNotifications()
        return (h.store, h.clock, h.scheduler)
    }

    // MARK: - endsAt, never remainingSeconds

    @Test func addTimer_setsEndsAtFromClock_notATickingRemainder() async throws {
        let (store, _, _) = await authorizedStore()
        let timer = try #require(store.addTimer(label: "Pasta", minutes: 8))
        #expect(timer.endsAt == t0.addingTimeInterval(8 * 60))
        #expect(timer.duration == 8 * 60)
        #expect(timer.status == .running)
        #expect(timer.pausedRemaining == nil)
        #expect(timer.remaining(at: t0) == TimeInterval(8 * 60))
    }

    @Test func addTimer_blankLabel_usesMinutesFallback() async throws {
        let (store, _, _) = await authorizedStore()
        let timer = try #require(store.addTimer(label: "  ", minutes: 5))
        #expect(timer.label == "5m timer")
    }

    @Test func addTimer_rejectsZeroAndOverMax() async {
        let (store, _, _) = await authorizedStore()
        #expect(store.addTimer(label: "x", minutes: 0) == nil)
        #expect(store.addTimer(label: "x", minutes: 1000) == nil)
        #expect(store.timers.isEmpty)
    }

    @Test func reconstruct_midTimer_matchesWallClock() async throws {
        let (store, clock, _) = await authorizedStore()
        let timer = try #require(store.addTimer(label: "Simmer", minutes: 20))
        clock.now = t0.addingTimeInterval(7 * 60)
        store.markElapsed()
        let live = try #require(store.timers.first)
        #expect(live.status == .running)
        #expect(live.id == timer.id)
        #expect(live.remaining(at: clock.now) == TimeInterval(13 * 60))
        #expect(live.endsAt == t0.addingTimeInterval(20 * 60))
    }

    @Test func reconstruct_pastEndsAt_marksDoneAndCompletes() async throws {
        let (store, clock, _) = await authorizedStore()
        let timer = try #require(store.addTimer(label: "Eggs", minutes: 10))
        clock.now = t0.addingTimeInterval(10 * 60)
        store.markElapsed()
        #expect(store.timers.first?.status == .done)
        #expect(store.completion?.id == timer.id)
    }

    // MARK: - pause / resume / cancel

    @Test func pause_clearsEndsAt_cancelsNotification_freezesRemainder() async throws {
        let (store, clock, scheduler) = await authorizedStore()
        let timer = try #require(store.addTimer(label: "Rice", minutes: 18))
        #expect(scheduler.scheduled.map(\.id) == [timer.id])

        clock.now = t0.addingTimeInterval(3 * 60)
        store.pause(id: timer.id)

        let paused = try #require(store.timers.first)
        #expect(paused.status == .paused)
        #expect(paused.endsAt == nil)
        #expect(try #require(paused.pausedRemaining) == TimeInterval(15 * 60))
        #expect(paused.pausedBySystem == false)
        #expect(scheduler.cancelled == [timer.id])
    }

    @Test func resume_writesNewEndsAtFromFrozenRemainder() async throws {
        let (store, clock, scheduler) = await authorizedStore()
        let timer = try #require(store.addTimer(label: "Rice", minutes: 18))
        clock.now = t0.addingTimeInterval(3 * 60)
        store.pause(id: timer.id)
        scheduler.scheduled.removeAll()

        clock.now = t0.addingTimeInterval(8 * 60)
        store.resume(id: timer.id)

        let running = try #require(store.timers.first)
        #expect(running.status == .running)
        #expect(running.endsAt == clock.now.addingTimeInterval(15 * 60))
        #expect(running.pausedRemaining == nil)
        #expect(scheduler.scheduled.map(\.id) == [timer.id])
    }

    @Test func cancel_removesTimer_andPendingNotification() async throws {
        let (store, _, scheduler) = await authorizedStore()
        let timer = try #require(store.addTimer(label: "Pasta", minutes: 8))
        store.cancel(id: timer.id)
        #expect(store.timers.isEmpty)
        #expect(scheduler.cancelled.contains(timer.id))
    }

    // MARK: - persist / process death

    @Test func persist_reloadsEndsAtAcrossNewStore() async throws {
        let suite = UUID().uuidString
        let h = harness(auth: .authorized, suite: suite)
        await h.store.prepareNotifications()
        let timer = try #require(h.store.addTimer(label: "Casserole", minutes: 45))

        let clock2 = ControllableCookingTimerClock(t0.addingTimeInterval(10 * 60))
        let store2 = CookingTimerStore(
            clock: clock2,
            scheduler: RecordingCookingTimerScheduler(),
            authorizer: ControllableCookingTimerAuthorizer(authorization: .authorized),
            defaults: h.defaults
        )
        let loaded = try #require(store2.timers.first)
        #expect(loaded.id == timer.id)
        #expect(loaded.endsAt == timer.endsAt)
        #expect(loaded.remaining(at: clock2.now) == TimeInterval(35 * 60))
        #expect(loaded.status == .running)
    }

    @Test func persist_processDeathPastEndsAt_isDoneOnReload() async {
        let suite = UUID().uuidString
        let h = harness(auth: .authorized, suite: suite)
        await h.store.prepareNotifications()
        _ = h.store.addTimer(label: "Steak Rest", minutes: 5)

        let later = ControllableCookingTimerClock(t0.addingTimeInterval(6 * 60))
        let store2 = CookingTimerStore(
            clock: later,
            scheduler: RecordingCookingTimerScheduler(),
            authorizer: ControllableCookingTimerAuthorizer(authorization: .authorized),
            defaults: h.defaults
        )
        #expect(store2.timers.first?.status == .done)
        #expect(store2.completion?.label == "Steak Rest")
    }

    // MARK: - permission denied → honest pause

    @Test func denied_background_pausesRunningTimers_cancelsNotification() async throws {
        let h = harness(auth: .denied)
        await h.store.prepareNotifications()
        let timer = try #require(h.store.addTimer(label: "Poached", minutes: 4))
        #expect(h.store.showsDeniedPauseCopy)
        h.clock.now = t0.addingTimeInterval(60)
        h.store.onBackground()

        let paused = try #require(h.store.timers.first)
        #expect(paused.status == .paused)
        #expect(paused.endsAt == nil)
        #expect(try #require(paused.pausedRemaining) == TimeInterval(3 * 60))
        #expect(paused.pausedBySystem)
        #expect(h.scheduler.cancelled.contains(timer.id))
    }

    @Test func denied_foreground_resumesSystemPaused_notUserPaused() async throws {
        let h = harness(auth: .denied)
        await h.store.prepareNotifications()
        let system = try #require(h.store.addTimer(label: "Veg", minutes: 7))
        let user = try #require(h.store.addTimer(label: "Pasta", minutes: 8))
        h.store.pause(id: user.id)
        h.clock.now = t0.addingTimeInterval(30)
        h.store.onBackground()

        h.clock.now = t0.addingTimeInterval(90)
        await h.store.onForeground()

        let veg = try #require(h.store.timers.first { $0.id == system.id })
        let pasta = try #require(h.store.timers.first { $0.id == user.id })
        #expect(veg.status == .running)
        #expect(veg.endsAt == h.clock.now.addingTimeInterval(7 * 60 - 30))
        #expect(pasta.status == .paused)
        #expect(pasta.pausedBySystem == false)
    }

    @Test func authorized_background_doesNotPause() async {
        let (store, _, _) = await authorizedStore()
        _ = store.addTimer(label: "Simmer", minutes: 20)
        store.onBackground()
        #expect(store.timers.first?.status == .running)
        #expect(store.timers.first?.endsAt == t0.addingTimeInterval(20 * 60))
    }

    // MARK: - multi-timer

    @Test func nextFinishing_isSoonestEndsAt_extraCountIgnoresDone() async throws {
        let (store, clock, _) = await authorizedStore()
        let long = try #require(store.addTimer(label: "Potato", minutes: 60))
        let short = try #require(store.addTimer(label: "Poached", minutes: 4))
        #expect(store.nextFinishing?.id == short.id)
        #expect(store.extraActiveCount == 1)

        clock.now = t0.addingTimeInterval(4 * 60)
        store.markElapsed()
        #expect(store.nextFinishing?.id == long.id)
        #expect(store.extraActiveCount == 0)
    }

    @Test func schedule_oneRequestPerTimer_uniqueIds() async throws {
        let (store, _, scheduler) = await authorizedStore()
        let a = try #require(store.addTimer(label: "A", minutes: 1))
        let b = try #require(store.addTimer(label: "B", minutes: 3))
        #expect(Set(scheduler.scheduled.map(\.id)) == [a.id, b.id])
        #expect(scheduler.scheduled.map(\.fireAt) == [
            t0.addingTimeInterval(60),
            t0.addingTimeInterval(180),
        ])
    }

    @Test func formatRemaining_ceilUntilDone() {
        #expect(CookingTimer.formatRemaining(0) == "0:00")
        #expect(CookingTimer.formatRemaining(1) == "0:01")
        #expect(CookingTimer.formatRemaining(61) == "1:01")
        #expect(CookingTimer.formatRemaining(3600) == "1:00:00")
    }
}

// MARK: - Test doubles

@MainActor
final class ControllableCookingTimerClock: CookingTimerClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class RecordingCookingTimerScheduler: CookingTimerScheduling {
    struct Call: Equatable {
        var id: String
        var label: String
        var fireAt: Date
    }
    var scheduled: [Call] = []
    var cancelled: [String] = []

    func schedule(id: String, label: String, fireAt: Date) {
        scheduled.append(Call(id: id, label: label, fireAt: fireAt))
    }

    func cancel(id: String) {
        cancelled.append(id)
        scheduled.removeAll { $0.id == id }
    }
}

@MainActor
final class ControllableCookingTimerAuthorizer: CookingTimerAuthorizing {
    var authorization: CookingTimerAuthorization
    init(authorization: CookingTimerAuthorization) {
        self.authorization = authorization
    }

    func status() async -> CookingTimerAuthorization { authorization }

    func request() async -> CookingTimerAuthorization { authorization }
}
