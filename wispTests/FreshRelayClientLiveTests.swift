import Foundation
import Testing
@testable import wisp

/// Read-only smoke run of `FreshRelayClient` against the real
/// `wss://feed.zap.cooking`. Skipped unless the operator opts in
/// (`touch wispTests/.fresh_relay_live_enable` or `FRESH_RELAY_LIVE=1`).
/// No key exists in this test; a recording transport fails it if any frame
/// other than `REQ` / `CLOSE` goes out. Prints what the relay did, for the
/// PR's gate file.
@Suite(.tags(.liveNetwork), .serialized)
struct FreshRelayClientLiveTests {

    nonisolated private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".fresh_relay_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["FRESH_RELAY_LIVE"] == "1" || env["TEST_RUNNER_FRESH_RELAY_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: FreshRelayClientLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.fresh_relay_live_enable"
        )
    )
    func smoke() async throws {
        let transport = RecordingTransport()
        let client = FreshRelayClient(transport: transport, silenceTimeout: 10)
        func log(_ line: String) { print("FRESH-LIVE \(line)") }

        let page1 = await client.feedPage()
        log("page1 outcome=\(page1.outcome) events=\(page1.events.count) received=\(page1.received) rejected=\(page1.rejected) short=\(page1.isShortPage)")
        #expect(page1.outcome == .answered)
        #expect(page1.rejected == 0)
        let kinds = Set(page1.events.map(\.kind))
        log("page1 kinds=\(kinds.sorted())")
        #expect(kinds.isSubset(of: [1, 30023, 1068]))

        var until = page1.oldestCreatedAt
        var pages = 1
        var total = page1.events.count
        var last = page1
        while let next = until, !last.isShortPage, pages < 40 {
            last = await client.feedPage(until: next)
            pages += 1
            total += last.events.count
            if last.outcome != .answered { break }
            until = last.oldestCreatedAt ?? next
        }
        log("walk pages=\(pages) events=\(total) lastOutcome=\(last.outcome) lastShort=\(last.isShortPage) rejected=\(last.rejected)")
        #expect(last.outcome == .answered || last.outcome == .floor)

        let floor = await client.floor
        let below = await client.feedPage(until: floor - 1)
        log("belowFloor outcome=\(below.outcome) (not sent)")
        #expect(below.outcome == .floor)

        let preview = await client.topicPreview(slug: "pasta")
        log("preview pasta outcome=\(preview.outcome) events=\(preview.events.count)")
        #expect(preview.outcome == .answered)
        #expect(preview.events.count <= 5)

        let unknown = await client.topicPreview(slug: "no-such-topic-ios-smoke")
        log("preview unknown outcome=\(unknown.outcome)")
        if case .invalid = unknown.outcome {} else { Issue.record("unknown slug: \(unknown.outcome)") }
        let sentBefore = transport.sent.count
        let again = await client.topicPreview(slug: "no-such-topic-ios-smoke")
        log("preview unknown again outcome=\(again.outcome) framesSent=\(transport.sent.count - sentBefore)")
        #expect(transport.sent.count == sentBefore)

        let recipes = await client.recipes()
        let oldest = recipes.events.last.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) }
        log("recipes outcome=\(recipes.outcome) events=\(recipes.events.count) rejected=\(recipes.rejected) oldest=\(oldest.map { "\($0)" } ?? "-")")
        #expect(recipes.outcome == .answered)

        let tail = await client.liveTail(since: NostrClock.now())
        try await Task.sleep(for: .seconds(3))
        log("tail lost=\(await client.tailIsLost)")
        await client.stopTail()
        _ = tail
        await client.close()

        let sent = transport.sent
        let kindsSent = Dictionary(grouping: sent, by: { String($0.prefix(8)) }).mapValues(\.count)
        log("framesSent=\(sent.count) byPrefix=\(kindsSent) authChallengesReceived=\(transport.authFramesReceived)")
        for frame in sent {
            #expect(frame.hasPrefix("[\"REQ\"") || frame.hasPrefix("[\"CLOSE\""), "sent \(frame.prefix(40))")
        }
    }
}

/// The production transport, recording every frame sent and counting the
/// AUTH frames received (which the client must ignore).
nonisolated private final class RecordingTransport: GroupRelayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _auth = 0

    func open(url: URL) -> GroupRelaySocket {
        RecordingSocket(inner: URLSessionGroupRelaySocket(url: url), owner: self)
    }

    func recordSent(_ frame: String) { lock.lock(); _sent.append(frame); lock.unlock() }
    func recordReceived(_ frame: String) {
        guard frame.hasPrefix("[\"AUTH\"") else { return }
        lock.lock(); _auth += 1; lock.unlock()
    }
    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    var authFramesReceived: Int { lock.lock(); defer { lock.unlock() }; return _auth }
}

nonisolated private final class RecordingSocket: GroupRelaySocket, @unchecked Sendable {
    let inner: GroupRelaySocket
    let owner: RecordingTransport
    init(inner: GroupRelaySocket, owner: RecordingTransport) { self.inner = inner; self.owner = owner }
    func resume() { inner.resume() }
    func send(_ text: String) { owner.recordSent(text); inner.send(text) }
    func receive() async throws -> String {
        let text = try await inner.receive()
        owner.recordReceived(text)
        return text
    }
    func cancel() { inner.cancel() }
}
