import Foundation
import Observation
import SwiftUI
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Authorization for the local-notification path. Denied / not-determined
/// is the honest in-process path: timers run only while the app is active
/// and pause on background. Never silently stall.
enum CookingTimerAuthorization: String, Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
}

/// Source of truth for a cooking timer. Remaining time is always derived
/// from `endsAt` (running) or `pausedRemaining` (paused). There is no
/// `remainingSeconds` field that ticks down — that model cannot reconstruct
/// after process death. Android's ViewModel ticks `remainingSeconds`; we
/// do not port that.
struct CookingTimer: Identifiable, Equatable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case running
        case paused
        case done
    }

    let id: String
    var label: String
    /// Original duration. Reset uses this, never a leftover remaining.
    let duration: TimeInterval
    /// Wall-clock fire date. Non-nil iff `status == .running`.
    var endsAt: Date?
    var status: Status
    /// Frozen remainder. Non-nil iff `status == .paused`.
    var pausedRemaining: TimeInterval?
    /// True when we paused because the app backgrounded without notification
    /// permission. Foreground auto-resumes these. A user pause does not.
    var pausedBySystem: Bool
    let createdAt: Date

    func remaining(at now: Date) -> TimeInterval {
        switch status {
        case .running:
            guard let endsAt else { return 0 }
            return max(0, endsAt.timeIntervalSince(now))
        case .paused:
            return max(0, pausedRemaining ?? 0)
        case .done:
            return 0
        }
    }

    /// `m:ss` or `h:mm:ss`. Ceil so the last second still reads 0:01.
    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds - 0.000_001)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

enum CookingTimerPresets {
    static let quickMinutes = [1, 3, 5, 10, 15, 30]
    static let cooking: [(emoji: String, name: String, minutes: Int)] = [
        ("🥚", "Poached", 4),
        ("🥚", "Hard Boiled", 10),
        ("🍝", "Pasta", 8),
        ("🍚", "Rice", 18),
        ("🥩", "Steak Rest", 5),
        ("🥦", "Steam Veg", 7),
        ("🥘", "Casserole", 45),
        ("🥔", "Baked Potato", 60),
    ]
}

/// On-screen copy when notifications are not authorized. Shown on the
/// sheet and the floating bar so a lock never looks like a silent stall.
enum CookingTimerCopy {
    /// Shown while notifications are not authorized. Timers still count
    /// down in the foreground; they freeze only when the app backgrounds.
    static let pausedWithoutNotifications =
        "Keep the app open — locking the phone pauses the timer. Allow notifications to get a ding when it finishes."
}

@MainActor
protocol CookingTimerClock: AnyObject {
    var now: Date { get }
}

@MainActor
protocol CookingTimerScheduling: AnyObject {
    func schedule(id: String, label: String, fireAt: Date)
    func cancel(id: String)
}

@MainActor
protocol CookingTimerAuthorizing: AnyObject {
    func status() async -> CookingTimerAuthorization
    func request() async -> CookingTimerAuthorization
}

/// Gadgets timers — Android `CookingTimerViewModel` + sheet/bar/overlay,
/// with `endsAt` instead of a 1-second decrement. Concern 1.8a.
///
/// Not cook mode. Android's `onStartCooking` is null; that screen is 1.8b.
@Observable
@MainActor
final class CookingTimerStore {

    static let shared = CookingTimerStore()

    static let persistKey = "cooking_timers_v1"
    static let maxMinutes = 999
    static let notificationPrefix = "cooking.timer."

    private(set) var timers: [CookingTimer] = []
    private(set) var completion: CookingTimer?
    private(set) var authorization: CookingTimerAuthorization = .notDetermined

    var hasActiveTimers: Bool { timers.contains { $0.status != .done } }

    var nextFinishing: CookingTimer? {
        timers
            .filter { $0.status == .running }
            .min { a, b in
                (a.endsAt ?? .distantFuture) < (b.endsAt ?? .distantFuture)
            }
            ?? timers.first { $0.status == .paused }
            ?? timers.first { $0.status == .done }
    }

    var extraActiveCount: Int {
        max(0, timers.filter { $0.status != .done }.count - 1)
    }

    /// True when the honest-pause sentence must be on screen.
    var showsDeniedPauseCopy: Bool { authorization != .authorized }

    @ObservationIgnored private let clock: CookingTimerClock
    @ObservationIgnored private let scheduler: CookingTimerScheduling
    @ObservationIgnored private let authorizer: CookingTimerAuthorizing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    #if canImport(UserNotifications)
    @ObservationIgnored private var notificationDelegate: CookingTimerNotificationDelegate?
    #endif

