import Foundation
import Testing
@testable import wisp

// Hermetic cover for `ScheduleApi` (the scheduled-posts contract,
// `docs/schedule-contract.md` in zapcooking/frontend). Every request goes to
// an in-process URLProtocol stub on the test's own session, so nothing
// reaches the network and nothing is ever published.

// MARK: - Fixtures

/// Answers each request with the next scripted reply and records what was sent.
final class ScheduleStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(Int, String)
        case offline
    }

    struct Recorded: Sendable {
        let method: String
        let url: String
        let authorization: String?
        let contentType: String?
        let body: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var seen: [Recorded] = []

    static func script(_ replies: [Reply]) {
        lock.lock(); self.replies = replies; seen = []; lock.unlock()
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScheduleStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    private static func bodyString(of request: URLRequest) -> String? {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }

    override func startLoading() {
        let recorded = Recorded(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: Self.bodyString(of: request)
        )
        Self.lock.lock()
        Self.seen.append(recorded)
        let reply: Reply? = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()

        switch reply {
        case .http(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .offline, nil:
            // An unscripted request fails rather than inventing an answer.
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}
}

/// A real local-key NIP-98 signer that counts how many headers it signed.
nonisolated final class CountingNip98Signer: Nip98Signing, @unchecked Sendable {
    private let inner: LocalNip98Signer
    private let lock = NSLock()
    private var _count = 0

    let pubkeyHex: String

    @MainActor init(keypair: Keypair) {
        inner = LocalNip98Signer(keypair: keypair)
        pubkeyHex = keypair.pubkey
    }

    var count: Int { lock.withLock { _count } }

    func signEvent(kind: Int, content: String, tags: [[String]]) async throws -> NostrEvent {
        lock.withLock { _count += 1 }
        return try await inner.signEvent(kind: kind, content: content, tags: tags)
    }
}

/// An event signer that can misbehave the ways real signers do.
nonisolated struct FakeEventSigner: ScheduleEventSigning {
    enum Mode: Sendable {
        case honest
        /// Stamps this time instead of the one asked for (a signer that signs "now").
        case redate(Int)
        /// Returns the right fields under a signature for something else.
        case wrongSignature
        case otherContent
        case refuse
        case unavailable
        /// What `Signer.sign` throws when a remote signer returns a different event.
        case remoteMismatch
    }

    let privkey: Data
    let pubkeyHex: String
    let mode: Mode

    func signEvent(kind: Int, tags: [[String]], content: String, createdAt: Int) async throws -> NostrEvent {
        func signed(at time: Int, _ text: String) throws -> NostrEvent {
            try NostrEvent.sign(privkey32: privkey, pubkey: pubkeyHex, kind: kind,
                                createdAt: time, tags: tags, content: text)
        }
        switch mode {
        case .honest: return try signed(at: createdAt, content)
        case .redate(let time): return try signed(at: time, content)
        case .otherContent: return try signed(at: createdAt, content + " (edited by signer)")
        case .wrongSignature:
            let real = try signed(at: createdAt, content)
            let other = try signed(at: createdAt, content + "x")
            return NostrEvent(id: real.id, pubkey: real.pubkey, kind: real.kind, createdAt: real.createdAt,
                              tags: real.tags, content: real.content, sig: other.sig)
        case .refuse: throw URLError(.userCancelledAuthentication)
        case .unavailable: throw ScheduleSigningUnavailable()
        case .remoteMismatch: throw Nip46.NipError.malformedResponse
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

private struct Account {
    let privkey: Data
    let keypair: Keypair

    init() throws {
        privkey = Schnorr.randomPrivkey()
        let pubkey = Hex.encode(try Schnorr.xonlyPubkey(privkey32: privkey))
        keypair = Keypair(privkey: Hex.encode(privkey), pubkey: pubkey)
    }

    var pubkey: String { keypair.pubkey }

    func event(kind: Int = 1, at time: Int = 1_900_000_000, tags: [[String]] = [["t", "foodstr"]],
               content: String = "see you tomorrow") throws -> NostrEvent {
        try NostrEvent.sign(privkey32: privkey, pubkey: pubkey, kind: kind,
                            createdAt: time, tags: tags, content: content)
    }

    func eventSigner(_ mode: FakeEventSigner.Mode) -> FakeEventSigner {
        FakeEventSigner(privkey: privkey, pubkeyHex: pubkey, mode: mode)
    }
}

/// The signed kind-27235 event inside an `Authorization: Nostr <base64>` value.
private func authEvent(_ header: String?) throws -> NostrEvent {
    let header = try #require(header)
    #expect(header.hasPrefix("Nostr "))
    let data = try #require(Data(base64Encoded: String(header.dropFirst("Nostr ".count))))
    let json = try #require(String(data: data, encoding: .utf8))
    return try #require(NostrEvent.fromJSON(json))
}

private func tagValue(_ event: NostrEvent, _ name: String) -> String? {
    event.tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
}

// MARK: - Relays

/// `ScheduleApi.pickRelays`. The first four tests are web's
/// `pickScheduleRelays` cases (`src/lib/scheduleClient.test.ts` in
/// zapcooking/frontend), input for input, so the clients agree. Web's list
/// also holds `42` and `null`; a Swift `[String]` cannot.
struct ScheduleApiRelayTests {

    @Test func keepsTheFirstFourUsableRelays_inOrder_normalized() {
        #expect(ScheduleApi.pickRelays([
            "wss://A.example.com/",
            "wss://b.example.com:443",
            "wss://c.example.com/inbox/",
            "wss://d.example.com",
            "wss://e.example.com",
        ]) == ["wss://a.example.com", "wss://b.example.com", "wss://c.example.com/inbox", "wss://d.example.com"])
    }

    @Test func dropsWhatTheServerWouldReject_soOneBadRelayCannotSinkTheRequest() {
        #expect(ScheduleApi.pickRelays([
            "ws://insecure.example.com",
            "wss://localhost",
            "wss://192.168.1.4",
            "wss://[::1]",
            "wss://nas.lan",
            "wss://abc.onion",
            "wss://user:pw@a.example.com",
            "wss://a.example.com/" + String(repeating: "p", count: 180),
            "",
            "wss://ok.example.com",
        ]) == ["wss://ok.example.com"])
    }

    @Test func doesNotSpendPlacesOnTheSchedulersOwnRelays_purplepages_orDuplicates() {
        #expect(ScheduleApi.pickRelays([
            "wss://nos.lol",
            "wss://relay.primal.net/",
            "wss://purplepag.es",
            "wss://Nos.lol/",
            "wss://a.example.com",
            "wss://A.example.com/",
            "wss://b.example.com",
        ]) == ["wss://a.example.com", "wss://b.example.com"])
    }

    @Test func anEmptyOrUnusableListIsEmpty() {
        #expect(ScheduleApi.pickRelays([]) == [])
        #expect(ScheduleApi.pickRelays(["wss://nos.lol", "nonsense"]) == [])
    }

    // The rest pin the port of `isPublicRelayUrl` / `normalizeScheduleRelay`.

    @Test(arguments: [
        "wss://relay.example.com.local", "wss://box.internal", "wss://a.home.arpa", "wss://x.i2p",
        "wss://relay.test", "wss://127.0.0.1", "wss://relay.0x7f", "wss://10.1", "wss://[2001:db8::1]:443",
        "wss://-bad.example.com", "wss://bad-.example.com", "wss://a..example.com", "wss://exa_mple.com",
        "wss://relay.example.com/ path", "wss://relay.example.com\n", "https://relay.example.com",
        "wss://user@relay.example.com", "wss://", "relay.example.com",
    ])
    func refuses(_ url: String) {
        #expect(!ScheduleApi.isPublicRelayUrl(url))
        #expect(ScheduleApi.pickRelays([url]) == [])
    }

    @Test(arguments: [
        ("WSS://Relay.Example.com", "wss://relay.example.com"),
        ("wss://relay.example.com:8443/", "wss://relay.example.com:8443"),
        ("wss://relay.example.com/a/b//", "wss://relay.example.com/a/b"),
        ("wss://relay.example.com/?token=Abc", "wss://relay.example.com?token=Abc"),
        ("wss://relay.example.com/#frag", "wss://relay.example.com"),
        ("wss://my-relay.example.co.uk", "wss://my-relay.example.co.uk"),
    ])
    func normalizes(_ url: String, to expected: String) {
        #expect(ScheduleApi.normalizedPublicRelay(url) == expected)
    }

    @Test func aUrlOfExactlyTwoHundredCharactersIsLeftOut() {
        let prefix = "wss://a.example.com/"
        let at199 = prefix + String(repeating: "p", count: 199 - prefix.count)
        #expect(ScheduleApi.pickRelays([at199]) == [at199])
        #expect(ScheduleApi.pickRelays([at199 + "p"]) == [])
    }
}

