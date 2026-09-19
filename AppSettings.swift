import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    /// Appearance, and the only theme control left in Interface settings
    /// now that the accent picker and the selectable presets are gone.
    enum ColorSchemePreference: String, CaseIterable {
        case system, light, dark
    }

    enum MediaLayoutStyle: String, CaseIterable {
        /// 2+ media items in a post render as a horizontal gallery (default).
        case grid
        /// 2+ media items render as a vertical stack — the original behaviour.
        case stack
    }

    /// The one zap glyph. Android draws a bolt everywhere and offers no
    /// choice, so the bitcoinsign alternative and the fiat-mode coin stack
    /// both went with the Interface settings pickers that fed them.
    nonisolated static let zapSymbol = "bolt.fill"

    private struct Keys {
        static let largeText = "wisp_settings_large_text"
        static let colorScheme = "wisp_settings_color_scheme"
        static let autoLoadMedia = "wisp_settings_auto_load_media"
        static let videoAutoplay = "wisp_settings_video_autoplay"
        static let animateAvatars = "wisp_settings_animate_avatars"
        static let mediaLayoutStyle = "wisp_settings_media_layout_style"
        static let clientTagEnabled = "wisp_settings_client_tag_enabled"
        static let fiatCurrency = "wisp_settings_fiat_currency"
        static let notificationSoundsEnabled = "wisp_settings_notification_sounds_enabled"
        static let postUndoTimerEnabled = "wisp_settings_post_undo_timer_enabled"
        static let postUndoTimerSeconds = "wisp_settings_post_undo_timer_seconds"
        static let postUndoTimerForReplies = "wisp_settings_post_undo_timer_for_replies"
        static let autoApproveRelayAuth = "wisp_settings_auto_approve_relay_auth"
        static let videoLoop = "wisp_settings_video_loop"
        static let autoTranslate = "wisp_settings_auto_translate"
        static let includeRepliesInFeed = "wisp_settings_include_replies_in_feed"
        static func quickZapEnabled(for pubkey: String?) -> String {
            pubkey.map { "wisp_settings_quick_zap_enabled_\($0)" } ?? "wisp_settings_quick_zap_enabled"
        }
        static func quickZapAmountSats(for pubkey: String?) -> String {
            pubkey.map { "wisp_settings_quick_zap_amount_sats_\($0)" } ?? "wisp_settings_quick_zap_amount_sats"
        }
        static func quickZapMessage(for pubkey: String?) -> String {
            pubkey.map { "wisp_settings_quick_zap_message_\($0)" } ?? "wisp_settings_quick_zap_message"
        }
    }

    /// Allowed durations for the post-undo countdown. Picker shows these as
    /// the granularity for the slider/segmented control in InterfaceSettings.
    static let postUndoTimerOptions: [Int] = [5, 10, 15, 20, 30]

    /// Brand primary, dark side: web `src/app.css` `html.dark --color-primary`
    /// and Android `Themes.kt` default `primary` (#FF5722). The light side
    /// (#EC4700) lives on the `custom` preset's light palette. Was Wisp's
    /// #FF9800 until the brand-color-parity concern.
    nonisolated static let defaultAccentARGB: Int = 0xFFFF5722

    var largeText: Bool {
        didSet { UserDefaults.standard.set(largeText, forKey: Keys.largeText) }
    }
    var colorScheme: ColorSchemePreference {
        didSet { UserDefaults.standard.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }
    var autoLoadMedia: Bool {
        didSet { UserDefaults.standard.set(autoLoadMedia, forKey: Keys.autoLoadMedia) }
    }
    var videoAutoplay: Bool {
        didSet { UserDefaults.standard.set(videoAutoplay, forKey: Keys.videoAutoplay) }
    }
    var animateAvatars: Bool {
        didSet { UserDefaults.standard.set(animateAvatars, forKey: Keys.animateAvatars) }
    }
    var mediaLayoutStyle: MediaLayoutStyle {
        didSet { UserDefaults.standard.set(mediaLayoutStyle.rawValue, forKey: Keys.mediaLayoutStyle) }
    }
    var clientTagEnabled: Bool {
        didSet { UserDefaults.standard.set(clientTagEnabled, forKey: Keys.clientTagEnabled) }
    }
    /// Currency for the wallet dashboard's fiat display (tap the balance to
    /// cycle sats → fiat → hidden) and the transaction rows. There is no
    /// app-wide fiat mode any more — zap and post surfaces are always sats.
    var fiatCurrency: String {
        didSet { UserDefaults.standard.set(fiatCurrency, forKey: Keys.fiatCurrency) }
    }
    var notificationSoundsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationSoundsEnabled, forKey: Keys.notificationSoundsEnabled) }
    }
    /// When true, publishing a top-level post (and optionally replies — see
    /// `postUndoTimerForReplies`) waits `postUndoTimerSeconds` before sending,
    /// giving the user a chance to cancel.
    var postUndoTimerEnabled: Bool {
        didSet { UserDefaults.standard.set(postUndoTimerEnabled, forKey: Keys.postUndoTimerEnabled) }
    }
    var postUndoTimerSeconds: Int {
        didSet { UserDefaults.standard.set(postUndoTimerSeconds, forKey: Keys.postUndoTimerSeconds) }
    }
    /// When false, replies skip the undo countdown and publish immediately —
    /// the default. Top-level posts still respect `postUndoTimerEnabled`.
    var postUndoTimerForReplies: Bool {
        didSet { UserDefaults.standard.set(postUndoTimerForReplies, forKey: Keys.postUndoTimerForReplies) }
    }
    /// When true (default), AUTH challenges from relays are signed and sent automatically
    /// without prompting. When false, each relay must be individually approved in relay settings.
    var autoApproveRelayAuth: Bool {
        didSet { UserDefaults.standard.set(autoApproveRelayAuth, forKey: Keys.autoApproveRelayAuth) }
    }
    var videoLoop: Bool {
        didSet { UserDefaults.standard.set(videoLoop, forKey: Keys.videoLoop) }
    }
    /// When true, notes that aren't in the device language are translated
    /// automatically as they render. Mirrors Android's "auto_translate".
    var autoTranslate: Bool {
        didSet { UserDefaults.standard.set(autoTranslate, forKey: Keys.autoTranslate) }
    }
    /// When true, the Follows feed shows replies from followed authors,
    /// rendered with their "Replying to …" context row. Off by default —
    /// replies are stripped from the feed, the original behaviour.
    var includeRepliesInFeed: Bool {
        didSet {
            UserDefaults.standard.set(includeRepliesInFeed, forKey: Keys.includeRepliesInFeed)
            guard oldValue != includeRepliesInFeed else { return }
            NotificationCenter.default.post(name: .feedRepliesSettingChanged, object: nil)
        }
    }
    /// When true, a single tap of the zap button on a post sends the configured
    /// amount immediately. Long-press still opens the zap composer. Surfaces in
    /// settings as "Instant zaps". Disabled by default — the previous
    /// behaviour (tap → composer) is preserved unless the user opts in.
    var quickZapEnabled: Bool {
        didSet {
            let pk = NostrKey.load()?.pubkey
            UserDefaults.standard.set(quickZapEnabled, forKey: Keys.quickZapEnabled(for: pk))
        }
    }
    /// Instant-zap amount in sats.
    var quickZapAmountSats: Int64 {
        didSet {
            let pk = NostrKey.load()?.pubkey
            UserDefaults.standard.set(quickZapAmountSats, forKey: Keys.quickZapAmountSats(for: pk))
        }
    }
    /// Optional default message included on an instant zap / payment. Empty
    /// string means "no message" — the zap fires with `content: ""` exactly
    /// as the composer's blank state would produce. Persisted per account
    /// (device-local; NIP-78 cross-device sync deferred — see #70).
    var quickZapMessage: String {
        didSet {
            let pk = NostrKey.load()?.pubkey
            UserDefaults.standard.set(quickZapMessage, forKey: Keys.quickZapMessage(for: pk))
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.largeText = defaults.object(forKey: Keys.largeText) as? Bool ?? false
        let csRaw = defaults.string(forKey: Keys.colorScheme) ?? ColorSchemePreference.dark.rawValue
        self.colorScheme = ColorSchemePreference(rawValue: csRaw) ?? .dark
        self.autoLoadMedia = defaults.object(forKey: Keys.autoLoadMedia) as? Bool ?? true
        self.videoAutoplay = defaults.object(forKey: Keys.videoAutoplay) as? Bool ?? true
        self.animateAvatars = defaults.object(forKey: Keys.animateAvatars) as? Bool ?? true
        let layoutRaw = defaults.string(forKey: Keys.mediaLayoutStyle) ?? MediaLayoutStyle.grid.rawValue
        self.mediaLayoutStyle = MediaLayoutStyle(rawValue: layoutRaw) ?? .grid
        self.clientTagEnabled = defaults.object(forKey: Keys.clientTagEnabled) as? Bool ?? true
        self.fiatCurrency = defaults.string(forKey: Keys.fiatCurrency) ?? "USD"
        self.notificationSoundsEnabled = defaults.object(forKey: Keys.notificationSoundsEnabled) as? Bool ?? true
        self.postUndoTimerEnabled = defaults.object(forKey: Keys.postUndoTimerEnabled) as? Bool ?? true
        let storedSeconds = defaults.object(forKey: Keys.postUndoTimerSeconds) as? Int ?? 10
        self.postUndoTimerSeconds = Self.postUndoTimerOptions.contains(storedSeconds) ? storedSeconds : 10
        self.postUndoTimerForReplies = defaults.object(forKey: Keys.postUndoTimerForReplies) as? Bool ?? false
        self.autoApproveRelayAuth = defaults.object(forKey: Keys.autoApproveRelayAuth) as? Bool ?? true
        self.videoLoop = defaults.object(forKey: Keys.videoLoop) as? Bool ?? true
        self.autoTranslate = defaults.object(forKey: Keys.autoTranslate) as? Bool ?? false
        self.includeRepliesInFeed = defaults.object(forKey: Keys.includeRepliesInFeed) as? Bool ?? false
        let qzPubkey = NostrKey.load()?.pubkey
        self.quickZapEnabled = defaults.object(forKey: Keys.quickZapEnabled(for: qzPubkey)) as? Bool ?? false
        let storedQuickInt = defaults.integer(forKey: Keys.quickZapAmountSats(for: qzPubkey))
        self.quickZapAmountSats = storedQuickInt > 0 ? Int64(storedQuickInt) : 21
        self.quickZapMessage = defaults.string(forKey: Keys.quickZapMessage(for: qzPubkey)) ?? ""
    }

    /// Load per-account instant-zap settings from UserDefaults. Falls back to
    /// defaults (21 sats / disabled / no message) when no value
    /// has been stored for this pubkey yet. Call on every account switch so
    /// each account's preferences are isolated.
    func loadQuickZapSettings(for pubkey: String) {
        let defaults = UserDefaults.standard
        quickZapEnabled = defaults.object(forKey: Keys.quickZapEnabled(for: pubkey)) as? Bool ?? false
        let storedSats = defaults.integer(forKey: Keys.quickZapAmountSats(for: pubkey))
        quickZapAmountSats = storedSats > 0 ? Int64(storedSats) : 21
        quickZapMessage = defaults.string(forKey: Keys.quickZapMessage(for: pubkey)) ?? ""
    }

    /// SF Symbol name for the zap icon — always the bolt.
    nonisolated var zapSymbolName: String { Self.zapSymbol }

    /// The zap icon, ready to render.
    nonisolated var zapImage: Image { Image(systemName: Self.zapSymbol) }

    /// What the window's interface style is pinned to. `nil` for System
    /// hands it back to the device — and `resolveTheme` reads the same
    /// device value, so the palette and the system chrome (home indicator,
    /// status bar) always agree whichever option is chosen.
    var preferredColorScheme: ColorScheme? {
        switch colorScheme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// `nonisolated` — these initializers and `hex(_:)` are pure value transforms
// (Int → Color), used at module-load time by `Themes` and from any actor.
nonisolated extension Color {
    init(argb: Int) {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a == 0 ? 1 : a)
    }

    init(rgb: Int) {
        self.init(argb: 0xFF000000 | (rgb & 0x00FFFFFF))
    }

    static func hex(_ argb: UInt32) -> Color {
        Color(argb: Int(bitPattern: UInt(argb)))
    }
}

extension Notification.Name {
    /// Posted by `AppSettings.includeRepliesInFeed.didSet` when the value
    /// actually changes. `FeedViewModel` re-filters the Follows feed in place.
    static let feedRepliesSettingChanged = Notification.Name("WispFeedRepliesSettingChanged")
}
