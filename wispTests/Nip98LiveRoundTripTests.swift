import Foundation
import Testing
@testable import wisp

extension Tag {
    /// Opt-in tests that hit the live zap.cooking network.
    /// Excluded from the default suite via `.enabled(if:)` — not run unless
    /// the deliberate enable sentinel / env gate is set (see ZAPCOOKING_IOS_BUILD.md).
    @Tag static var liveNetwork: Self
}

/// Live NIP-98 round-trip against zap.cooking (Concern 0.6 acceptance gate).
///
/// Isolated from the default suite: `.enabled(if:)` stays false unless the
/// operator opts in (touch `wispTests/.nip98_live_enable` or set `NIP98_LIVE=1`).
/// A tag alone cannot exclude tests here — this project has no shared test plan
/// and the installed `xcodebuild` has no `-skip-testing-tags`. Uses an ephemeral
/// keypair — never a real nsec.
///
/// Acceptance signal is `owner: true` in the JSON body, NOT HTTP 200:
/// `check-status` silently degrades to the public shape on a bad signature
/// rather than returning 401.
@Suite(.tags(.liveNetwork))
struct Nip98LiveRoundTripTests {

    /// Opt-in sentinel next to this source file. The simulator can see the
    /// host path baked into `#filePath` (same mechanism used when verifying
    /// the round-trip body). Env var is also accepted for hosts that forward it.
    private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".nip98_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        return ProcessInfo.processInfo.environment["NIP98_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: Nip98LiveRoundTripTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.nip98_live_enable (see ZAPCOOKING_IOS_BUILD.md)"
        )
    )
    func checkStatus_acceptsEphemeralNip98Signature() async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let privHex = Hex.encode(priv)
        let pubHex = Hex.encode(pub)
        let keypair = Keypair(privkey: privHex, pubkey: pubHex)

        let url = URL(string: "https://zap.cooking/api/membership/check-status")!
        let bodyString = "{\"pubkey\":\"\(pubHex)\"}"
        let auth = try await Nip98.authHeader(
            keypair: keypair,
            method: "POST",
            url: url.absoluteString,
            bodyString: bodyString
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = Data(bodyString.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        let body = String(data: data, encoding: .utf8) ?? ""

        #expect(http.statusCode == 200, "status=\(http.statusCode) body=\(body)")
        #expect(
            body.contains(#""owner":true"#) || body.contains(#""owner": true"#),
            "acceptance is owner:true (not mere HTTP 200); body=\(body)"
        )
    }
}