// MARK: - Signing

@MainActor
@Suite(.serialized)
struct ScheduleApiSignTests {

    static let now = 1_800_000_000

    @Test func signsWithThePublishTime() async throws {
        let account = try Account()
        let publishAt = Self.now + 3_600
        let event = try await ScheduleApi.sign(
            kind: 1, tags: [["t", "soup"]], content: "later", publishAt: publishAt,
            signer: account.eventSigner(.honest), now: Self.now
        ).get()
        #expect(event.createdAt == publishAt)
        #expect(event.kind == 1)
        #expect(event.content == "later")
        #expect(event.tags == [["t", "soup"]])
        #expect(event.pubkey == account.pubkey)
        #expect(event.hasValidSignature())
    }

    /// The account's real signer, local key: `created_at` is the caller's.
    @Test func localKeySignsAFutureCreatedAt() async throws {
        let account = try Account()
        let publishAt = NostrClock.now() + 86_400
        let event = try await ScheduleApi.sign(
            kind: 1068, tags: [], content: "poll", publishAt: publishAt,
            signer: AccountScheduleSigner(keypair: account.keypair)
        ).get()
        #expect(event.createdAt == publishAt)
        #expect(event.hasValidSignature())
    }

    @Test func watchOnlyAccountIsSignedOut() async throws {
        let account = try Account()
        let watchOnly = Keypair(privkey: "", pubkey: account.pubkey)
        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: NostrClock.now() + 3_600,
            signer: AccountScheduleSigner(keypair: watchOnly)
        )
        #expect(result.failure == .signedOut)
    }

    @Test(arguments: [0, 60, 120, 180, -5])
    func refusesATimeThreeMinutesOffOrLess(_ lead: Int) async throws {
        let account = try Account()
        // `.refuse` would turn up as signFailed: the signer must not be asked.
        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + lead,
            signer: account.eventSigner(.refuse), now: Self.now
        )
        #expect(result.failure == .badPublishTime)
    }

    @Test func acceptsATimeJustOverThreeMinutesOff() async throws {
        let account = try Account()
        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + 181,
            signer: account.eventSigner(.honest), now: Self.now
        )
        #expect(result.failure == nil)
    }

    @Test func refusesNinetyDaysOrMore() async throws {
        let account = try Account()
        let ninetyDays = 90 * 86_400
        let atLimit = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + ninetyDays,
            signer: account.eventSigner(.refuse), now: Self.now
        )
        #expect(atLimit.failure == .badPublishTime)
        let under = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + ninetyDays - 1,
            signer: account.eventSigner(.honest), now: Self.now
        )
        #expect(under.failure == nil)
    }

    @Test func aSignerThatRedatesTheEventIsCaught() async throws {
        let account = try Account()
        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + 3_600,
            signer: account.eventSigner(.redate(Self.now)), now: Self.now
        )
        #expect(result.failure == .signerChangedEvent)
    }

    @Test func aSignatureThatDoesNotVerifyIsCaught() async throws {
        let account = try Account()
        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + 3_600,
            signer: account.eventSigner(.wrongSignature), now: Self.now
        )
        #expect(result.failure == .signerChangedEvent)
    }

    @Test func aSignerThatChangesTheContentIsCaught() async throws {
        let account = try Account()
        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + 3_600,
            signer: account.eventSigner(.otherContent), now: Self.now
        )
        #expect(result.failure == .signerChangedEvent)
    }

    @Test func anEventSignedByAnotherKeyIsCaught() async throws {
        let account = try Account()
        let other = try Account()
        let impostor = FakeEventSigner(privkey: other.privkey, pubkeyHex: other.pubkey, mode: .honest)
        struct Claiming: ScheduleEventSigning {
            let pubkeyHex: String
            let inner: FakeEventSigner
            func signEvent(kind: Int, tags: [[String]], content: String, createdAt: Int) async throws -> NostrEvent {
                try await inner.signEvent(kind: kind, tags: tags, content: content, createdAt: createdAt)
            }
        }
        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + 3_600,
            signer: Claiming(pubkeyHex: account.pubkey, inner: impostor), now: Self.now
        )
        #expect(result.failure == .signerChangedEvent)
    }

    @Test func theRemoteSignerMismatchErrorIsSignerChangedEvent() async throws {
        let account = try Account()
        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + 3_600,
            signer: account.eventSigner(.remoteMismatch), now: Self.now
        )
        #expect(result.failure == .signerChangedEvent)
    }

    @Test func aRefusingSignerIsSignFailed_andAnUnavailableOneIsSignedOut() async throws {
        let account = try Account()
        let refused = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + 3_600,
            signer: account.eventSigner(.refuse), now: Self.now
        )
        #expect(refused.failure == .signFailed)
        let unavailable = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: Self.now + 3_600,
            signer: account.eventSigner(.unavailable), now: Self.now
        )
        #expect(unavailable.failure == .signedOut)
    }

    /// The whole chain for a NIP-46 account: a remote signer that stamps
    /// "now" → `Signer.sign` refuses it → `.signerChangedEvent`.
    @Test func aRemoteSignerThatRedates_endToEnd() async throws {
        actor RedatingRemote: RemoteSigning {
            let privkey: Data
            let pubkey: String
            init(privkey: Data, pubkey: String) { self.privkey = privkey; self.pubkey = pubkey }
            func signEvent(unsigned: [String: Any]) async throws -> NostrEvent {
                let kind = try #require(unsigned["kind"] as? Int)
                let tags = try #require(unsigned["tags"] as? [[String]])
                let content = try #require(unsigned["content"] as? String)
                return try NostrEvent.sign(privkey32: privkey, pubkey: pubkey, kind: kind,
                                           createdAt: NostrClock.now(), tags: tags, content: content)
            }
            func nip44Encrypt(peerPubkeyHex: String, plaintext: String) async throws -> String {
                throw Signer.SignerError.remoteSignerUnsupported
            }
            func nip44Decrypt(peerPubkeyHex: String, ciphertext: String) async throws -> String {
                throw Signer.SignerError.remoteSignerUnsupported
            }
        }

        let account = try Account()
        let listKey = "nip46_account_pubkeys"
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: listKey) ?? []) + [account.pubkey], forKey: listKey)
        Signer.remoteSigningOverrides[account.pubkey] = RedatingRemote(privkey: account.privkey, pubkey: account.pubkey)
        defer {
            Signer.remoteSigningOverrides[account.pubkey] = nil
            let rest = (defaults.stringArray(forKey: listKey) ?? []).filter { $0 != account.pubkey }
            if rest.isEmpty { defaults.removeObject(forKey: listKey) } else { defaults.set(rest, forKey: listKey) }
        }
        let remote = Keypair(privkey: "", pubkey: account.pubkey)
        try #require(remote.isRemote)

        let result = await ScheduleApi.sign(
            kind: 1, tags: [], content: "x", publishAt: NostrClock.now() + 3_600,
            signer: AccountScheduleSigner(keypair: remote)
        )
        #expect(result.failure == .signerChangedEvent)
    }
}

