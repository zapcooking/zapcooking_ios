import Foundation
import Testing
@testable import wisp

/// Unified-feed PR 1 gate (§10): cold start with no saved key lands on
/// OnlyFood and leaves `last_feed_type_<pubkey>` unset; an explicit pick
/// writes it. Hermetic — UserDefaults suites are per-test, and the
/// `FeedViewModel` cases only exercise `init` and `selectOnlyFood()`, neither
/// of which opens a socket.
@MainActor
struct FeedKindStoreTests {

    private func freshDefaults() -> (UserDefaults, () -> Void) {
        let suite = "FeedKindStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func freshPubkey() -> String {
        (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }

    private func relaySet(pubkey: String, dTag: String = "cooks") -> RelaySet {
        RelaySet(pubkey: pubkey, dTag: dTag, name: "Cooks", relays: ["wss://nos.lol"], createdAt: 1)
    }

    // MARK: - Resolver

    @Test func coldStart_noSavedKey_landsOnOnlyFood_andDoesNotWrite() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        let landing = FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil }
        #expect(landing == .onlyFood)
        #expect(defaults.object(forKey: FeedKindStore.typeKey(pk)) == nil)
    }

    @Test func explicitPick_writesKey_andRoundTrips() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        FeedKindStore.persist(.follows, pubkey: pk, defaults: defaults)
        #expect(defaults.string(forKey: FeedKindStore.typeKey(pk)) == "FOLLOWS")
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil } == .follows)

        FeedKindStore.persist(.extendedNetwork, pubkey: pk, defaults: defaults)
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil } == .extendedNetwork)
    }

    @Test func explicitOnlyFood_isDistinctFromNeverChose() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        FeedKindStore.persist(.onlyFood, pubkey: pk, defaults: defaults)
        #expect(defaults.string(forKey: FeedKindStore.typeKey(pk)) == "ONLY_FOOD")
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil } == .onlyFood)
    }

    @Test func relay_restoresNormalizedUrl_andClearsRelaySetKey() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        defaults.set("stale", forKey: FeedKindStore.relaySetKey(pk))
        FeedKindStore.persist(.relay(url: "wss://nos.lol"), pubkey: pk, defaults: defaults)
        #expect(defaults.object(forKey: FeedKindStore.relaySetKey(pk)) == nil)
        let expected = Nip51Lists.normalize("wss://nos.lol")!
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil } == .relay(url: expected))
    }

    @Test func relay_withoutRestorableUrl_fallsBackToOnlyFood() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        defaults.set("RELAY", forKey: FeedKindStore.typeKey(pk))
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil } == .onlyFood)
        defaults.set("not a url", forKey: FeedKindStore.relayUrlKey(pk))
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil } == .onlyFood)
    }

    @Test func relaySet_restoresViaLookup_clearsUrlKey_andFallsBackWhenGone() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        let set = relaySet(pubkey: pk)
        defaults.set("wss://nos.lol", forKey: FeedKindStore.relayUrlKey(pk))
        FeedKindStore.persist(.relaySet(set), pubkey: pk, defaults: defaults)
        #expect(defaults.string(forKey: FeedKindStore.typeKey(pk)) == "RELAY_SET")
        #expect(defaults.string(forKey: FeedKindStore.relaySetKey(pk)) == "cooks")
        #expect(defaults.object(forKey: FeedKindStore.relayUrlKey(pk)) == nil)

        var asked: [String] = []
        let restored = FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { dTag in
            asked.append(dTag)
            return dTag == "cooks" ? set : nil
        }
        #expect(restored == .relaySet(set))
        #expect(asked == ["cooks"])

        // The set was deleted (on another client, say): fall back, don't strand.
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil } == .onlyFood)
    }

    @Test func unknownStoredName_fallsBackToOnlyFood_withoutRewriting() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        defaults.set("TRENDING", forKey: FeedKindStore.typeKey(pk))
        #expect(FeedKindStore.resolveInitial(pubkey: pk, defaults: defaults) { _ in nil } == .onlyFood)
        #expect(defaults.string(forKey: FeedKindStore.typeKey(pk)) == "TRENDING")
    }

    @Test func storedNames_areStable() {
        // On-disk contract: renaming any of these strands a saved choice.
        #expect(FeedKindStore.StoredType.onlyFood.rawValue == "ONLY_FOOD")
        #expect(FeedKindStore.StoredType.follows.rawValue == "FOLLOWS")
        #expect(FeedKindStore.StoredType.extendedNetwork.rawValue == "EXTENDED_FOLLOWS")
        #expect(FeedKindStore.StoredType.relay.rawValue == "RELAY")
        #expect(FeedKindStore.StoredType.relaySet.rawValue == "RELAY_SET")
        #expect(FeedKindStore.StoredType.fresh.rawValue == "FRESH")
        #expect(FeedKindStore.legacyDefaultKind == .onlyFood)
        #expect(FeedKindStore.defaultKind == .fresh)
        #expect(FeedKind.onlyFood.displayName == "OnlyFood")
    }

    // MARK: - FeedViewModel wiring (standard defaults, fresh pubkeys, no I/O)

    /// A sign-in after the one-time write (the hosted app ran it at launch;
    /// set here so the case does not depend on that).
    @Test func viewModel_coldStart_landsOnFresh_marksAndLeavesKeyUnset() {
        let pk = freshPubkey()
        let key = FeedKindStore.typeKey(pk)
        UserDefaults.standard.set(true, forKey: FeedDefaultMigration.doneKey)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: FeedDefaultMigration.markerKey(pk))
        }
        let vm = FeedViewModel(keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: pk))
        #expect(vm.currentKind == .fresh)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(FeedDefaultMigration.hasFreshDefaultMarker(pk))
    }

    /// Copilot review on #67: the same-kind guard in `selectOnlyFood()` must
    /// not swallow the persist when the VM is already on the cold-start
    /// default — that pick is the one that turns "never chose" into "chose".
    @Test func viewModel_explicitOnlyFoodOnDefaultLanding_writesKey() {
        let pk = freshPubkey()
        let key = FeedKindStore.typeKey(pk)
        UserDefaults.standard.set(true, forKey: FeedDefaultMigration.doneKey)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: FeedDefaultMigration.markerKey(pk))
        }
        let vm = FeedViewModel(keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: pk))
        #expect(vm.currentKind == .fresh)
        #expect(UserDefaults.standard.object(forKey: key) == nil)

        vm.selectOnlyFood()
        #expect(vm.currentKind == .onlyFood)
        #expect(UserDefaults.standard.string(forKey: key) == "ONLY_FOOD")

        // A later cold start now restores an explicit choice, not the default.
        let again = FeedViewModel(keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: pk))
        #expect(again.currentKind == .onlyFood)
        #expect(UserDefaults.standard.string(forKey: key) == "ONLY_FOOD")
    }

    @Test func viewModel_restoresSavedPick_andExplicitOnlyFoodWritesKey() {
        let pk = freshPubkey()
        let key = FeedKindStore.typeKey(pk)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("FOLLOWS", forKey: key)
        let vm = FeedViewModel(keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: pk))
        #expect(vm.currentKind == .follows)

        vm.selectOnlyFood()
        #expect(vm.currentKind == .onlyFood)
        #expect(UserDefaults.standard.string(forKey: key) == "ONLY_FOOD")
        #expect(vm.events.isEmpty)
    }

    // MARK: - The Fresh default for new users (FeedDefaultMigration)

    private func resolve(_ pk: String, _ d: UserDefaults, fresh: Bool = true) -> FeedKind {
        FeedKindStore.resolveInitial(pubkey: pk, defaults: d, freshEnabled: fresh) { _ in nil }
    }

    @Test func neverChose_existingAccount_getsOnlyFoodWrittenOnce() {
        let (d, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        #expect(FeedDefaultMigration.runIfNeeded(accounts: [pk], protectedDataAvailable: true, defaults: d)
                == .ran(wroteOnlyFood: [pk]))
        #expect(d.string(forKey: FeedKindStore.typeKey(pk)) == "ONLY_FOOD")
        #expect(resolve(pk, d) == .onlyFood)
        #expect(!FeedDefaultMigration.hasFreshDefaultMarker(pk, defaults: d))
    }

    @Test func choseOnlyFood_andChoseFollows_areKept() {
        let (d, cleanup) = freshDefaults(); defer { cleanup() }
        let food = freshPubkey(), follows = freshPubkey()
        FeedKindStore.persist(.onlyFood, pubkey: food, defaults: d)
        FeedKindStore.persist(.follows, pubkey: follows, defaults: d)
        #expect(FeedDefaultMigration.runIfNeeded(accounts: [food, follows], protectedDataAvailable: true, defaults: d)
                == .ran(wroteOnlyFood: []))
        #expect(resolve(food, d) == .onlyFood)
        #expect(resolve(follows, d) == .follows)
        #expect(d.string(forKey: FeedKindStore.typeKey(follows)) == "FOLLOWS")
    }

    @Test func newSignIn_afterTheWrite_landsOnFresh_andIsMarked() {
        let (d, cleanup) = freshDefaults(); defer { cleanup() }
        // Fresh install: no accounts when the write runs.
        #expect(FeedDefaultMigration.runIfNeeded(accounts: [], protectedDataAvailable: true, defaults: d)
                == .ran(wroteOnlyFood: []))
        let pk = freshPubkey()
        #expect(resolve(pk, d) == .fresh)
        #expect(d.string(forKey: FeedKindStore.typeKey(pk)) == nil, "applying the default never writes the kind")
        #expect(FeedDefaultMigration.hasFreshDefaultMarker(pk, defaults: d))
        #expect(resolve(pk, d) == .fresh)
    }

    @Test func theWrite_neverRunsTwice_andARerunCannotMoveANewUser() {
        let (d, cleanup) = freshDefaults(); defer { cleanup() }
        let old = freshPubkey()
        _ = FeedDefaultMigration.runIfNeeded(accounts: [old], protectedDataAvailable: true, defaults: d)
        let new = freshPubkey()
        #expect(resolve(new, d) == .fresh)
        #expect(FeedDefaultMigration.runIfNeeded(accounts: [old, new], protectedDataAvailable: true, defaults: d)
                == .alreadyDone)
        #expect(resolve(new, d) == .fresh)

        // Even if the device flag is lost (or a later build renames it), the
        // per-account marker keeps the new user on Fresh.
        d.removeObject(forKey: FeedDefaultMigration.doneKey)
        #expect(FeedDefaultMigration.runIfNeeded(accounts: [old, new], protectedDataAvailable: true, defaults: d)
                == .ran(wroteOnlyFood: []))
        #expect(d.string(forKey: FeedKindStore.typeKey(new)) == nil)
        #expect(resolve(new, d) == .fresh)
        #expect(resolve(old, d) == .onlyFood)
    }

    @Test func protectedDataUnavailable_writesNothing_setsNoFlag_andExistingUsersKeepOnlyFood() {
        let (d, cleanup) = freshDefaults(); defer { cleanup() }
        let pk = freshPubkey()
        #expect(FeedDefaultMigration.runIfNeeded(accounts: [], protectedDataAvailable: false, defaults: d)
                == .protectedDataUnavailable)
        #expect(!FeedDefaultMigration.isDone(d))
        // Not done: an account with no stored kind keeps the old default and
        // is not marked, so it can't be mistaken for a new sign-in.
        #expect(resolve(pk, d) == .onlyFood)
        #expect(!FeedDefaultMigration.hasFreshDefaultMarker(pk, defaults: d))
        // Later, with the account list readable: the write runs.
        #expect(FeedDefaultMigration.runIfNeeded(accounts: [pk], protectedDataAvailable: true, defaults: d)
                == .ran(wroteOnlyFood: [pk]))
        #expect(resolve(pk, d) == .onlyFood)
    }

    @Test func freshOff_neverChoseLandsOnOnlyFood_andAStoredFreshFallsBack() {
        let (d, cleanup) = freshDefaults(); defer { cleanup() }
        _ = FeedDefaultMigration.runIfNeeded(accounts: [], protectedDataAvailable: true, defaults: d)
        let pk = freshPubkey()
        #expect(resolve(pk, d, fresh: false) == .onlyFood)
        #expect(!FeedDefaultMigration.hasFreshDefaultMarker(pk, defaults: d))
        FeedKindStore.persist(.fresh, pubkey: pk, defaults: d)
        #expect(resolve(pk, d, fresh: false) == .onlyFood)
        #expect(resolve(pk, d, fresh: true) == .fresh)
    }

    @Test func unrestorableStoredChoice_fallsBackToOnlyFood_notFresh() {
        let (d, cleanup) = freshDefaults(); defer { cleanup() }
        _ = FeedDefaultMigration.runIfNeeded(accounts: [], protectedDataAvailable: true, defaults: d)
        let pk = freshPubkey()
        d.set("RELAY", forKey: FeedKindStore.typeKey(pk))
        #expect(resolve(pk, d) == .onlyFood)
        d.set("TRENDING", forKey: FeedKindStore.typeKey(pk))
        #expect(resolve(pk, d) == .onlyFood)
    }

    @Test func accountWipe_removesTheFeedKindAndTheMarker() {
        let pk = freshPubkey()
        let d = UserDefaults.standard
        d.set("FOLLOWS", forKey: FeedKindStore.typeKey(pk))
        d.set("wss://nos.lol", forKey: FeedKindStore.relayUrlKey(pk))
        d.set("cooks", forKey: FeedKindStore.relaySetKey(pk))
        d.set(true, forKey: FeedDefaultMigration.markerKey(pk))
        NostrKey.deleteAccount(pubkey: pk)
        #expect(d.object(forKey: FeedKindStore.typeKey(pk)) == nil)
        #expect(d.object(forKey: FeedKindStore.relayUrlKey(pk)) == nil)
        #expect(d.object(forKey: FeedKindStore.relaySetKey(pk)) == nil)
        #expect(d.object(forKey: FeedDefaultMigration.markerKey(pk)) == nil)
    }
}
