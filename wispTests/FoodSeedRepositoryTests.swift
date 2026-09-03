import Foundation
import Testing
@testable import wisp

/// Pure-helper coverage for the sign-up creator seed (Concern C-J). The relay
/// fetch itself is live and stays out of the hermetic run.
@MainActor
struct FoodSeedRepositoryTests {

    private let curator = ZapCookingCurator.pubkey
    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)
    private let carol = String(repeating: "c", count: 64)
    private let other = String(repeating: "d", count: 64)

    private func kind3(pubkey: String, createdAt: Int, follows: [[String]], kind: Int = 3) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "e", count: 64),
            pubkey: pubkey,
            kind: kind,
            createdAt: createdAt,
            tags: follows,
            content: "",
            sig: ""
        )
    }

    @Test func parseSeed_takesNewestCuratorKind3_andDedupes() {
        let older = kind3(pubkey: curator, createdAt: 100, follows: [["p", alice]])
        let newest = kind3(pubkey: curator, createdAt: 200, follows: [
            ["p", bob], ["p", carol], ["p", bob], ["p", alice.uppercased()]
        ])
        let seed = FoodSeedRepository.parseSeed(from: [older, newest])
        #expect(seed == [bob, carol, alice])
    }

    @Test func parseSeed_ignoresOtherAuthors_otherKinds_andBadTags() {
        let impostor = kind3(pubkey: other, createdAt: 900, follows: [["p", other]])
        let notAFollowList = kind3(pubkey: curator, createdAt: 950, follows: [["p", other]], kind: 1)
        let real = kind3(pubkey: curator, createdAt: 300, follows: [
            ["p", alice],
            ["p", curator],            // self-follow dropped
            ["p", "not-a-pubkey"],     // not 64-hex
            ["p"],                     // malformed
            ["t", bob],                // wrong tag
            ["p", bob, "wss://relay.example", "petname"]
        ])
        let seed = FoodSeedRepository.parseSeed(from: [impostor, notAFollowList, real])
        #expect(seed == [alice, bob])
    }

    @Test func parseSeed_isEmptyWithoutACuratorFollowList() {
        #expect(FoodSeedRepository.parseSeed(from: []).isEmpty)
        let only = kind3(pubkey: other, createdAt: 1, follows: [["p", alice]])
        #expect(FoodSeedRepository.parseSeed(from: [only]).isEmpty)
    }

    @Test func creatorOrder_putsCuratorFirst_dedupes_andCaps() {
        let order = FoodSeedRepository.creatorOrder(seed: [alice, curator, bob, alice, carol], cap: 3)
        #expect(order == [curator, alice, bob])
        #expect(FoodSeedRepository.creatorOrder(seed: [], cap: 24) == [curator])
    }

    @Test func curatorFallbackProfile_readsAsZapCooking() {
        let profile = FoodSeedRepository.curatorFallbackProfile
        #expect(profile.pubkey == curator)
        #expect(profile.displayString == "Zap Cooking")
    }

    @Test func cachedSeed_isReadBackFromDefaults() {
        let suite = "FoodSeedRepositoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FoodSeedRepository(defaults: defaults).pubkeys.isEmpty)
        defaults.set([alice, bob], forKey: "zc_food_seed_pubkeys")
        #expect(FoodSeedRepository(defaults: defaults).pubkeys == [alice, bob])
    }
}
