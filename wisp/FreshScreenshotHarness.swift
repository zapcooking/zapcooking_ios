import Foundation

#if DEBUG
/// DEBUG-only launch arguments for `FreshScreenshotsUITests` (AGENTS.md
/// "Screenshots for UI changes"): the real app with a brand-new account that
/// can't publish, and invented content.
///
/// - `-FreshScreenshotAccount`: when no account is saved, create a
///   **watch-only** account with a random pubkey (it holds no private key, so
///   nothing can be signed or published; `RelayListRepair` skips watch-only
///   accounts too), with terms accepted and onboarding marked done. It is
///   created after `FeedDefaultMigration` has run, so it is a new sign-in and
///   lands on Fresh.
/// - `-FreshScreenshotNewAccount` (with the above): create a new one even
///   when an account is saved, for a brand-new account's first screen in each
///   orientation.
/// - `-FreshScreenshotFixtures`: Fresh reads `FreshScreenshotFixtures` (six
///   invented cooks, served by an in-app relay) instead of the feed relay;
///   no real user appears and nothing is stored.
/// - `-FreshVisitMarkSecondsAgo N`: set that account's last-visit mark to
///   now − N, so the "new since your last visit" divider has a place to go.
nonisolated enum FreshScreenshotHarness {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isOn: Bool { arguments.contains("-FreshScreenshotAccount") }

    static func intArgument(_ flag: String) -> Int? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return Int(arguments[i + 1])
    }

    static var usesFixtures: Bool { isOn && arguments.contains("-FreshScreenshotFixtures") }

    /// Returns the new watch-only account when one was created (the caller
    /// routes to it), nil otherwise. Applies the visit-mark argument to the
    /// account in use either way.
    @MainActor
    static func prepare(existing: Keypair?) -> Keypair? {
        guard isOn else { return nil }
        var created: Keypair?
        if existing == nil || arguments.contains("-FreshScreenshotNewAccount") {
            let pubkey = Hex.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            NostrKey.saveWatchOnly(pubkey: pubkey, acceptance: .now())
            NostrKey.markOnboardingComplete(pubkey: pubkey)
            created = NostrKey.load()
        }
        if let pubkey = (created ?? existing)?.pubkey,
           let ago = intArgument("-FreshVisitMarkSecondsAgo") {
            UserDefaults.standard.set(String(NostrClock.now() - ago), forKey: FreshLastVisit.key(pubkey: pubkey))
            FreshLastVisit.shared.resetSession()
        }
        return created
    }
}
extension FreshFeedViewModel {
    /// The screenshot run's view model (invented content), else nil.
    @MainActor
    static func screenshotFixture(pubkey: String) -> FreshFeedViewModel? {
        FreshScreenshotHarness.usesFixtures ? FreshScreenshotFixtures.viewModel(pubkey: pubkey) : nil
    }
}
#endif
