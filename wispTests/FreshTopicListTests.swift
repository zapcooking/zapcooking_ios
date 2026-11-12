import Foundation
import Testing
@testable import wisp

/// The NIP-11 topic-list GET (`FreshTopicList`): its exact request, its
/// cookie-free session, the cache lifetime and the failure holds. The wire
/// tests go through an in-process URLProtocol stub on the list's own
/// session, so nothing reaches the network.
@Suite(.serialized)
struct FreshTopicListTests {

    // MARK: - Fixtures

    static let nip11: Data = Data("""
    {"name":"Zap Cooking feed","topics":{"parents":[
      {"slug":"baking","name":"Baking","count_14d":40,"topics":[
        {"slug":"sourdough","name":"Sourdough","count_14d":12},
        {"slug":"bread","name":"Bread","count_14d":9}]},
      {"slug":"drinks","name":"Drinks","count_14d":30,"topics":[
        {"slug":"coffee","name":"Coffee","count_14d":20}]}]}}
    """.utf8)

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
        func advance(_ seconds: TimeInterval) { lock.lock(); _now += seconds; lock.unlock() }
    }

    /// A scripted fetch: each call takes the next reply (the last repeats).
    final class Fetcher: @unchecked Sendable {
        enum Reply { case ok(Data), status(Int), error }
        private let lock = NSLock()
        private var replies: [Reply]
        private(set) var requests: [URLRequest] = []
        init(_ replies: [Reply]) { self.replies = replies }

        func set(_ replies: [Reply]) { lock.lock(); self.replies = replies; lock.unlock() }

        private func next(_ request: URLRequest) -> Reply {
            lock.withLock {
                requests.append(request)
                return replies.count > 1 ? replies.removeFirst() : replies[0]
            }
        }

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            switch next(request) {
            case .ok(let data):
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .status(let code):
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            case .error:
                throw URLError(.notConnectedToInternet)
            }
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    }

    static func list(_ fetcher: Fetcher, clock: Clock = Clock(), enabled: Bool = true) -> FreshTopicList {
        FreshTopicList(fetch: { try await fetcher.fetch($0) }, now: { clock.now }, enabled: { enabled })
    }

    // MARK: - The request

    @Test("the request is a plain GET of https://feed.zap.cooking with only Accept: application/nostr+json")
    func requestShape() {
        let request = FreshTopicList.request(URL(string: FreshTopicCatalog.nip11Url())!)
        #expect(request.url?.absoluteString == "https://feed.zap.cooking")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.allHTTPHeaderFields == ["Accept": "application/nostr+json"])
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("the session keeps no cookies, cache or credentials")
    func sessionShape() {
        let config = FreshTopicList.makeSession().configuration
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCache == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// The stub sees the request the session hands its protocol. It does not
    /// see cookie headers (checked 2026-11-11 by turning cookies on: this
    /// test still passed while the two above failed), so the cookie
    /// guarantee is the two tests above, not this one.
    @Test("on the wire: one GET to the relay's host with Accept and no Authorization")
    func wireRequest() async throws {
        let host = "\(UUID().uuidString.lowercased()).topics.test"
        TopicStubProtocol.serve(host: host, body: Self.nip11)

        let session = FreshTopicList.makeSession(protocolClasses: [TopicStubProtocol.self])
        let list = FreshTopicList(relayUrl: "wss://\(host)", fetch: { try await session.data(for: $0) },
                                  enabled: { true })
        let groups = await list.groups()
        #expect(groups.map(\.slug) == ["baking", "drinks"])

        let seen = try #require(TopicStubProtocol.requests(host: host).first)
        #expect(seen.httpMethod == "GET")
        #expect(seen.url?.scheme == "https")
        #expect(seen.url?.host == host)
        #expect(["", "/"].contains(seen.url?.path ?? "?"))
        #expect(seen.url?.query == nil)
        #expect(seen.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(seen.value(forHTTPHeaderField: "Accept") == "application/nostr+json")
    }

    // MARK: - Cache

    @Test("a usable list is kept for six hours: one request, then another after it expires")
    func cachedForItsLifetime() async {
        let fetcher = Fetcher([.ok(Self.nip11)])
        let clock = Clock()
        let list = Self.list(fetcher, clock: clock)
        #expect(await list.groups().count == 2)
        clock.advance(FreshTopicList.successLifetime - 1)
        #expect(await list.groups().count == 2)
        #expect(fetcher.count == 1)
        clock.advance(2)
        #expect(await list.groups().count == 2)
        #expect(fetcher.count == 2)
    }

    @Test("callers that arrive during a request share it")
    func concurrentCallersShare() async {
        let fetcher = Fetcher([.ok(Self.nip11)])
        let list = Self.list(fetcher)
        async let a = list.groups()
        async let b = list.groups()
        async let c = list.groups()
        let counts = await [a.count, b.count, c.count]
        #expect(counts == [2, 2, 2])
        #expect(fetcher.count == 1)
    }

    // MARK: - Failures

    @Test("a failure is no list (no spotlights), and the next request waits 2, 5, 15, 30, 30 min")
    func failureHolds() async {
        let fetcher = Fetcher([.error])
        let clock = Clock()
        let list = Self.list(fetcher, clock: clock)
        var holds: [TimeInterval] = []
        for _ in 0..<5 {
            #expect(await list.groups().isEmpty)
            let hold = await list.holdLeft()
            holds.append(hold)
            // During the hold: no request, however often it is asked.
            let before = fetcher.count
            for _ in 0..<20 { _ = await list.groups() }
            clock.advance(hold - 1)
            _ = await list.groups()
            #expect(fetcher.count == before)
            clock.advance(1)
        }
        #expect(holds == [120, 300, 900, 1800, 1800])
        #expect(fetcher.count == 5)
        // A success ends the holds.
        fetcher.set([.ok(Self.nip11)])
        #expect(await list.groups().count == 2)
        #expect(await list.holdLeft() == 0)
    }

    @Test("not a usable list: a non-2xx status, a body that isn't JSON, no topics, an oversized body")
    func unusableAnswersFail() async {
        let oversized = Data(repeating: 0x20, count: FreshTopicList.maxBodyBytes + 1)
        for reply: Fetcher.Reply in [.status(503), .status(404), .ok(Data("<html>".utf8)),
                                     .ok(Data(#"{"name":"x"}"#.utf8)), .ok(oversized)] {
            let fetcher = Fetcher([reply])
            let list = Self.list(fetcher)
            #expect(await list.groups().isEmpty)
            #expect(await list.holdLeft() == 120)
        }
    }

    @Test("an expired list is kept when the refresh fails")
    func staleListKeptOnFailure() async {
        let fetcher = Fetcher([.ok(Self.nip11), .error])
        let clock = Clock()
        let list = Self.list(fetcher, clock: clock)
        #expect(await list.groups().count == 2)
        clock.advance(FreshTopicList.successLifetime + 1)
        #expect(await list.groups().count == 2)
        #expect(fetcher.count == 2)
        #expect(await list.holdLeft() == 120)
        #expect(await list.groups().count == 2)
        #expect(fetcher.count == 2)
    }

    @Test("disabled (the flag): no request")
    func disabledSendsNothing() async {
        let fetcher = Fetcher([.ok(Self.nip11)])
        let list = Self.list(fetcher, enabled: false)
        #expect(await list.groups().isEmpty)
        #expect(fetcher.count == 0)
    }

    @Test("by default the list follows the flag, which ships on (a scripted fetch: no network)")
    func defaultFollowsTheFlag() async {
        #expect(FeatureFlags.freshSpecialsEnabled == true)
        let fetcher = Fetcher([.ok(Self.nip11)])
        let list = FreshTopicList(fetch: { try await fetcher.fetch($0) })
        #expect(await list.groups().count == 2)
        #expect(fetcher.count == 1)
    }
}

/// Serves a NIP-11 body for registered hosts and records each request.
final class TopicStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    static func serve(host: String, body: Data) {
        lock.lock(); bodies[host] = body; lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock()
        Self.seen[host, default: []].append(request)
        let body = Self.bodies[host]
        Self.lock.unlock()
        let status = body == nil ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/nostr+json",
                                                      "Set-Cookie": "tracker=1; Path=/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
