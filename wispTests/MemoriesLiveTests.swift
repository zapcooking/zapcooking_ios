import Foundation
import Testing
@testable import wisp

/// Memories live gate (read-only — nothing is published, so §7.13 does not
/// apply). Fetches real memories for a pubkey with notes 1–3 years back
/// against the production relay union and reports, per window, the event
/// count and whether it resolved via EOSE or timeout.
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (`touch wispTests/.memories_live_enable` or
/// `MEMORIES_LIVE=1`). The author defaults to jb55 (posts most days since
/// 2022, so every window has notes); override with `MEMORIES_LIVE_PUBKEY=<hex>`
/// to run it against your own key.
@Suite(.tags(.liveNetwork))
@MainActor
struct MemoriesLiveTests {

    nonisolated private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".memories_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        let env = ProcessInfo.processInfo.environment
        return env["MEMORIES_LIVE"] == "1"
    }

    /// jb55 — an account with kind-1 history back to 2022 on the archive relays.
    nonisolated private static let defaultPubkey = "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245"

    nonisolated private static var pubkey: String {
        let env = ProcessInfo.processInfo.environment["MEMORIES_LIVE_PUBKEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return env.count == 64 ? env.lowercased() : defaultPubkey
    }

    @Test(
        .enabled(if: MemoriesLiveTests.isDeliberatelyEnabled,
                 "Opt-in live gate: touch wispTests/.memories_live_enable or set MEMORIES_LIVE=1"),
        .timeLimit(.minutes(3))
    )
    func fetchesRealMemories_reportingPerWindowResolution() async {
        let suite = "MemoriesLiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = MemoriesRepository(store: MemoriesStore(defaults: defaults), persistEvents: { _ in })
        let pk = Self.pubkey
        let started = Date()

        print("MEMORIES_LIVE author=\(pk) relays=\(MemoriesRelay.relays.joined(separator: ","))")
        let groups = await repo.fetchMemories(pubkey: pk)
        let elapsed = Int(Date().timeIntervalSince(started))

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        for g in groups {
            let day = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(g.dateSec)))
            print("MEMORIES_LIVE window=\(g.yearsAgo)y day=\(day) events=\(g.events.count) resolved=\(g.resolvedVia.rawValue.uppercased())")
            for e in g.events.prefix(5) {
                let when = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(e.createdAt)))
                let snippet = e.content.replacingOccurrences(of: "\n", with: " ").prefix(60)
                print("MEMORIES_LIVE   \(when) \(e.id.prefix(8)) \(snippet)")
            }
        }
        print("MEMORIES_LIVE total=\(groups.reduce(0) { $0 + $1.events.count }) cacheable=\(shouldCacheMemories(groups)) elapsed=\(elapsed)s")

        #expect(groups.map(\.yearsAgo) == [1, 2, 3])
        #expect(groups.contains { $0.resolvedVia == .eose }, "no window reached any relay's EOSE")
        #expect(groups.reduce(0) { $0 + $1.events.count } > 0, "no memories found for an author known to have them")
        for g in groups {
            #expect(g.events.allSatisfy { $0.pubkey == pk && $0.kind == 1 && !isMemoryReply($0) })
            #expect(g.events.map(\.createdAt) == g.events.map(\.createdAt).sorted())
        }
    }
}
