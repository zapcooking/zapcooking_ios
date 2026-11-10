import Foundation
import Testing
@testable import wisp

/// PR #172 review follow-ups that are reachable without a network seam.
///
/// Covered here: the archive zap scan's repository contract
/// (`LiveStreamRepository.addArchivedZaps`) and the "Show live streams"
/// switch (`LiveStreamViewModel.start()`'s guard, and
/// `FeedViewModel.liveContentSettingChanged` / `refreshLiveDiscovery`).
///
/// Not covered: chat history paging (`loadOlderMessages`) and `start()`'s
/// cancellation guards. Both run behind `RelayPool.queryDetailed` /
/// `RelayPool.query` / `RelayListRepository` called directly, and paging is
/// additionally gated on the private `started` latch that only a real
/// `start()` sets — testing them needs an injectable query seam.
@MainActor
@Suite(.serialized)
struct LiveStreamReviewTests {

    // MARK: Fixtures

    private static let host = String(repeating: "ab", count: 32)
    private static let zapper = String(repeating: "cd", count: 32)
    private static let dTag = "review-172"
    private var aTag: String { Nip53.aTagValue(host: Self.host, dTag: Self.dTag) }

    /// `Bolt11.decode` reads the amount from the HRP and needs at least
    /// 7 + 104 data characters; it does not verify the checksum.
    private static let invoice = "lnbc10u1" + String(repeating: "q", count: 120)

    private func eventId(_ n: Int) -> String {
        String(format: "%064x", n)
    }

    private func zapReceipt(_ n: Int, createdAt: Int) -> NostrEvent {
        let request = #"{"pubkey":"\#(Self.zapper)","content":"","kind":9734}"#
        return NostrEvent(
            id: eventId(n), pubkey: String(repeating: "ef", count: 32), kind: 9735,
            createdAt: createdAt,
            tags: [["a", aTag], ["bolt11", Self.invoice], ["description", request]],
            content: "", sig: ""
        )
    }

    private func chatMessage(_ n: Int, createdAt: Int) -> NostrEvent {
        NostrEvent(
            id: eventId(n), pubkey: Self.zapper, kind: Nip53.kindLiveChatMessage,
            createdAt: createdAt, tags: [["a", aTag]], content: "hi \(n)", sig: ""
        )
    }

    private func liveActivity() -> NostrEvent {
        NostrEvent(
            id: eventId(9_000), pubkey: Self.host, kind: Nip53.kindLiveActivity,
            createdAt: Int(Date().timeIntervalSince1970),
            tags: [["d", Self.dTag], ["status", "live"], ["streaming", "https://example.com/live.m3u8"]],
            content: "", sig: ""
        )
    }

    private func zapAmount() throws -> Int64 {
        let sats = Nip57.zapAmountSats(receipt: zapReceipt(0, createdAt: 0))
        try #require(sats > 0, "fixture invoice must decode to a positive amount")
        return sats
    }

