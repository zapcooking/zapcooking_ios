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
        #expect(FeedKindStore.defaultKind == .onlyFood)
        #expect(FeedKind.onlyFood.displayName == "OnlyFood")
    }

    // MARK: - FeedViewModel wiring (standard defaults, fresh pubkeys, no I/O)

    @Test func viewModel_coldStart_landsOnOnlyFood_andLeavesKeyUnset() {
        let pk = freshPubkey()
        let key = FeedKindStore.typeKey(pk)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let vm = FeedViewModel(keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: pk))
        #expect(vm.currentKind == .onlyFood)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
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
}
