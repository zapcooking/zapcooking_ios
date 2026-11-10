import Foundation
import Testing
@testable import wisp

/// Fresh feed, PR 1: no relay path in the app answers a NIP-42 challenge
/// from `wss://feed.zap.cooking` while `FeatureFlags.feedRelayLoginEnabled`
/// is off (Guideline 2.1(b): a login there unlocks the paid Cook+ tier).
///
/// The relay sends its challenge on connect and again before every
/// `CLOSED auth-required:` (probed 2026-11-10), and before this change the
/// shared pool, the group pool and Lazarus each signed whatever challenge
/// they were handed. All three sign through `Nip42.buildAuthEvent`, so the
/// refusal lives there; the tripwire at the bottom keeps it the only place
/// a kind-22242 event can be built.
///
/// Not covered here: `RelayPool.respondToAuthChallenge` itself, which takes
/// a real `URLSessionWebSocketTask`. What is covered is the signer it calls.
@Suite @MainActor struct FeedRelayNoAuthTests {

    private func makeKeypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    /// Every spelling of the feed relay a relay path could be handed.
    private static let feedSpellings = [
        "wss://feed.zap.cooking",
        "wss://feed.zap.cooking/",
        "WSS://Feed.Zap.Cooking",
        "wss://feed.zap.cooking:443",
        "wss://feed.zap.cooking/some/path?x=1",
        "wss://feed.zap.cooking.",
        "wss://user@feed.zap.cooking",
        "ws://feed.zap.cooking",
        "https://feed.zap.cooking",
        "feed.zap.cooking",
        "  wss://feed.zap.cooking\n",
    ]

    /// Hosts that must keep signing: the members relay, a public relay, and
    /// look-alikes that only contain the feed host's name.
    private static let otherRelays = [
        "wss://pantry.zap.cooking",
        "wss://nos.lol",
        "wss://zap.cooking",
        "wss://x.feed.zap.cooking",
        "wss://feed.zap.cooking.example.com",
        "wss://example.com/feed.zap.cooking",
        "wss://example.com?relay=feed.zap.cooking",
        "wss://feed.zap.cooking@example.com",
    ]

    // MARK: - The flag and the host match

    /// The shipped value. Flipping it re-opens 2.1(b); see `FeatureFlags`.
    @Test func flag_shipsOff() {
        #expect(!FeatureFlags.feedRelayLoginEnabled)
    }

    @Test func hostMatch_everySpellingOfTheFeedRelay() {
        for url in Self.feedSpellings {
            #expect(FeedRelay.isFeedRelay(url), "\(url)")
        }
        #expect(FeedRelay.isFeedRelay(FeedRelay.url))
    }

    @Test func hostMatch_neverALookAlike() {
        for url in Self.otherRelays + ["", "wss://", "not a url"] {
            #expect(!FeedRelay.isFeedRelay(url), "\(url)")
        }
    }

    /// The gate is the flag and the host together, both ways.
    @Test func loginAllowed_truthTable() {
        #expect(!Nip42.loginAllowed(relayUrl: FeedRelay.url, feedRelayLoginEnabled: false))
        #expect(Nip42.loginAllowed(relayUrl: FeedRelay.url, feedRelayLoginEnabled: true))
        #expect(Nip42.loginAllowed(relayUrl: "wss://pantry.zap.cooking", feedRelayLoginEnabled: false))
        #expect(Nip42.loginAllowed(relayUrl: "wss://pantry.zap.cooking", feedRelayLoginEnabled: true))
        // The shipped default is the `false` row.
        #expect(!Nip42.loginAllowed(relayUrl: FeedRelay.url))
    }

    // MARK: - The choke point

