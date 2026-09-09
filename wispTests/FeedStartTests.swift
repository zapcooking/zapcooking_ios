import Foundation
import Testing
@testable import wisp

/// Unified-feed PR 1 review gate: `FeedViewModel.start()` is idempotent on the
/// OnlyFood landing (the default for every user), and the event-store prune
/// runs there. Hermetic — every side-effecting collaborator of the setup block
/// is injected through `StartupServices` and counted; nothing opens a socket.
@MainActor
struct FeedStartTests {

    final class Calls {
        var metrics = 0
        var discovery: [String] = []
        var registered: [UUID] = []
        var unregistered: [UUID] = []
        var bootstraps: [String] = []
        var prunes: [String] = []
        var indexerQueries = 0
    }

    private func freshPubkey() -> String {
        (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }

    private func makeVM(pubkey: String) -> (FeedViewModel, Calls) {
        let calls = Calls()
        let services = FeedViewModel.StartupServices(
            liveMetrics: {
                calls.metrics += 1
                return AsyncStream { $0.finish() }
            },
            startLiveDiscovery: { calls.discovery.append($0) },
            registerSweepSource: { _ in
                let id = UUID()
                calls.registered.append(id)
                return id
            },
            unregisterSweepSource: { calls.unregistered.append($0) },
            bootstrapRelaySets: { calls.bootstraps.append($0.pubkey) },
            pruneEventStore: { calls.prunes.append($0) },
            queryIndexers: { _ in
                calls.indexerQueries += 1
                return []
            }
        )
        let kp = Keypair(privkey: String(repeating: "1", count: 64), pubkey: pubkey)
        return (FeedViewModel(keypair: kp, services: services), calls)
    }

    /// The bootstrap and prune are fire-and-forget `Task`s off `start()`;
    /// give them a few main-actor turns to land.
    private func settle(_ done: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func onlyFoodLanding_startTwice_runsSharedSetupOnce() async {
        let pk = freshPubkey()
        let (vm, calls) = makeVM(pubkey: pk)
        #expect(vm.currentKind == .onlyFood)

        await vm.start()
        await vm.start()
        await settle { calls.bootstraps.count >= 1 && calls.prunes.count >= 1 }

        #expect(vm.didStart)
        #expect(vm.isLoading == false)
        #expect(calls.registered.count == 1, "sweep source registered exactly once")
        #expect(calls.metrics == 1, "one metrics socket, no orphaned metricsTask")
        #expect(calls.bootstraps == [pk], "relay-set bootstrap fired once")
        #expect(calls.discovery == [pk], "live discovery kicked once")
        #expect(calls.prunes == [pk], "event-store prune ran once")
        #expect(calls.indexerQueries == 2, "profile + contacts refresh, once")

        vm.stop()
        #expect(calls.unregistered == calls.registered, "stop() unregisters the one source")

        // The latch is for the VM's lifetime (main's parity: a populated
        // Follows list held it across stop/start too).
        await vm.start()
        #expect(calls.registered.count == 1)
        #expect(calls.metrics == 1)
        #expect(calls.bootstraps.count == 1)
    }

    @Test func onlyFoodLanding_runsEventStorePrune_protectingOwnPubkey() async {
        let pk = freshPubkey()
        let (vm, calls) = makeVM(pubkey: pk)

        await vm.start()
        await settle { !calls.prunes.isEmpty }

        #expect(calls.prunes == [pk])
        vm.stop()
    }

    @Test func onlyFoodLanding_doesNotStartFollowsOrRelayWork() async {
        let pk = freshPubkey()
        let (vm, calls) = makeVM(pubkey: pk)

        await vm.start()
        await settle { !calls.prunes.isEmpty }

        #expect(vm.events.isEmpty)
        #expect(vm.relayFeedStatus == .idle)
        #expect(vm.connectedRelayCount == 0)
        vm.stop()
    }
}
