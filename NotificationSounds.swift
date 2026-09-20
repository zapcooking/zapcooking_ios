import Foundation
import AVFoundation

@MainActor
final class NotificationSounds {
    static let shared = NotificationSounds()

    enum Effect: Equatable {
        case reply
        case blip
        case zap
    }

    private var players: [Effect: AVAudioPlayer] = [:]
    private var sessionConfigured = false

    private init() {}

    func play(_ effect: Effect) {
        guard AppSettings.shared.notificationSoundsEnabled else {
            NSLog("[NotifSnd] skipped: setting off effect=%@", String(describing: effect))
            return
        }
        configureSessionIfNeeded()
        reactivateSessionForPlayback()
        guard let p = player(for: effect) else {
            NSLog("[NotifSnd] no player for effect=%@", String(describing: effect))
            return
        }
        p.currentTime = 0
        let ok = p.play()
        NSLog("[NotifSnd] play effect=%@ ok=%d vol=%f", String(describing: effect), ok ? 1 : 0, p.volume)
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

    private func player(for effect: Effect) -> AVAudioPlayer? {
        if let p = players[effect] { return p }
        let (name, vol): (String, Float) = {
            switch effect {
            case .reply: return ("icq_reply", 0.4)
            case .blip:  return ("notif_blip", 0.2)
            case .zap:   return ("zap_thunder", 0.4)
            }
        }()
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            NSLog("[NotificationSounds] missing resource %@.mp3", name)
            return nil
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = vol
            p.prepareToPlay()
            players[effect] = p
            return p
        } catch {
            NSLog("[NotificationSounds] AVAudioPlayer init failed for %@: %@", name, String(describing: error))
            return nil
        }
    }
}
