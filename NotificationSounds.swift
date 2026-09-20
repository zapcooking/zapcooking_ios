import Foundation
import AVFoundation

/// The selectable notification tones, ported from Zap Cooking Android's
/// `NotificationSoundPreferences.SOUNDS`. Same files, same labels, same
/// order, same defaults — replies get the oven ding, everything else the
/// soda pop, and zaps keep a dedicated thunder that is not selectable.
nonisolated struct NotificationSound: Identifiable, Equatable {
    /// Bundled resource name, minus the `.mp3`.
    let rawName: String
    let label: String

    var id: String { rawName }

    /// Selecting this plays nothing.
    static let none = "none"
    /// Fixed tone for zaps — dedicated, deliberately not user-selectable.
    static let zap = "zap_thunder"
    static let defaultReply = "oven_ding"
    static let defaultActivity = "soda_open"

    /// Options offered by the two pickers, in Android's order.
    static let all: [NotificationSound] = [
        NotificationSound(rawName: "oven_ding", label: "Oven Ding"),
        NotificationSound(rawName: "soda_open", label: "Soda Pop"),
        NotificationSound(rawName: "dinner_bell", label: "Dinner Bell"),
        NotificationSound(rawName: "door_bell", label: "Door Bell"),
        NotificationSound(rawName: "frying_pan", label: "Frying Pan"),
        NotificationSound(rawName: "cartoon_bite", label: "Cartoon Bite"),
        NotificationSound(rawName: "yum_yum", label: "Yum Yum"),
        NotificationSound(rawName: "glass_toast", label: "Glass Toast"),
        NotificationSound(rawName: none, label: "None (silent)"),
    ]

    static func label(for rawName: String) -> String {
        all.first { $0.rawName == rawName }?.label ?? label(for: defaultReply)
    }

    /// What a stored preference resolves to. A name this build no longer
    /// ships (a tone dropped in a later version) falls back to the default
    /// rather than leaving the user silent by accident.
    static func resolve(stored raw: String?, fallback: String) -> String {
        guard let raw, all.contains(where: { $0.rawName == raw }) else { return fallback }
        return raw
    }
}

@MainActor
final class NotificationSounds {
    static let shared = NotificationSounds()

    enum Effect: Equatable {
        case reply
        case blip
        case zap
    }

    /// Cached per resource name rather than per effect: two categories can
    /// point at the same tone, and a selection change must not leave a stale
    /// player behind.
    private var players: [String: AVAudioPlayer] = [:]
    private var sessionConfigured = false

    private init() {}

    /// The resource the effect currently resolves to. Replies and activity
    /// follow the user's pick; zaps are fixed.
    static func resourceName(for effect: Effect, settings: AppSettings = .shared) -> String {
        switch effect {
        case .reply: settings.replySoundName
        case .blip:  settings.activitySoundName
        case .zap:   NotificationSound.zap
        }
    }

    func play(_ effect: Effect) {
        guard AppSettings.shared.notificationSoundsEnabled else {
            NSLog("[NotifSnd] skipped: setting off effect=%@", String(describing: effect))
            return
        }
        play(resource: Self.resourceName(for: effect))
    }

    /// Play a tone by resource name. Also the settings picker's preview, so
    /// it deliberately does not consult the master switch — auditioning a
    /// tone you are about to choose should work whatever that is set to.
    func play(resource name: String) {
        guard name != NotificationSound.none else { return }
        configureSessionIfNeeded()
        reactivateSessionForPlayback()
        guard let p = player(named: name) else {
            NSLog("[NotifSnd] no player for %@", name)
            return
        }
        p.currentTime = 0
        let ok = p.play()
        NSLog("[NotifSnd] play %@ ok=%d vol=%f", name, ok ? 1 : 0, p.volume)
    }

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        #if os(iOS) || os(tvOS) || os(visionOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            sessionConfigured = true
        } catch {
            NSLog("[NotificationSounds] session setup failed: %@", String(describing: error))
        }
        #else
        sessionConfigured = true
        #endif
    }

    private func reactivateSessionForPlayback() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true, options: [])
        #endif
    }

    private func player(named name: String) -> AVAudioPlayer? {
        if let p = players[name] { return p }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            NSLog("[NotificationSounds] missing resource %@.mp3", name)
            return nil
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            // The thunder is the loudest of the set and was already mixed
            // down; the food tones share one level so switching between
            // them does not change how loud a reply is.
            p.volume = name == NotificationSound.zap ? 0.4 : 0.5
            p.prepareToPlay()
            players[name] = p
            return p
        } catch {
            NSLog("[NotificationSounds] AVAudioPlayer init failed for %@: %@", name, String(describing: error))
            return nil
        }
    }
}
