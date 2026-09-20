import Foundation
import Testing
@testable import wisp

/// The selectable notification tones, ported from Zap Cooking Android's
/// `NotificationSoundPreferences`. Same files, same labels, same order,
/// same defaults — a picker that offers a tone the bundle does not ship
/// would be silently broken, so every option is checked against the app
/// bundle.
@MainActor
struct NotificationSoundCatalogTests {

    @Test func catalog_matchesAndroidOrderAndLabels() {
        #expect(NotificationSound.all.map(\.rawName) == [
            "oven_ding", "soda_open", "dinner_bell", "door_bell",
            "frying_pan", "cartoon_bite", "yum_yum", "glass_toast", "none",
        ])
        #expect(NotificationSound.label(for: "soda_open") == "Soda Pop")
        #expect(NotificationSound.label(for: NotificationSound.none) == "None (silent)")
    }

    @Test func defaults_matchAndroid() {
        #expect(NotificationSound.defaultReply == "oven_ding")
        #expect(NotificationSound.defaultActivity == "soda_open")
        #expect(NotificationSound.zap == "zap_thunder")
    }

    /// Every selectable tone — and the fixed zap one — has to be in the
    /// bundle. A missing file plays nothing and logs, which is exactly the
    /// kind of silence nobody notices.
    @Test func everySelectableSound_isBundled() {
        for sound in NotificationSound.all where sound.rawName != NotificationSound.none {
            #expect(Bundle.main.url(forResource: sound.rawName, withExtension: "mp3") != nil,
                    "\(sound.rawName).mp3 missing from the bundle")
        }
        #expect(Bundle.main.url(forResource: NotificationSound.zap, withExtension: "mp3") != nil)
    }

    /// The Wisp-era tones are gone with the ICQ convention.
    @Test func wispTones_areNoLongerBundled() {
        for name in ["icq_reply", "notif_blip"] {
            #expect(Bundle.main.url(forResource: name, withExtension: "mp3") == nil, "\(name) is still bundled")
        }
    }

    /// A stored tone this build no longer ships falls back to the default
    /// rather than leaving the user accidentally silent.
    @Test func resolve_fallsBackForUnknownNames() {
        #expect(NotificationSound.resolve(stored: "yum_yum", fallback: "oven_ding") == "yum_yum")
        #expect(NotificationSound.resolve(stored: nil, fallback: "oven_ding") == "oven_ding")
        #expect(NotificationSound.resolve(stored: "retired_tone", fallback: "oven_ding") == "oven_ding")
        // Silence is a real choice and survives.
        #expect(NotificationSound.resolve(stored: "none", fallback: "oven_ding") == "none")
    }

    /// Replies and activity follow the user's pick; zaps never do.
    @Test func effects_resolveToTheChosenTones() {
        let settings = AppSettings.shared
        let saved = (settings.replySoundName, settings.activitySoundName)
        defer {
            settings.replySoundName = saved.0
            settings.activitySoundName = saved.1
        }
        settings.replySoundName = "frying_pan"
        settings.activitySoundName = "yum_yum"

        #expect(NotificationSounds.resourceName(for: .reply) == "frying_pan")
        #expect(NotificationSounds.resourceName(for: .blip) == "yum_yum")
        #expect(NotificationSounds.resourceName(for: .zap) == NotificationSound.zap)

        settings.replySoundName = NotificationSound.none
        #expect(NotificationSounds.resourceName(for: .reply) == NotificationSound.none)
    }
}