    /// Runs `body` with the switch forced, then restores it (and removes the
    /// key again if it was unset, since `didSet` writes it through).
    private func withLiveContent(_ on: Bool, _ body: () async throws -> Void) async rethrows {
        let key = "wisp_settings_shows_live_content"
        let wasStored = UserDefaults.standard.object(forKey: key) != nil
        let original = AppSettings.shared.showsLiveContent
        AppSettings.shared.showsLiveContent = on
        defer {
            AppSettings.shared.showsLiveContent = original
            if !wasStored { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    private func makeFeedVM() -> (FeedViewModel, () -> [String]) {
        final class Calls { var discovery: [String] = [] }
        let calls = Calls()
        let services = FeedViewModel.StartupServices(
            startLiveDiscovery: { calls.discovery.append($0) },
            registerSweepSource: { _ in UUID() },
            unregisterSweepSource: { _ in },
            bootstrapRelaySets: { _ in },
            pruneEventStore: { _ in },
            queryIndexers: { _ in [] },
            openFollowsSubscription: { _, id, _ in RelaySubscription(id: id) }
        )
        let kp = Keypair(privkey: String(repeating: "1", count: 64), pubkey: Self.host)
        return (FeedViewModel(keypair: kp, services: services), { calls.discovery })
    }

    // MARK: Zap scan

    /// Receipts older than the loaded chat add to the total but never become
    /// chat rows; receipts as recent as the oldest loaded chat (inclusive)
    /// become announcements, and each receipt is counted exactly once.
    @Test func zapScan_oldReceiptsCountButOnlyRecentOnesAnnounce() throws {
        let sats = try zapAmount()
        let repo = LiveStreamRepository()
        #expect(repo.addChatMessage(chatMessage(1, createdAt: 1_000)))

        let old = zapReceipt(10, createdAt: 500)
        let boundary = zapReceipt(11, createdAt: 1_000)
        let recent = zapReceipt(12, createdAt: 1_500)
        repo.addArchivedZaps([old, boundary, recent], aTag: aTag, announceFrom: 1_000)

        #expect(repo.streamZapTotalsSats[aTag] == sats * 3)
        let rows = repo.messages(for: aTag)
        let announced = Set(rows.filter(\.isZapAnnouncement).map(\.id))
        #expect(announced == ["zap-\(boundary.id)", "zap-\(recent.id)"])
        #expect(!rows.contains { $0.id == "zap-\(old.id)" })
        #expect(rows.filter { !$0.isZapAnnouncement }.map(\.id) == [eventId(1)])
    }

    /// A rescan, or a receipt the live zap subscription already delivered,
    /// does not count twice — old or recent.
    @Test func zapScan_dedupesAgainstRescansAndTheLiveSubscription() throws {
        let sats = try zapAmount()
        let repo = LiveStreamRepository()
        #expect(repo.addChatMessage(chatMessage(1, createdAt: 1_000)))

        let old = zapReceipt(10, createdAt: 500)
        let live = zapReceipt(12, createdAt: 1_500)
        repo.addStreamZap(live, aTag: aTag)  // the live zap sub saw it first
        repo.addArchivedZaps([old, live], aTag: aTag, announceFrom: 1_000)
        repo.addArchivedZaps([old, live], aTag: aTag, announceFrom: 1_000)

        #expect(repo.streamZapTotalsSats[aTag] == sats * 2)
        #expect(repo.messages(for: aTag).filter(\.isZapAnnouncement).map(\.id) == ["zap-\(live.id)"])
    }

    /// The point of the split: a full scan page (1,000) of old receipts must
    /// not occupy the chat buffer that history paging pages from.
    @Test func zapScan_fullPageOfOldReceiptsLeavesTheChatBufferAlone() throws {
        let sats = try zapAmount()
        let repo = LiveStreamRepository()
        #expect(repo.addChatMessage(chatMessage(1, createdAt: 100_000)))

        let page = (0..<LiveStreamRepository.maxChatMessages).map { zapReceipt(1_000 + $0, createdAt: 1 + $0) }
        repo.addArchivedZaps(page, aTag: aTag, announceFrom: 100_000)

        #expect(repo.messages(for: aTag).count == 1)
        #expect(repo.streamZapTotalsSats[aTag] == sats * Int64(page.count))
    }

    // MARK: Live-content switch

    /// With the switch off, `start()` returns before claiming the stream or
    /// resolving relays (it would otherwise query the network).
    @Test func start_doesNothingWhileSwitchIsOff() async {
        let savedCurrent = LiveStreamRepository.shared.currentATag
        LiveStreamRepository.shared.setCurrent(nil)
        defer { LiveStreamRepository.shared.setCurrent(savedCurrent) }

        await withLiveContent(false) {
            let vm = LiveStreamViewModel(
                aTagValue: aTag, hostPubkey: Self.host, dTag: Self.dTag,
                naddrRelayHints: ["wss://relay.example.com"],
                keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: Self.zapper)
            )
            await vm.start()
            #expect(LiveStreamRepository.shared.currentATag == nil, "start() must not claim the stream")
            #expect(vm.chatRelays.isEmpty, "start() must not resolve relays")
        }
    }

    /// Turning the switch off drops every discovered stream, its chat and its
    /// zap totals, and does not restart discovery.
    @Test func switchOff_clearsDiscoveredStreams() async throws {
        let repo = LiveStreamRepository.shared
        defer { repo.clear() }
        repo.addActivity(liveActivity())
        try #require(repo.streams[aTag] != nil, "fixture activity must count as live")
        #expect(repo.addChatMessage(chatMessage(1, createdAt: 1_000)))
        repo.addStreamZap(zapReceipt(10, createdAt: 1_000), aTag: aTag)
        repo.setCurrent(aTag)

        let (vm, discovery) = makeFeedVM()
        await withLiveContent(false) {
            vm.liveContentSettingChanged(false)
        }

        #expect(repo.streams.isEmpty)
        #expect(repo.messagesByStream.isEmpty)
        #expect(repo.streamZapTotalsSats.isEmpty)
        #expect(repo.currentATag == nil)
        #expect(discovery().isEmpty)
    }

    /// Turning it back on starts discovery at once; a refresh while it is off
    /// does nothing.
    @Test func switchOn_startsDiscovery_refreshWhileOffDoesNot() async {
        let (vm, discovery) = makeFeedVM()
        await withLiveContent(false) {
            vm.refreshLiveDiscovery()
        }
        #expect(discovery().isEmpty)

        await withLiveContent(true) {
            vm.liveContentSettingChanged(true)
        }
        #expect(discovery() == [Self.host])
    }
}