    @Test func buildAuthEvent_refusesTheFeedRelay() throws {
        let keypair = try makeKeypair()
        for url in Self.feedSpellings {
            #expect(throws: Nip42.AuthError.loginDisabled(relayUrl: url), "\(url)") {
                try Nip42.buildAuthEvent(challenge: "c", relayUrl: url, keypair: keypair)
            }
        }
    }

    @Test func buildAuthEvent_stillSignsForEveryOtherRelay() throws {
        let keypair = try makeKeypair()
        for url in Self.otherRelays {
            let event = try Nip42.buildAuthEvent(challenge: "c-1", relayUrl: url, keypair: keypair)
            #expect(event.kind == 22242, "\(url)")
            #expect(event.pubkey == keypair.pubkey)
            #expect(event.tags.contains(["relay", url]))
            #expect(event.tags.contains(["challenge", "c-1"]))
        }
    }

    // MARK: - The callers

    /// The group pool, on its fake transport: the feed relay's challenge
    /// (on connect, and again after a refusal) gets no AUTH frame.
    @Test func groupPool_sendsNoAuthToTheFeedRelay() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay(FeedRelay.url, keypair: try makeKeypair())
        let socket = try #require(transport.latest)

        socket.feed("[\"AUTH\",\"challenge-on-connect\"]")
        #expect(await eventually { await pool.authState(relayUrl: FeedRelay.url) == .unavailable })
        socket.feed("[\"AUTH\",\"challenge-on-connect\"]")
        try await Task.sleep(for: .milliseconds(100))

        #expect(socket.sent.filter { $0.hasPrefix("[\"AUTH\"") }.isEmpty, "sent: \(socket.sent)")
        #expect(await pool.authState(relayUrl: FeedRelay.url) == .unavailable)
    }

    /// Control for the test above: the same pool still answers another relay.
    @Test func groupPool_stillAuthenticatesElsewhere() async throws {
        let transport = FakeGroupTransport()
        let pool = GroupRelayPool(transport: transport)
        await pool.ensureRelay("wss://pantry.zap.cooking", keypair: try makeKeypair())
        let socket = try #require(transport.latest)

        socket.feed("[\"AUTH\",\"challenge-1\"]")
        #expect(await eventually { socket.sentAuthEventId != nil })
    }

    /// Lazarus's signer (the user's key, built the way the recovery screen
    /// builds it) declines the feed relay whatever the approval setting says.
    @Test func lazarusSigner_declinesTheFeedRelay() throws {
        let signer = LazarusRelayClient.authSigner(for: try makeKeypair())
        for url in Self.feedSpellings {
            #expect(signer(url, "c") == nil, "\(url)")
        }
    }

    /// The shared pool's signer has the shape `MainView` installs
    /// (`try? Nip42.buildAuthEvent`): nil for the feed relay, so
    /// `respondToAuthChallenge` returns without sending.
    @Test func sharedPoolSignerShape_declinesTheFeedRelay() throws {
        let keypair = try makeKeypair()
        let signer: @Sendable (String, String) -> NostrEvent? = { url, challenge in
            try? Nip42.buildAuthEvent(challenge: challenge, relayUrl: url, keypair: keypair)
        }
        #expect(signer(FeedRelay.url, "c") == nil)
        #expect(signer("wss://nos.lol", "c") != nil)
    }

    // MARK: - Tripwire: one place builds a kind-22242 event

    /// The files allowed to name kind 22242 in code. A new signing path that
    /// builds its own AUTH event would bypass `loginAllowed`; route it
    /// through `Nip42.buildAuthEvent` instead of adding it here. If a path
    /// truly cannot (it signs with a key that is not the user's), it must
    /// call `Nip42.loginAllowed` itself before it is listed.
    private static let allowedAuthEventBuilders: Set<String> = ["Nip42.swift"]

    /// Lines of `text` that name kind 22242 in code: the literal, or
    /// `Nip42.kindAuth`. Comments are ignored.
    private func authKindUses(in text: String) -> [Int] {
        var hits: [Int] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
            let compact = code.replacingOccurrences(of: "_", with: "")
            if compact.contains("22242") || code.contains("Nip42.kindAuth") {
                hits.append(i + 1)
            }
        }
        return hits
    }

    /// Every app source file: the repo root's Swift files and everything
    /// under `wisp/`. Tests and generated code are not app signing paths.
    private func appSources() throws -> [(name: String, url: URL)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        var files: [(String, URL)] = []
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, url))
        }
        let wisp = root.appendingPathComponent("wisp")
        if let walker = fm.enumerator(at: wisp, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(("wisp/" + url.path.dropFirst(wisp.path.count + 1), url))
            }
        }
        return files
    }

    @Test func onlyNip42_buildsAKind22242Event() throws {
        let sources = try appSources()
        // The scan found the tree: the guard's own file is in it.
        #expect(sources.contains { $0.name == "Nip42.swift" })
        #expect(sources.count > 100, "scanned only \(sources.count) files")

        var offenders: [String] = []
        for (name, url) in sources where !Self.allowedAuthEventBuilders.contains(name) {
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += authKindUses(in: text).map { "\(name):\($0)" }
        }
        #expect(offenders.isEmpty,
                "kind 22242 named outside Nip42.swift; sign through Nip42.buildAuthEvent: \(offenders)")
    }

    /// The tripwire can fail: a hand-built AUTH event trips it, in either
    /// spelling, and a comment or another kind does not.
    @Test func tripwire_catchesAHandBuiltAuthEvent() {
        let bypass = """
            // kind-22242 in a comment is fine
            let a = try NostrEvent.sign(privkey32: priv, pubkey: pk, kind: 22242,
                                        createdAt: now, tags: tags, content: "")
            let b = try NostrEvent.sign(privkey32: priv, pubkey: pk, kind: Nip42.kindAuth,
                                        createdAt: now, tags: tags, content: "")
            let c = 22_242
            let blossom = 24242  /// not 22242
            """
        #expect(authKindUses(in: bypass) == [2, 4, 6])
    }

    private func eventually(timeout: TimeInterval = 3,
                            _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}
