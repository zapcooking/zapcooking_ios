import Foundation
import Testing
@testable import wisp

/// The one log line per Follows load: written once, at settle or at the
/// load's end, whichever comes first. The settle rule itself is covered by
/// `FollowsSinceTests`; nothing here changes it.
@Suite @MainActor struct FollowsLoadReportTests {

    nonisolated final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [String] = []
        func append(_ line: String) { lock.lock(); _all.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return _all }
    }

    nonisolated final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _t: TimeInterval = 1_000
        func advance(_ s: TimeInterval) { lock.lock(); _t += s; lock.unlock() }
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return _t }
    }

    private let a = "wss://a.example.com", b = "wss://b.example.com", c = "wss://c.example.com"

    private func load(_ asked: Set<String>, lines: Lines, clock: Clock) -> FollowsLoadSettle {
        let name = "FollowsLoadReportTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return FollowsLoadSettle(pubkey: String(repeating: "f", count: 64), askedRelays: asked,
                                 now: { 2_000_000_000 }, defaults: defaults,
                                 uptime: { clock.now }, report: { lines.append($0) })
    }

    @Test func line_namesAskedAnsweredSettledAndSeconds() {
        #expect(FollowsLoadReport.line(asked: 12, answered: 12, settledAfter: 3.44)
                == "Follows load: relays asked 12, answered 12, settled yes, seconds to settle 3.4")
        #expect(FollowsLoadReport.line(asked: 12, answered: 9, settledAfter: nil)
                == "Follows load: relays asked 12, answered 9, settled no, seconds to settle -")
    }

    @Test func settledLoad_logsOnceAtSettle_andNotAgainWhenReplaced() {
        let lines = Lines(), clock = Clock()
        let settle = load([a, b], lines: lines, clock: clock)
        clock.advance(1)
        settle.answered(relayUrl: a, streamCount: 0)
        #expect(lines.all.isEmpty)
        clock.advance(1.5)
        settle.answered(relayUrl: b, streamCount: 0)
        settle.answered(relayUrl: b, streamCount: 0)       // a reconnect's second EOSE
        settle.end()                       // replaced later
        #expect(lines.all == ["Follows load: relays asked 2, answered 2, settled yes, seconds to settle 2.5"])
    }

    @Test func unsettledLoad_logsOnceWhenReplaced_withHowManyAnswered() {
        let lines = Lines(), clock = Clock()
        let settle = load([a, b, c], lines: lines, clock: clock)
        settle.answered(relayUrl: a, streamCount: 0)
        settle.answered(relayUrl: "wss://unasked.example.com", streamCount: 0)
        settle.end()
        settle.end()                       // stop() after a replace
        settle.answered(relayUrl: b, streamCount: 0)
        settle.answered(relayUrl: c, streamCount: 0)       // settles after its end: no second line
        #expect(lines.all == ["Follows load: relays asked 3, answered 1, settled no, seconds to settle -"])
    }

    @Test func loadThatAskedNobody_logsWhenItEnds() {
        let lines = Lines(), clock = Clock()
        let settle = load([], lines: lines, clock: clock)
        settle.answered(relayUrl: a, streamCount: 0)
        settle.end()
        #expect(lines.all == ["Follows load: relays asked 0, answered 0, settled no, seconds to settle -"])
    }
}
