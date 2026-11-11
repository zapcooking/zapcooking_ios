import Foundation

/// The "new users only" default for Fresh (ruling 2026-11-10).
///
/// Fresh becomes the landing feed for an account that never picked one, but
/// only for accounts that sign in after this build. Every account already on
/// the device with no stored feed kind gets `ONLY_FOOD` written once, so it
/// keeps the feed it had. Three safeguards make that write safe to rerun and
/// impossible to run on the wrong data:
///
/// 1. **Per-account marker.** When Fresh is applied as the default
///    (`FeedKindStore.resolveInitial`), `fresh_default_applied_<pubkey>` is
///    written. The migration skips any account carrying it, so if it ever ran
///    again (the device flag lost or renamed) it could not move a new user
///    who never picked a feed back to OnlyFood.
/// 2. **Protected data.** It runs only when the app can read its data (after
///    first unlock). Before that, `UserDefaults` can read as empty: the
///    account list would look empty, the flag would be set with nothing
///    written, and every existing user would land on Fresh. When it can't
///    run it does nothing and is retried (next launch, or when protected
///    data becomes available).
/// 3. **Wipe list.** `last_feed_type_`, `last_relay_url_`, `last_relay_set_`
///    and the marker are removed with the account (`NostrKey.deleteAccount`),
///    so a removed and re-added account starts as a new sign-in.
///
/// Until the migration has run, an account with no stored kind keeps the old
/// default (OnlyFood) and no marker is written: an account seen before the
/// write can't be mistaken for a new one.
///
/// It runs from `ContentView`'s first appearance, after the saved account is
/// registered in the account list and before any sign-in can add a new one.
/// On a fresh install the list is empty, so every account that follows is a
/// new sign-in.
enum FeedDefaultMigration {
    /// Device-wide: set once the write has run with protected data available.
    static let doneKey = "fresh_default_migration_v1_done"

    static func markerKey(_ pubkey: String) -> String { "fresh_default_applied_\(pubkey)" }

    static func isDone(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: doneKey)
    }

    static func hasFreshDefaultMarker(_ pubkey: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: markerKey(pubkey))
    }

    /// What one run did (tests).
    enum Outcome: Equatable {
        case alreadyDone
        case protectedDataUnavailable
        /// Ran: the accounts that got `ONLY_FOOD` written.
        case ran(wroteOnlyFood: [String])
    }

    /// The one-time write. `accounts` is the device's account list
    /// (`NostrKey.accounts()`).
    @discardableResult
    static func runIfNeeded(
        accounts: [String],
        protectedDataAvailable: Bool,
        defaults: UserDefaults = .standard
    ) -> Outcome {
        guard !isDone(defaults) else { return .alreadyDone }
        guard protectedDataAvailable else { return .protectedDataUnavailable }
        var wrote: [String] = []
        for pubkey in accounts {
            guard defaults.string(forKey: FeedKindStore.typeKey(pubkey)) == nil,
                  !hasFreshDefaultMarker(pubkey, defaults: defaults) else { continue }
            defaults.set(FeedKindStore.StoredType.onlyFood.rawValue, forKey: FeedKindStore.typeKey(pubkey))
            wrote.append(pubkey)
        }
        defaults.set(true, forKey: doneKey)
        return .ran(wroteOnlyFood: wrote)
    }
}
