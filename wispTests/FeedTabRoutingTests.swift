import Foundation
import SwiftUI
import Testing
@testable import wisp

/// Unified-feed PR 2 gates (§10): one feed surface renders the OnlyFood
/// list or the general feed by kind; switching kind away from OnlyFood and
/// back issues no new REQ; the OnlyFood stack's destinations survive on
/// `feedPath`; the tab enum has no `home` / `onlyfood`; a feed-tab re-tap
/// pops to root on both kinds. Hermetic: the OnlyFood VM takes an injected
/// query, and the FeedViewModel case touches only `init`.
@MainActor
struct FeedTabRoutingTests {

    private let pubkey = String(repeating: "a", count: 64)

    private func food(id: String, createdAt: Int) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: String(repeating: "b", count: 64),
            kind: 1,
            createdAt: createdAt,
            tags: [["t", "foodstr"]],
            content: "yummy",
            sig: String(repeating: "0", count: 128)
        )
    }

    private func muteOnlyFilter() -> OnlyFoodFilter {
        OnlyFoodFilter(
            nowSeconds: { 2_000_000 },
            blockedPubkeys: OnlyFoodFilter.blockedPubkeys,
            isUserBlocked: { _ in false },
            containsMutedWord: { _ in false },
            isThreadMuted: { _ in false },
            isDeleted: { _ in false },
            isWotFiltered: { _ in false }
        )
    }

    private func freshPubkey() -> String {
        (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }

    // MARK: - §7.4 across the kind switch

    @Test func kindSwitch_awayFromOnlyFoodAndBack_issuesNoNewREQ_pullToRefreshDoes() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                calls += 1
                return OnlyFoodQueryResult(
                    events: [self.food(id: "g1", createdAt: 100)],
                    connected: true, anySent: true, eoseFired: true
                )
            },
            seedCache: { [] },
            persist: { _ in }
        )

        // Cold landing on OnlyFood: the appear hook starts the VM once.
        FeedTabRouting.ensureOnlyFoodStarted(kind: .onlyFood, onlyFood: vm)
        await vm.inFlight?.value
        #expect(calls == 1)
        #expect(vm.queryCount == 1)
        #expect(vm.notes.map(\.id) == ["g1"])

        // Away (Follows, Extended, a relay) and back: no new REQ.
        FeedTabRouting.ensureOnlyFoodStarted(kind: .follows, onlyFood: vm)
        FeedTabRouting.ensureOnlyFoodStarted(kind: .extendedNetwork, onlyFood: vm)
        FeedTabRouting.ensureOnlyFoodStarted(kind: .relay(url: "wss://nos.lol"), onlyFood: vm)
        FeedTabRouting.ensureOnlyFoodStarted(kind: .onlyFood, onlyFood: vm)
        // Tab re-appear while on OnlyFood: still no new REQ.
        FeedTabRouting.ensureOnlyFoodStarted(kind: .onlyFood, onlyFood: vm)
        await vm.inFlight?.value
        #expect(calls == 1)
        #expect(vm.queryCount == 1)
        #expect(vm.notes.map(\.id) == ["g1"])

        // Pull-to-refresh is the only re-query path.
        await vm.refreshAndWait()
        #expect(calls == 2)
        #expect(vm.queryCount == 2)
    }

    @Test func otherKinds_neverStartOnlyFood_noPrewarm() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                calls += 1
                return OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: true)
            },
            seedCache: { [] },
            persist: { _ in }
        )
        FeedTabRouting.ensureOnlyFoodStarted(kind: .follows, onlyFood: vm)
        FeedTabRouting.ensureOnlyFoodStarted(kind: .extendedNetwork, onlyFood: vm)
        await vm.inFlight?.value
        #expect(calls == 0)
        #expect(vm.queryCount == 0)
    }

    @Test func resumeHook_onlyResumesOnlyFood_andOnlyAfterStart() async {
        var calls = 0
        let vm = OnlyFoodFeedViewModel(
            pubkey: pubkey,
            filter: muteOnlyFilter(),
            query: { _ in
                calls += 1
                return OnlyFoodQueryResult(events: [], connected: true, anySent: true, eoseFired: true)
            },
            seedCache: { [] },
            persist: { _ in }
        )
        FeedTabRouting.resumeOnlyFoodIfActive(kind: .onlyFood, onlyFood: vm)
        #expect(calls == 0, "resume before start is a no-op")

        FeedTabRouting.ensureOnlyFoodStarted(kind: .onlyFood, onlyFood: vm)
        await vm.inFlight?.value
        #expect(calls == 1)

        FeedTabRouting.resumeOnlyFoodIfActive(kind: .follows, onlyFood: vm)
        await vm.inFlight?.value
        #expect(calls == 1, "not the active kind: no resume")

        FeedTabRouting.resumeOnlyFoodIfActive(kind: .onlyFood, onlyFood: vm)
        await vm.inFlight?.value
        #expect(calls == 2, "foreground on OnlyFood merges fresh on top")
    }

    // MARK: - Default landing renders the OnlyFood list

    @Test func coldStart_defaultLanding_rendersOnlyFoodBody_notPlaceholder() {
        let pk = freshPubkey()
        let key = FeedKindStore.typeKey(pk)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let vm = FeedViewModel(keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: pk))
        #expect(vm.currentKind == .onlyFood)
        #expect(FeedTabRouting.body(for: vm.currentKind) == .onlyFood)

        #expect(FeedTabRouting.body(for: .follows) == .general)
        #expect(FeedTabRouting.body(for: .extendedNetwork) == .general)
        #expect(FeedTabRouting.body(for: .relay(url: "wss://nos.lol")) == .general)
        let set = RelaySet(pubkey: pk, dTag: "cooks", name: "Cooks", relays: ["wss://nos.lol"], createdAt: 1)
        #expect(FeedTabRouting.body(for: .relaySet(set)) == .general)
    }

    // MARK: - Deep link from a food post into a recipe resolves on feedPath

    @Test func foodPostRecipeLink_resolvesOnFeedStack() {
        guard let recipe = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            return
        }
        // The card / embed tap pushes RecipeRoute onto whatever stack hosts
        // the card — on the merged surface, that is `feedPath`.
        var path = NavigationPath()
        ArticleTapRouting.appendCardTap(to: &path, event: recipe)
        #expect(path.count == 1)
        #expect(FeedTabRouting.feedStackRegisters(RecipeRoute.self))
        #expect(FeedTabRouting.feedStackRegisters(RecipeTagFeedRoute.self))

        // Nothing the deleted OnlyFood stack registered was lost.
        for type in FeedTabRouting.absorbedOnlyFoodStackRoutes {
            #expect(FeedTabRouting.feedStackRegisters(type), "\(type) missing from feedPath")
        }
    }

    // MARK: - Tab enum: no home / onlyfood; feed keeps the slot and icon

    @Test func bottomTab_hasNoHomeOrOnlyfood_feedKeepsSlotAndIcon() {
        let names = BottomTab.allCases.map(\.rawValue)
        #expect(!names.contains("home"))
        #expect(!names.contains("onlyfood"))
        #expect(names == ["recipes", "feed", "search", "kitchen", "notifications", "wallet", "messages"])
        #expect(BottomTab.bottomBarCases == [.recipes, .feed, .search, .kitchen, .notifications])
        #expect(BottomTab.feed.icon == "leaf")
        #expect(BottomTab.feed.selectedIcon == "leaf.fill")
        #expect(BottomTab.feed.title == "Feed")
    }

    // MARK: - Re-tap pops to root on both kinds

    @Test func feedTabRetap_popsToRoot_onBothKinds() {
        for kind in [FeedKind.onlyFood, .follows] {
            var path = NavigationPath()
            path.append(ProfileRoute(pubkey: pubkey))
            path.append(ThreadRoute(eventId: String(repeating: "e", count: 64), authorPubkey: pubkey))
            var trigger = 7
            FeedTabRouting.popFeedToRoot(kind: kind, path: &path, scrollToTopTrigger: &trigger)
            #expect(path.isEmpty, "\(kind) did not pop to root")
            #expect(trigger == 8, "\(kind) did not bump scroll-to-top")
        }
    }

    // MARK: - Compose FAB prefill (§8)

    @Test func composePrefill_isFoodstrOnOnlyFoodOnly() {
        #expect(FeedTabRouting.composePrefill(for: .onlyFood) == OnlyFoodCompose.prefill)
        #expect(FeedTabRouting.composePrefill(for: .follows) == nil)
        #expect(FeedTabRouting.composePrefill(for: .extendedNetwork) == nil)
        #expect(FeedTabRouting.composePrefill(for: .relay(url: "wss://nos.lol")) == nil)
    }
}