// MARK: - Requests

@MainActor
@Suite(.serialized)
struct ScheduleApiRequestTests {

    static let url = "https://zap.cooking/api/schedule"

    private func created(_ event: NostrEvent, relays: [String] = []) -> ScheduleStubProtocol.Reply {
        let list = relays.map { "\"\($0)\"" }.joined(separator: ",")
        return .http(201, """
        {"id":"\(event.id)","publish_at":\(event.createdAt),"relay_mode":"all","relays":[\(list)],"status":"pending"}
        """)
    }

    // MARK: schedule

    @Test func schedule_postsTheSignedEvent_withAHeaderBoundToTheseBytes() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([created(event, relays: ["wss://a.example.com"])])

        let receipt = try await ScheduleApi.schedule(
            event: event, relays: ["wss://A.example.com/", "wss://nos.lol"],
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        #expect(receipt == ScheduleReceipt(id: event.id, publishAt: event.createdAt, relayMode: .all,
                                           relays: ["wss://a.example.com"], status: .pending,
                                           alreadyScheduled: false))

        let requests = ScheduleStubProtocol.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.url == Self.url)
        #expect(request.contentType == "application/json")
        let body = try #require(request.body)
        #expect(body == "{\"event\":\(event.toJSON()),\"relay_mode\":\"all\",\"relays\":[\"wss://a.example.com\"]}")

        // The event travels exactly as signed.
        let sentObject = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let sentEventObject = try #require(sentObject["event"] as? [String: Any])
        let sentEvent = try #require(NostrEvent(json: sentEventObject))
        #expect(sentEvent.id == event.id)
        #expect(sentEvent.sig == event.sig)
        #expect(sentEvent.createdAt == event.createdAt)
        #expect(sentEvent.hasValidSignature())

        let auth = try authEvent(request.authorization)
        #expect(auth.kind == 27235)
        #expect(auth.content == "")
        #expect(auth.pubkey == account.pubkey)
        #expect(auth.hasValidSignature())
        #expect(abs(auth.createdAt - NostrClock.now()) <= 5)
        #expect(tagValue(auth, "u") == Self.url)
        #expect(tagValue(auth, "method") == "POST")
        #expect(tagValue(auth, "payload") == Nip98.sha256Hex(Data(body.utf8)))
    }

    @Test func schedule_omitsRelaysWhenNoneAreUsable() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([created(event)])

        _ = try await ScheduleApi.schedule(
            event: event, relays: ["wss://nos.lol", "wss://relay.primal.net", "wss://purplepag.es", "ws://x.example.com"],
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        let body = try #require(ScheduleStubProtocol.requests.first?.body)
        #expect(body == "{\"event\":\(event.toJSON()),\"relay_mode\":\"all\"}")
    }

    @Test func schedule_sendsAtMostFourRelays_inOrder() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([created(event)])

        _ = try await ScheduleApi.schedule(
            event: event, relays: (1...6).map { "wss://r\($0).example.com" },
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        let body = try #require(ScheduleStubProtocol.requests.first?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["relays"] as? [String] == (1...4).map { "wss://r\($0).example.com" })
    }

    /// A second schedule with a different body signs its own header: nothing
    /// is cached between calls.
    @Test func schedule_neverReusesAHeader() async throws {
        let account = try Account()
        let first = try account.event(content: "one")
        let second = try account.event(content: "two")
        let signer = CountingNip98Signer(keypair: account.keypair)
        let session = ScheduleStubProtocol.session()
        ScheduleStubProtocol.script([created(first), created(second), .http(200, "{\"items\":[]}"), .http(200, "{\"items\":[]}")])

        _ = try await ScheduleApi.schedule(event: first, signer: signer, session: session).get()
        _ = try await ScheduleApi.schedule(event: second, signer: signer, session: session).get()
        _ = try await ScheduleApi.list(status: .pending, signer: signer, session: session).get()
        _ = try await ScheduleApi.list(status: .pending, signer: signer, session: session).get()

        #expect(signer.count == 4)
        let requests = ScheduleStubProtocol.requests
        #expect(requests.count == 4)
        for request in requests.prefix(2) {
            let auth = try authEvent(request.authorization)
            let body = try #require(request.body)
            #expect(tagValue(auth, "payload") == Nip98.sha256Hex(Data(body.utf8)))
        }
    }

    @Test func schedule_retriesA401Once_withAFreshlySignedHeader() async throws {
        let account = try Account()
        let event = try account.event()
        let signer = CountingNip98Signer(keypair: account.keypair)
        ScheduleStubProtocol.script([.http(401, "{\"error\":\"auth_failed\",\"detail\":\"event\"}"), created(event)])

        let receipt = try await ScheduleApi.schedule(
            event: event, signer: signer, session: ScheduleStubProtocol.session()
        ).get()

        #expect(receipt.status == .pending)
        #expect(signer.count == 2)
        let requests = ScheduleStubProtocol.requests
        #expect(requests.count == 2)
        // The same signed event both times: a retry never re-signs the post.
        #expect(requests.first?.body == requests.last?.body)
    }

    @Test func schedule_aSecond401IsAuthFailed_andIsNotRetriedAgain() async throws {
        let account = try Account()
        let event = try account.event()
        let signer = CountingNip98Signer(keypair: account.keypair)
        let rejected = ScheduleStubProtocol.Reply.http(401, "{\"error\":\"auth_failed\",\"detail\":\"event\"}")
        ScheduleStubProtocol.script([rejected, rejected, created(event)])

        let result = await ScheduleApi.schedule(event: event, signer: signer, session: ScheduleStubProtocol.session())

        #expect(result.failure == .authFailed)
        #expect(signer.count == 2)
        #expect(ScheduleStubProtocol.requests.count == 2)
    }

    @Test func schedule_onBadRelays_retriesOnceWithoutThem() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(400, "{\"error\":\"bad_relays\"}"), created(event)])

        let receipt = try await ScheduleApi.schedule(
            event: event, relays: ["wss://a.example.com"],
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        #expect(receipt.relays == [])
        let requests = ScheduleStubProtocol.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first?.body)
        let second = try #require(requests.last?.body)
        #expect(first.contains("\"relays\":[\"wss://a.example.com\"]"))
        #expect(second == "{\"event\":\(event.toJSON()),\"relay_mode\":\"all\"}")
        // The retry is a different body, so its header is bound to the new bytes.
        let auth = try authEvent(requests.last?.authorization)
        #expect(tagValue(auth, "payload") == Nip98.sha256Hex(Data(second.utf8)))
    }

    @Test func schedule_badRelaysTwice_isBadRelays() async throws {
        let account = try Account()
        let event = try account.event()
        let refused = ScheduleStubProtocol.Reply.http(400, "{\"error\":\"bad_relays\"}")
        ScheduleStubProtocol.script([refused, refused, created(event)])

        let result = await ScheduleApi.schedule(
            event: event, relays: ["wss://a.example.com"],
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .badRelays)
        #expect(ScheduleStubProtocol.requests.count == 2)
    }

    @Test func schedule_badRelaysWithNoneSent_isNotRetried() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(400, "{\"error\":\"bad_relays\"}"), created(event)])

        let result = await ScheduleApi.schedule(
            event: event, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .badRelays)
        #expect(ScheduleStubProtocol.requests.count == 1)
    }

    @Test(arguments: [ScheduleStatus.pending, .publishing, .sent])
    func schedule_alreadyScheduledAndOnItsWay_isSuccess(_ status: ScheduleStatus) async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(409, "{\"error\":\"already_scheduled\",\"status\":\"\(status.rawValue)\"}")])

        let receipt = try await ScheduleApi.schedule(
            event: event, relays: ["wss://a.example.com"],
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        #expect(receipt == ScheduleReceipt(id: event.id, publishAt: event.createdAt, relayMode: .all,
                                           relays: ["wss://a.example.com"], status: status,
                                           alreadyScheduled: true))
    }

    @Test(arguments: [ScheduleStatus.cancelled, .failed])
    func schedule_alreadyScheduledButDead_isAFailureWithTheStatus(_ status: ScheduleStatus) async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(409, "{\"error\":\"already_scheduled\",\"status\":\"\(status.rawValue)\"}")])

        let result = await ScheduleApi.schedule(
            event: event, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .alreadyScheduled(status: status))
    }

    /// Every contract code a create can return, with the contract's status.
    @Test(arguments: [
        (400, "bad_request", ScheduleFailure.badRequest),
        (400, "bad_relay_mode", .badRelayMode),
        (400, "bad_signature", .badSignature),
        (400, "pubkey_mismatch", .pubkeyMismatch),
        (400, "bad_kind", .badKind),
        (400, "kind_not_allowed_for_relay_mode", .kindNotAllowedForRelayMode),
        (400, "bad_publish_time", .badPublishTime),
        (400, "too_large", .tooLarge),
        (400, "poll_closes_before_publish", .pollClosesBeforePublish),
        (400, "quota_exceeded", .quotaExceeded),
        (429, "rate_limited", .rateLimited),
        (500, "not_configured", .notConfigured),
        (500, "internal", .internal),
        // A code another endpoint owns, and one nobody has defined yet.
        (400, "bad_status", .unknown),
        (400, "not_cancellable", .unknown),
        (418, "brand_new_code", .unknown),
    ])
    func schedule_mapsTheErrorCode(_ status: Int, _ code: String, _ expected: ScheduleFailure) async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(status, "{\"error\":\"\(code)\"}")])

        let result = await ScheduleApi.schedule(
            event: event, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == expected)
        // rate_limited and the rest are never retried automatically.
        #expect(ScheduleStubProtocol.requests.count == 1)
    }

    @Test(arguments: [
        (502, "<html>Bad gateway</html>"), (400, ""), (400, "[]"), (400, "{\"code\":\"RATE_LIMITED\"}"),
        (200, "{\"id\":\"x\",\"status\":\"pending\"}"),
    ])
    func schedule_aResponseWithNoKnownCodeIsUnknown(_ status: Int, _ body: String) async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(status, body)])

        let result = await ScheduleApi.schedule(
            event: event, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .unknown)
    }

    @Test func schedule_aRequestThatDoesNotCompleteIsNetwork() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.offline])

        let result = await ScheduleApi.schedule(
            event: event, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .network)
        #expect(ScheduleStubProtocol.requests.count == 1)
    }

    @Test func schedule_anAccountThatCannotSignIsSignedOut_andSendsNothing() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([created(event)])
        let watchOnly = Keypair(privkey: "", pubkey: account.pubkey)

        let result = await ScheduleApi.schedule(
            event: event, signer: LocalNip98Signer(keypair: watchOnly), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .signedOut)
        #expect(ScheduleStubProtocol.requests.isEmpty)
    }

    @Test func schedule_anEventFromAnotherAccountIsNotSent() async throws {
        let account = try Account()
        let other = try Account()
        let event = try other.event()
        ScheduleStubProtocol.script([created(event)])

        let result = await ScheduleApi.schedule(
            event: event, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .pubkeyMismatch)
        #expect(ScheduleStubProtocol.requests.isEmpty)
    }

    @Test func schedule_anEventThatDoesNotVerifyIsNotSent() async throws {
        let account = try Account()
        let real = try account.event()
        let tampered = NostrEvent(id: real.id, pubkey: real.pubkey, kind: real.kind, createdAt: real.createdAt + 60,
                                  tags: real.tags, content: real.content, sig: real.sig)
        ScheduleStubProtocol.script([created(real)])

        let result = await ScheduleApi.schedule(
            event: tampered, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .signerChangedEvent)
        #expect(ScheduleStubProtocol.requests.isEmpty)
    }

    @Test func schedule_pantryModeSendsNoRelays() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(201, """
        {"id":"\(event.id)","publish_at":\(event.createdAt),"relay_mode":"pantry","relays":[],"status":"pending"}
        """)])

        let receipt = try await ScheduleApi.schedule(
            event: event, relayMode: .pantry, relays: ["wss://a.example.com"],
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        #expect(receipt.relayMode == .pantry)
        let body = try #require(ScheduleStubProtocol.requests.first?.body)
        #expect(body == "{\"event\":\(event.toJSON()),\"relay_mode\":\"pantry\"}")
    }

    // MARK: list

    @Test func list_getsWithTheStatusInTheQuery_andSignsTheBareUrl() async throws {
        let account = try Account()
        let soon = try account.event(kind: 1, at: 1_900_000_000, content: "note")
        let poll = try account.event(kind: 1068, at: 1_900_003_600, tags: [["option", "a", "Yes"]], content: "poll?")
        ScheduleStubProtocol.script([.http(200, """
        {"items":[
          {"id":"\(poll.id)","publish_at":\(poll.createdAt),"relay_mode":"pantry","relays":[],
           "status":"pending","attempts":0,"last_error":null,"sent_at":null,"event":\(poll.toJSON())},
          {"id":"\(soon.id)","publish_at":\(soon.createdAt),"relay_mode":"all","relays":["wss://a.example.com"],
           "status":"failed","attempts":10,"last_error":"blocked: spam filter","sent_at":null,"event":\(soon.toJSON())},
          {"id":"no-event","publish_at":1,"relay_mode":"all","relays":[],"status":"pending"},
          {"id":"\(soon.id)","publish_at":\(soon.createdAt),"status":"some_future_status","event":\(soon.toJSON())},
          "not a row"
        ]}
        """)])

        let posts = try await ScheduleApi.list(
            status: .pending, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        // Server order kept; the three unreadable rows skipped, not fatal.
        #expect(posts.count == 2)
        let first = try #require(posts.first)
        #expect(first.id == poll.id)
        #expect(first.publishAt == poll.createdAt)
        #expect(first.relayMode == .pantry)
        #expect(first.status == .pending)
        #expect(first.attempts == 0)
        #expect(first.lastError == nil)
        #expect(first.sentAt == nil)
        #expect(first.event.kind == 1068)
        #expect(first.event.tags == [["option", "a", "Yes"]])
        #expect(first.event.hasValidSignature())
        let second = try #require(posts.last)
        #expect(second.status == .failed)
        #expect(second.attempts == 10)
        #expect(second.lastError == "blocked: spam filter")
        #expect(second.relays == ["wss://a.example.com"])
        #expect(second.event.content == "note")

        let request = try #require(ScheduleStubProtocol.requests.first)
        #expect(ScheduleStubProtocol.requests.count == 1)
        #expect(request.method == "GET")
        #expect(request.url == Self.url + "?status=pending")
        #expect(request.body == nil)
        #expect(request.contentType == nil)
        let auth = try authEvent(request.authorization)
        #expect(auth.kind == 27235)
        #expect(tagValue(auth, "u") == Self.url)
        #expect(tagValue(auth, "method") == "GET")
        #expect(tagValue(auth, "payload") == nil)
    }

    @Test func list_withNoStatusSendsNoQuery_andReadsSentRows() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(200, """
        {"items":[{"id":"\(event.id)","publish_at":\(event.createdAt),"relay_mode":"all","relays":[],
          "status":"sent","attempts":1,"last_error":null,"sent_at":1900000042,"event":\(event.toJSON())}]}
        """)])

        let posts = try await ScheduleApi.list(
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        #expect(ScheduleStubProtocol.requests.first?.url == Self.url)
        let post = try #require(posts.first)
        #expect(post.status == .sent)
        #expect(post.sentAt == 1_900_000_042)
    }

    @Test func list_anEmptyListIsEmpty() async throws {
        let account = try Account()
        ScheduleStubProtocol.script([.http(200, "{\"items\":[]}")])
        let posts = try await ScheduleApi.list(
            status: .failed, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()
        #expect(posts.isEmpty)
        #expect(ScheduleStubProtocol.requests.first?.url == Self.url + "?status=failed")
    }

    @Test(arguments: [
        (400, "{\"error\":\"bad_status\"}", ScheduleFailure.badStatus),
        (500, "{\"error\":\"not_configured\"}", .notConfigured),
        (500, "{\"error\":\"internal\"}", .internal),
        (400, "{\"error\":\"quota_exceeded\"}", .unknown),
        (200, "{\"rows\":[]}", .unknown),
    ])
    func list_mapsFailures(_ status: Int, _ body: String, _ expected: ScheduleFailure) async throws {
        let account = try Account()
        ScheduleStubProtocol.script([.http(status, body)])
        let result = await ScheduleApi.list(
            status: .pending, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )
        #expect(result.failure == expected)
    }

    @Test func list_retriesA401Once_thenReportsAuthFailed() async throws {
        let account = try Account()
        let signer = CountingNip98Signer(keypair: account.keypair)
        let rejected = ScheduleStubProtocol.Reply.http(401, "{\"error\":\"auth_failed\",\"detail\":\"event\"}")

        ScheduleStubProtocol.script([rejected, .http(200, "{\"items\":[]}")])
        let recovered = await ScheduleApi.list(status: .pending, signer: signer, session: ScheduleStubProtocol.session())
        #expect(recovered.failure == nil)
        #expect(signer.count == 2)

        ScheduleStubProtocol.script([rejected, rejected])
        let refused = await ScheduleApi.list(status: .pending, signer: signer, session: ScheduleStubProtocol.session())
        #expect(refused.failure == .authFailed)
        #expect(ScheduleStubProtocol.requests.count == 2)
    }

    @Test func list_offlineIsNetwork_andWatchOnlyIsSignedOut() async throws {
        let account = try Account()
        ScheduleStubProtocol.script([.offline])
        let offline = await ScheduleApi.list(
            signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )
        #expect(offline.failure == .network)

        ScheduleStubProtocol.script([.http(200, "{\"items\":[]}")])
        let watchOnly = await ScheduleApi.list(
            signer: LocalNip98Signer(keypair: Keypair(privkey: "", pubkey: account.pubkey)),
            session: ScheduleStubProtocol.session()
        )
        #expect(watchOnly.failure == .signedOut)
        #expect(ScheduleStubProtocol.requests.isEmpty)
    }

    // MARK: cancel

    @Test func cancel_deletesById_withAHeaderForThatUrl() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(200, "{\"id\":\"\(event.id)\",\"status\":\"cancelled\"}")])

        let done = try await ScheduleApi.cancel(
            id: event.id, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        #expect(done == ScheduleCancellation(id: event.id, alreadyCancelled: false))
        #expect(ScheduleStubProtocol.requests.count == 1)
        let request = try #require(ScheduleStubProtocol.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.url == Self.url + "/" + event.id)
        #expect(request.body == nil)
        let auth = try authEvent(request.authorization)
        #expect(tagValue(auth, "u") == Self.url + "/" + event.id)
        #expect(tagValue(auth, "method") == "DELETE")
        #expect(tagValue(auth, "payload") == nil)
    }

    @Test func cancel_alreadyCancelledCountsAsDone() async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(409, "{\"error\":\"not_cancellable\",\"status\":\"cancelled\"}")])

        let done = try await ScheduleApi.cancel(
            id: event.id, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        ).get()

        #expect(done == ScheduleCancellation(id: event.id, alreadyCancelled: true))
    }

    @Test(arguments: [ScheduleStatus.publishing, .sent, .failed])
    func cancel_notCancellableSaysWhatHappened(_ status: ScheduleStatus) async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(409, "{\"error\":\"not_cancellable\",\"status\":\"\(status.rawValue)\"}")])

        let result = await ScheduleApi.cancel(
            id: event.id, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )

        #expect(result.failure == .notCancellable(status: status))
    }

    @Test(arguments: [
        (404, "{\"error\":\"not_found\"}", ScheduleFailure.notFound),
        (409, "{\"error\":\"not_cancellable\"}", .notCancellable(status: nil)),
        (500, "{\"error\":\"internal\"}", .internal),
        (500, "{\"error\":\"not_configured\"}", .notConfigured),
        (400, "{\"error\":\"bad_kind\"}", .unknown),
        // A 200 that does not say cancelled is not a cancellation.
        (200, "{\"id\":\"x\",\"status\":\"pending\"}", .unknown),
        (200, "", .unknown),
    ])
    func cancel_mapsFailures(_ status: Int, _ body: String, _ expected: ScheduleFailure) async throws {
        let account = try Account()
        let event = try account.event()
        ScheduleStubProtocol.script([.http(status, body)])
        let result = await ScheduleApi.cancel(
            id: event.id, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )
        #expect(result.failure == expected)
    }

    @Test(arguments: ["", "abc", "../schedule", String(repeating: "g", count: 64), String(repeating: "A", count: 64),
                      String(repeating: "a", count: 63), String(repeating: "a", count: 64) + "?x=1"])
    func cancel_anythingButAnEventIdIsNotFound_andSendsNothing(_ id: String) async throws {
        let account = try Account()
        ScheduleStubProtocol.script([.http(200, "{\"status\":\"cancelled\"}")])
        let result = await ScheduleApi.cancel(
            id: id, signer: LocalNip98Signer(keypair: account.keypair), session: ScheduleStubProtocol.session()
        )
        #expect(result.failure == .notFound)
        #expect(ScheduleStubProtocol.requests.isEmpty)
    }

    @Test func cancel_retriesA401Once_andOfflineIsNetwork() async throws {
        let account = try Account()
        let event = try account.event()
        let signer = CountingNip98Signer(keypair: account.keypair)
        ScheduleStubProtocol.script([
            .http(401, "{\"error\":\"auth_failed\",\"detail\":\"event\"}"),
            .http(200, "{\"id\":\"\(event.id)\",\"status\":\"cancelled\"}"),
        ])
        let done = await ScheduleApi.cancel(id: event.id, signer: signer, session: ScheduleStubProtocol.session())
        #expect(done.failure == nil)
        #expect(signer.count == 2)

        ScheduleStubProtocol.script([.offline])
        let offline = await ScheduleApi.cancel(id: event.id, signer: signer, session: ScheduleStubProtocol.session())
        #expect(offline.failure == .network)
    }
}