    convenience init() {
        self.init(
            clock: SystemCookingTimerClock(),
            scheduler: UserNotificationCookingTimerScheduler(),
            authorizer: UserNotificationCookingTimerAuthorizer(),
            defaults: .standard,
            installNotificationDelegate: true
        )
    }

    init(
        clock: CookingTimerClock,
        scheduler: CookingTimerScheduling,
        authorizer: CookingTimerAuthorizing,
        defaults: UserDefaults,
        installNotificationDelegate: Bool = false
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.authorizer = authorizer
        self.defaults = defaults
        timers = Self.load(from: defaults)
        markElapsed()
        persist()
        if installNotificationDelegate {
            #if canImport(UserNotifications)
            let delegate = CookingTimerNotificationDelegate()
            notificationDelegate = delegate
            UNUserNotificationCenter.current().delegate = delegate
            #endif
        }
        startWatchingIfNeeded()
    }

    // MARK: - Mutations

    @discardableResult
    func addTimer(label: String, minutes: Int) -> CookingTimer? {
        guard minutes > 0, minutes <= Self.maxMinutes else { return nil }
        let now = clock.now
        let duration = TimeInterval(minutes * 60)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let timer = CookingTimer(
            id: UUID().uuidString,
            label: trimmed.isEmpty ? "\(minutes)m timer" : trimmed,
            duration: duration,
            endsAt: now.addingTimeInterval(duration),
            status: .running,
            pausedRemaining: nil,
            pausedBySystem: false,
            createdAt: now
        )
        timers.append(timer)
        persist()
        scheduleIfAuthorized(timer)
        startWatchingIfNeeded()
        return timer
    }

    func pause(id: String) {
        pause(id: id, bySystem: false)
    }

