import SwiftUI
import UIKit

@main
struct wispApp: App {
    @State private var settings = AppSettings.shared
    @State private var powPrefs = PowPreferences.shared
    @State private var audioPlayer = AudioPlayerStore.shared

    init() {
        #if DEBUG
        // Diagnostics for the once-per-session feed freeze: logs any >250ms
        // main-thread stall + the breadcrumb/note that triggered it. See
        // MainThreadWatchdog.swift. No-op in release.
        MainThreadWatchdog.shared.start()
        #endif
        NsecPasteGuard.setUp()
        try? ObjectBoxSetup.setUp()
        // Estimate device-clock skew so outgoing event `created_at` is correct even
        // when the wall clock is off (relays reject future timestamps). Re-syncs on
        // foreground entry, throttled inside NostrClock.
        NostrClock.bootstrap()
        Task {
            await ExchangeRateService.shared.refresh()
            await ExchangeRateCache.shared.updateFromService()
        }
        // Aggressively warm avatar cache for every profile we've ever persisted
        // so feed/profile/notifications surfaces render their avatars without a
        // network round-trip after the first launch.
        Task.detached(priority: .utility) {
            await AvatarPrefetcher.shared.sweepPersistedProfiles()
        }

        // Drop UIKit's 1pt hairline shadow under every UINavigationBar so views
        // that paint a custom toolbar background (e.g. ProfileView with a pinned
        // tab strip directly under the nav bar) read as one continuous header.
        // SwiftUI's `.toolbarBackground` doesn't expose shadow control.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    #if DEBUG
    /// Relay-driven verification hook: seed a watch-only login so harness
    /// screens (`-ThreadHarnessSeed` and friends) can run against real
    /// relay data without driving the sign-up UI. No-op once any account
    /// exists — a real login is never overwritten.
    private static func seedWatchOnlyLoginIfRequested() {
        guard let pk = launchValue(of: "-WatchOnlyLogin"), NostrKey.load() == nil else { return }
        NostrKey.saveWatchOnly(pubkey: pk, acceptance: .now())
        UserDefaults.standard.set(true, forKey: "onboarding_done_\(pk)")
    }

    /// Value following a launch flag, e.g. `-WatchOnlyLogin <pubkey>`.
    private static func launchValue(of flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ComposerDragHarness") {
                ComposerDragHarness()
            } else if ProcessInfo.processInfo.arguments.contains("-EmojiLibraryHarness") {
                EmojiLibraryHarness()
            } else if ProcessInfo.processInfo.arguments.contains("-EmojiReactionHarness") {
                EmojiReactionHarness()
            } else if ProcessInfo.processInfo.arguments.contains("-WalletAddressHarness") {
                WalletAddressHarness()
            } else {
                rootContent
            }
            #else
            rootContent
            #endif
        }
    }

    /// The real app. Split out so the DEBUG harness switch above stays a
    /// two-line branch instead of wrapping the whole modifier chain.
    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        let _ = Self.seedWatchOnlyLoginIfRequested()
        #endif
        RootContainer()
            .environment(settings)
            .environment(powPrefs)
            .environment(audioPlayer)
            .preferredColorScheme(settings.preferredColorScheme)
            // Keep the home indicator drawn over our own bottom bar
            // instead of leaving it to `.automatic`, which lets the
            // system dim or drop it. The window's interface style and
            // the palette are resolved from the same Appearance
            // preference, so the indicator's auto-chosen tint always
            // contrasts with the ground the bar is painted on.
            .persistentSystemOverlays(.visible)
            .onOpenURL { url in
                if url.scheme == "wisp", url.host == "share" {
                    let files = PendingShareStore.consumePendingFiles()
                    guard !files.isEmpty else { return }
                    // A text/link share stages one `.sharetext` file
                    // instead of media — see `ShareViewController`.
                    if let textFile = files.first(where: { $0.pathExtension == PendingShareStore.textFileExtension }),
                       let text = try? String(contentsOf: textFile, encoding: .utf8),
                       !text.isEmpty {
                        NotificationCenter.default.post(name: .pendingShareReceived, object: PendingShareItem(text: text))
                        return
                    }
                    let providers = files.compactMap { NSItemProvider(contentsOf: $0) }
                    guard !providers.isEmpty else { return }
                    NotificationCenter.default.post(name: .pendingShareReceived, object: PendingShareItem(providers: providers))
                    return
                }
            }
    }
}

private struct RootContainer: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let resolved = settings.resolveTheme(systemColorScheme: systemColorScheme, contrast: contrast)
        ResolvedThemeProxy.update(resolved)
        return ContentView()
            .environment(\.theme, resolved)
            .id("\(settings.colorScheme.rawValue)-\(systemColorScheme == .dark)-\(contrast == .increased)")
    }
}