// MARK: - Codes

struct ScheduleFailureCodeTests {
    /// The contract's error table, code for code.
    @Test func everyContractCodeHasItsOwnCase() {
        let codes: [(String, ScheduleFailure)] = [
            ("auth_failed", .authFailed), ("bad_request", .badRequest), ("bad_relay_mode", .badRelayMode),
            ("bad_relays", .badRelays), ("bad_signature", .badSignature), ("pubkey_mismatch", .pubkeyMismatch),
            ("bad_kind", .badKind), ("kind_not_allowed_for_relay_mode", .kindNotAllowedForRelayMode),
            ("bad_publish_time", .badPublishTime), ("too_large", .tooLarge),
            ("poll_closes_before_publish", .pollClosesBeforePublish),
            ("already_scheduled", .alreadyScheduled(status: nil)), ("quota_exceeded", .quotaExceeded),
            ("rate_limited", .rateLimited), ("bad_status", .badStatus), ("not_found", .notFound),
            ("not_cancellable", .notCancellable(status: nil)), ("not_configured", .notConfigured),
            ("internal", .internal),
        ]
        #expect(codes.count == 19)
        for (code, expected) in codes {
            #expect(ScheduleFailure(code: code) == expected)
            #expect(expected != .unknown)
        }
        #expect(Set(codes.map(\.0)).count == codes.count)
        #expect(ScheduleFailure(code: "AUTH_FAILED") == .unknown)
        #expect(ScheduleFailure(code: "") == .unknown)
    }

    @Test func theStatusNamesAreTheContracts() {
        #expect(ScheduleStatus.allCases.map(\.rawValue) == ["pending", "publishing", "sent", "failed", "cancelled"])
        #expect(ScheduleRelayMode.all.rawValue == "all")
        #expect(ScheduleRelayMode.pantry.rawValue == "pantry")
    }
}
