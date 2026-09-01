import Foundation
import Testing
@testable import wisp

/// Live canary: pinned public Nourish REQ against pantry.
/// Expects EOSE and **no AUTH**. No key. Relay-policy canary as well as
/// the Nourish read path.
///
/// Opt-in: `touch wispTests/.nourish_live_enable` or `NOURISH_LIVE=1`.
@Suite(.tags(.liveNetwork))
struct NourishLiveTests {
    private nonisolated static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".nourish_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        return ProcessInfo.processInfo.environment["NOURISH_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: NourishLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.nourish_live_enable (no key; pantry policy canary)"
        )
    )
    @MainActor
    func pantryPinnedReq_eoseWithoutAuth() async throws {
        let pantry = try #require(RelayDefaults.members.first)
        let url = try #require(URL(string: pantry))
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        let filterJSON = NourishFilter.publicCorpus.toJSON()
        let keys = NourishFilter.encodedKeys(NourishFilter.publicCorpus)
        #expect(keys == ["kinds", "authors", "limit"])
        try await ws.send(.string("[\"REQ\",\"nourish-live\",\(filterJSON)]"))

        var sawAuth = false
        var sawEose = false
        var eventCount = 0
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, !sawEose {
            let msg = try await receive(ws, timeout: 4)
            guard case .string(let text) = msg,
                  let data = text.data(using: .utf8),
                  let arr = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let type = arr.first as? String
            else { continue }
            switch type {
            case "AUTH":
                sawAuth = true
            case "CLOSED":
                let reason = (arr.count >= 3 ? arr[2] as? String : nil) ?? ""
                if reason.lowercased().contains("auth-required") { sawAuth = true }
            case "EVENT":
                eventCount += 1
            case "EOSE":
                sawEose = true
            default:
                break
            }
        }

        #expect(sawEose, "pantry must EOSE the pinned public Nourish filter")
        #expect(!sawAuth, "pinned public Nourish REQ must not AUTH (relay-policy canary)")
        print("Nourish live: events=\(eventCount) eose=\(sawEose) auth=\(sawAuth)")
    }

    private func receive(
        _ ws: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await ws.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ProbeTimeout()
            }
            let msg = try await group.next()
            group.cancelAll()
            return try #require(msg)
        }
    }
}

private struct ProbeTimeout: Error {}