    func resume(id: String) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        var timer = timers[index]
        guard timer.status == .paused else { return }
        let remaining = max(0, timer.pausedRemaining ?? 0)
        if remaining == 0 {
            timer.status = .done
            timer.endsAt = nil
            timer.pausedRemaining = nil
            timer.pausedBySystem = false
            timers[index] = timer
            presentCompletion(timer)
            persist()
            return
        }
        let now = clock.now
        timer.status = .running
        timer.endsAt = now.addingTimeInterval(remaining)
        timer.pausedRemaining = nil
        timer.pausedBySystem = false
        timers[index] = timer
        persist()
        scheduleIfAuthorized(timer)
        startWatchingIfNeeded()
    }

    func cancel(id: String) {
        scheduler.cancel(id: id)
        if completion?.id == id { completion = nil }
        timers.removeAll { $0.id == id }
        persist()
    }

    func reset(id: String) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        scheduler.cancel(id: id)
        let now = clock.now
        var timer = timers[index]
        timer.status = .running
        timer.endsAt = now.addingTimeInterval(timer.duration)
        timer.pausedRemaining = nil
        timer.pausedBySystem = false
        timers[index] = timer
        if completion?.id == id { completion = nil }
        persist()
        scheduleIfAuthorized(timer)
        startWatchingIfNeeded()
    }

    func clearFinished() {
        let finishedIds = timers.filter { $0.status == .done }.map(\.id)
        for id in finishedIds { scheduler.cancel(id: id) }
        if let completion, finishedIds.contains(completion.id) {
            self.completion = nil
        }
        timers.removeAll { $0.status == .done }
        persist()
    }

    func dismissCompletion() {
        completion = nil
    }

    /// Recompute done-ness from `endsAt`. Call on foreground and on the
    /// 1s watch. This is the reconstruction the Android decrement cannot do.
    func markElapsed() {
        let now = clock.now
        var newly: [CookingTimer] = []
        timers = timers.map { timer in
            guard timer.status == .running, let endsAt = timer.endsAt, now >= endsAt else {
                return timer
            }
            var done = timer
            done.status = .done
            done.endsAt = nil
            done.pausedRemaining = nil
            done.pausedBySystem = false
            newly.append(done)
            return done
        }
        if let last = newly.last {
            for timer in newly { scheduler.cancel(id: timer.id) }
            presentCompletion(last)
            persist()
        }
    }

    func prepareNotifications() async {
        var status = await authorizer.status()
        if status == .notDetermined {
            status = await authorizer.request()
        }
        authorization = status
        syncScheduledNotifications()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await onForeground() }
        case .background:
            onBackground()
        default:
            break
        }
    }

    func onForeground() async {
        authorization = await authorizer.status()
        markElapsed()
        // Always unfreeze system-paused timers on active. Denied: they
        // count down in-process. Newly authorized (granted in Settings):
        // they pick up a wall-clock `endsAt` and then get a notification.
        resumeSystemPaused()
        syncScheduledNotifications()
        startWatchingIfNeeded()
    }

    func onBackground() {
        watchTask?.cancel()
        watchTask = nil
        if authorization != .authorized {
            pauseRunningForBackground()
        }
    }

    // MARK: - Internals

    private func pause(id: String, bySystem: Bool) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        var timer = timers[index]
        guard timer.status == .running else { return }
        let remaining = timer.remaining(at: clock.now)
        scheduler.cancel(id: id)
        timer.status = .paused
        timer.endsAt = nil
        timer.pausedRemaining = remaining
        timer.pausedBySystem = bySystem
        timers[index] = timer
        persist()
    }

    private func pauseRunningForBackground() {
        let ids = timers.filter { $0.status == .running }.map(\.id)
        for id in ids { pause(id: id, bySystem: true) }
    }

    private func resumeSystemPaused() {
        let ids = timers.filter { $0.status == .paused && $0.pausedBySystem }.map(\.id)
        for id in ids { resume(id: id) }
    }

    private func syncScheduledNotifications() {
        if authorization == .authorized {
            for timer in timers where timer.status == .running {
                scheduleIfAuthorized(timer)
            }
        } else {
            for timer in timers where timer.status == .running {
                scheduler.cancel(id: timer.id)
            }
        }
    }

    private func scheduleIfAuthorized(_ timer: CookingTimer) {
        guard authorization == .authorized,
              timer.status == .running,
              let endsAt = timer.endsAt,
              endsAt > clock.now
        else { return }
        scheduler.schedule(id: timer.id, label: timer.label, fireAt: endsAt)
    }

    private func presentCompletion(_ timer: CookingTimer) {
        completion = timer
        #if canImport(UIKit)
        Haptics.shared.success()
        #endif
    }

    private func startWatchingIfNeeded() {
        guard watchTask == nil, timers.contains(where: { $0.status == .running }) else { return }
        watchTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.timers.contains(where: { $0.status == .running }) {
                self.markElapsed()
                try? await Task.sleep(for: .seconds(1))
            }
            self?.watchTask = nil
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(timers) else { return }
        defaults.set(data, forKey: Self.persistKey)
    }

    private static func load(from defaults: UserDefaults) -> [CookingTimer] {
        guard let data = defaults.data(forKey: persistKey),
              let timers = try? JSONDecoder().decode([CookingTimer].self, from: data)
        else { return [] }
        return timers.map { timer in
            var t = timer
            switch t.status {
            case .running:
                t.pausedRemaining = nil
                t.pausedBySystem = false
            case .paused:
                t.endsAt = nil
            case .done:
                t.endsAt = nil
                t.pausedRemaining = nil
                t.pausedBySystem = false
            }
            return t
        }
    }
}

// MARK: - Production collaborators

@MainActor
final class SystemCookingTimerClock: CookingTimerClock {
    var now: Date { Date() }
}

#if canImport(UserNotifications)
@MainActor
final class UserNotificationCookingTimerScheduler: CookingTimerScheduling {
    func schedule(id: String, label: String, fireAt: Date) {
        let interval = fireAt.timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Timer done!"
        content.body = "\(label) is ready"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, interval),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: CookingTimerStore.notificationPrefix + id,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    func cancel(id: String) {
        let identifier = CookingTimerStore.notificationPrefix + id
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

@MainActor
final class UserNotificationCookingTimerAuthorizer: CookingTimerAuthorizing {
    func status() async -> CookingTimerAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    func request() async -> CookingTimerAuthorization {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        return granted ? .authorized : .denied
    }

    private static func map(_ status: UNAuthorizationStatus) -> CookingTimerAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

/// Foreground: suppress the system banner — the in-app overlay owns that
/// moment. Background: banner + sound + Notification Center.
final class CookingTimerNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .active { return [] }
        #endif
        return [.banner, .sound, .list]
    }
}
#else
@MainActor
final class UserNotificationCookingTimerScheduler: CookingTimerScheduling {
    func schedule(id: String, label: String, fireAt: Date) {}
    func cancel(id: String) {}
}

@MainActor
final class UserNotificationCookingTimerAuthorizer: CookingTimerAuthorizing {
    func status() async -> CookingTimerAuthorization { .denied }
    func request() async -> CookingTimerAuthorization { .denied }
}
#endif
