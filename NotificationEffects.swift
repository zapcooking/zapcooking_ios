import Foundation
import Observation
import SwiftUI

/// Which notification types the user wants to hear about.
///
/// Android reads this set on every arrival before playing a sound, buzzing,
/// or running a bottom-bar burst (`Navigation.kt`). iOS already persisted the
/// same set, but only `NotificationsViewModel` knew the key, and the two
/// repositories that fire effects have no view model to ask. The key moves
/// here so both sides read one definition; the view model now delegates.
@MainActor
enum NotificationFilterStore {
    /// Per-account, matching what `NotificationsViewModel` has always
    /// written. iOS scopes the set to a pubkey where Android keeps one
    /// global pref (`PREF_ENABLED_NOTIF_TYPES`) — the per-account form is
    /// kept, since switching accounts should not inherit the other
    /// account's filter.
    static func key(pubkey: String) -> String { "notif_enabled_types_\(pubkey)" }

    /// The saved set, or every type when the account has never touched the
    /// filter. An unknown stored raw value is dropped rather than failing
    /// the whole load, so a filter removed in a later build can't strand the
    /// user with no types.
    static func load(pubkey: String) -> Set<NotificationFilter> {
        guard let raws = UserDefaults.standard.stringArray(forKey: key(pubkey: pubkey)) else {
            return Set(NotificationFilter.allCases)
        }
        return Set(raws.compactMap(NotificationFilter.init(rawValue:)))
    }

    static func save(_ types: Set<NotificationFilter>, pubkey: String) {
        UserDefaults.standard.set(types.map(\.rawValue), forKey: key(pubkey: pubkey))
    }

    /// The set for whichever account is signed in — what the repositories
    /// consult on an arrival, since they are not built per account. No
    /// signed-in key means nothing to filter against, so everything passes.
    static func loadActive() -> Set<NotificationFilter> {
        guard let pubkey = NostrKey.load()?.pubkey else {
            return Set(NotificationFilter.allCases)
        }
        return load(pubkey: pubkey)
    }
}

/// Transient "a zap just landed" flag that drives the bottom-bar burst,
/// mirroring Android's `isZapAnimating` in `Navigation.kt`. The repository
/// fires; `MainView` renders.
///
/// Android also runs an ICQ flower burst on replies and DMs
/// (`isReplyAnimating`). That is a Wisp house convention, not a Zap Cooking
/// one, so it is deliberately not ported — replies and DMs keep their sound
/// and haptic and draw nothing.
///
/// The flag latches true for the same window Android uses and then clears
/// itself, so the burst view sees a false → true transition exactly once per
/// arrival. Re-firing while a burst is in flight restarts it.
@MainActor
@Observable
final class NotificationBurstStore {
    static let shared = NotificationBurstStore()

    /// Android: `delay(900)` around `isZapAnimating`.
    static let zapDuration: TimeInterval = 0.9

    private(set) var zapBurst = false
    /// Bumped on every `fireZap()`, including a refire while the flag is
    /// already true. `ZapBurstView` only starts particles on a false→true
    /// edge of `isActive`, so the parent watches this token to restart.
    private(set) var zapGeneration = 0

    @ObservationIgnored private var zapClear: Task<Void, Never>?

    /// `shared` is the instance the app drives; the initializer is open so
    /// tests can exercise the latch on their own instance instead of racing
    /// each other through the singleton.
    init() {}

    /// Bolt burst over the Notifications tab, and the tab's own glyph swaps
    /// to a bolt for the duration (Android `BottomBar.kt` swaps to `ic_bolt`
    /// while `isZapAnimating`).
    func fireZap() {
        zapClear?.cancel()
        zapGeneration += 1
        zapBurst = true
        zapClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.zapDuration))
            guard !Task.isCancelled else { return }
            self?.zapBurst = false
        }
    }
}

/// The haptic an arrival fires, named rather than invoked so the decision can
/// be made (and tested) away from `Haptics.shared`.
enum NotificationHaptic: Equatable {
    case pulse
    case blip
    case zapBuzz

    @MainActor
    func fire() {
        switch self {
        case .pulse:   Haptics.shared.pulse()
        case .blip:    Haptics.shared.blip()
        case .zapBuzz: Haptics.shared.zapBuzz()
        }
    }
}

/// Which bottom-bar burst an arrival runs, if any. Zaps are the only one —
/// Android's ICQ flower for replies and DMs is a Wisp convention we do not
/// carry over.
enum NotificationBurst: Equatable {
    case zap

    @MainActor
    func fire() {
        switch self {
        case .zap: NotificationBurstStore.shared.fireZap()
        }
    }
}

/// Everything one arrival should set off. Pure data so the Android parity
/// table can be asserted directly instead of inferred from side effects.
///
/// The two gates are not symmetric, and that asymmetry is Android's:
/// - the global sound toggle silences **audio only**;
/// - the per-type notification filter suppresses the **haptic and burst too**
///   — muting Reactions stops them buzzing, not just chiming;
/// - except for zaps, whose burst and thunder Android runs off `zapReceived`
///   with no filter check (`Navigation.kt`); only the buzz consults ZAPS.
struct NotificationEffectPlan: Equatable {
    var sound: NotificationSounds.Effect?
    var haptic: NotificationHaptic?
    var burst: NotificationBurst?

    static let none = NotificationEffectPlan()

    static func plan(
        for kind: NotificationKind,
        soundsOn: Bool,
        typeEnabled: Bool
    ) -> NotificationEffectPlan {
        switch kind {
        case .reply, .dm:
            // Android groups DMs with replies — same sound, same haptic. Its
            // ICQ flower burst rides along with them there; we drop the burst
            // and keep the pair.
            guard typeEnabled else { return .none }
            return NotificationEffectPlan(
                sound: soundsOn ? .reply : nil, haptic: .pulse, burst: nil)
        case .reaction, .repost, .mention, .quote, .pollVote, .pollEnded:
            // Votes bucket in with the blip crowd on Android
            // (`Nip88.KIND_POLL_RESPONSE -> NotificationFilter.VOTES`).
            guard typeEnabled else { return .none }
            return NotificationEffectPlan(
                sound: soundsOn ? .blip : nil, haptic: .blip, burst: nil)
        case .zap:
            return NotificationEffectPlan(
                sound: soundsOn ? .zap : nil,
                haptic: typeEnabled ? .zapBuzz : nil,
                burst: .zap)
        }
    }

    /// Run it. No-op for `.none`.
    @MainActor
    func fire() {
        if let sound { NotificationSounds.shared.play(sound) }
        haptic?.fire()
        burst?.fire()
    }
}
