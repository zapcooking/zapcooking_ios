import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Refcounted keep-awake for cook mode. `isIdleTimerDisabled` is true while
/// the count is greater than zero.
///
/// Scoped to **the cook-mode screen being visible and the scene being
/// active**, never to a running timer. Timers outlive the screen; the idle
/// timer must not. A user who pops back to the feed with a 45-minute
/// casserole running must not have their screen pinned on.
///
/// Concern 1.8b. iOS-original — Android cook mode was never wired
/// (`onStartCooking = null`), so there is no reference implementation.
///
/// Pairing used by `CookModeViewModel`:
/// - `acquire` on appear and on `scenePhase == .active`
/// - `release` on disappear, `.background`, and `.inactive` (this
///   screen's claim only — never `forceZero` on a live shared lock)
/// - `forceZero` on terminate (process is dying)
///
/// Do not set `UIApplication.shared.isIdleTimerDisabled` from a view body.
@MainActor
final class CookWakeLock {

    static let shared = CookWakeLock()

    private(set) var count = 0
    /// Last value pushed to the idle-timer setter. Tests assert this
    /// explicitly after teardown rather than assuming `release` ran.
    private(set) var lastApplied = false

    /// Production writes `UIApplication.shared.isIdleTimerDisabled`.
    /// Tests replace this so the suite never touches the process idle timer.
    var applyIdleTimer: (Bool) -> Void

    var isIdleTimerDisabled: Bool { count > 0 }

    init(applyIdleTimer: ((Bool) -> Void)? = nil) {
        self.applyIdleTimer = applyIdleTimer ?? { disabled in
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = disabled
            #endif
        }
    }

    func acquire() {
        count += 1
        apply()
    }

    func release() {
        guard count > 0 else { return }
        count -= 1
        apply()
    }

    /// Drop every claim. Call on terminate so a dying process cannot
    /// leave the idle timer disabled. Do **not** call this when a single
    /// cook-mode screen tears down — that path is `release`, so another
    /// window's claim survives.
    func forceZero() {
        count = 0
        apply()
    }

    private func apply() {
        let disabled = count > 0
        lastApplied = disabled
        applyIdleTimer(disabled)
    }
}
