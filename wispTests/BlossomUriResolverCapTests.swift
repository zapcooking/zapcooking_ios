//
//  BlossomUriResolverCapTests.swift
//  wispTests
//
//  The resolver downloads a whole blob to check its hash, so the download
//  is capped. Every request here goes to an in-process URLProtocol stub on
//  the resolver's own session: nothing reaches the network, including the
//  signed-in account's Blossom servers (the stub answers 404 for any host
//  it was not given).
//

import CryptoKit
import Foundation
import Testing
@testable import wisp

@Suite(.serialized)
struct BlossomUriResolverCapTests {

    // MARK: - Fixtures

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A blob served by a fresh stub host; returns the `blossom:` URI.
    private static func serve(
        _ body: Data, declaredLength: Int? = nil, sz: Int? = nil
    ) -> (uri: String, host: String) {
        let host = "\(UUID().uuidString.lowercased()).blossom.test"
        BlossomStubProtocol.set(host: host, route: .init(body: body, declaredLength: declaredLength))
        var uri = "blossom:\(hex(body)).jpg?xs=\(host)"
        if let sz { uri += "&sz=\(sz)" }
        return (uri, host)
    }

    private static func resolver(cap: Int) -> BlossomUriResolver {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BlossomStubProtocol.self]
        return BlossomUriResolver(session: URLSession(configuration: config), maxBlobBytes: cap)
    }

    private static func blob(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    // MARK: - Control: the stub path resolves

    @Test func blobUnderTheCap_resolvesToTheServerUrl() async {
        let body = Self.blob(4096)
        let (uri, host) = Self.serve(body)
        let hit = await Self.resolver(cap: 8192).resolve(uri)
        #expect(hit == "https://\(host)/\(Self.hex(body))")
    }

    @Test func blobExactlyAtTheCap_resolves() async {
        let body = Self.blob(4096)
        let (uri, _) = Self.serve(body)
        #expect(await Self.resolver(cap: 4096).resolve(uri) != nil)
    }

    // MARK: - Oversized

    /// No Content-Length, a correctly hashed body one byte past the cap:
    /// the stream stops at the cap and the candidate is a miss, though the
    /// bytes would have verified.
    @Test func oversizedBodyWithoutContentLength_isRejected() async {
        let body = Self.blob(4097)
        let (uri, host) = Self.serve(body)
        let hit = await Self.resolver(cap: 4096).resolve(uri)
        #expect(hit == nil)
        #expect(BlossomStubProtocol.requests(host: host) == 1)
    }

    /// An endless body (a server that never stops sending) over a 1 MB cap:
    /// the resolver gives up at the cap and cancels the transfer. The stub
    /// only stops when it is told to (or at a 64 MB safety bound), so an
    /// uncapped resolver would read the whole bound and the stub would
    /// never see an early stop.
    @Test func endlessBody_transferIsCancelledAtTheCap() async throws {
        let body = Self.blob(1024)
        let host = "\(UUID().uuidString.lowercased()).blossom.test"
        BlossomStubProtocol.set(host: host, route: .init(body: body, declaredLength: nil, endless: true))
        let uri = "blossom:\(Self.hex(body)).jpg?xs=\(host)"
        let hit = await Self.resolver(cap: 1024 * 1024).resolve(uri)
        #expect(hit == nil)
        // URLSession calls stopLoading after the cancel, on its own thread.
        var stopped = false
        for _ in 0..<200 where !stopped {
            stopped = BlossomStubProtocol.stoppedEarly(host: host)
            if !stopped { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(stopped, "the transfer ran to the stub's 64 MB bound instead of stopping at the cap")
        #expect(BlossomStubProtocol.sentBytes(host: host) < 64 * 1024 * 1024)
    }

    /// Content-Length over the cap: rejected from the header alone. The
    /// body actually sent is small and hashes correctly, so only the
    /// declared length can be the reason.
    @Test func declaredLengthOverTheCap_isRejectedFromTheHeader() async {
        let body = Self.blob(1024)
        let (uri, _) = Self.serve(body, declaredLength: 10 * 1024 * 1024)
        #expect(await Self.resolver(cap: 4096).resolve(uri) == nil)
    }

    /// The URI's own `sz` over the cap: never fetched at all.
    @Test func uriSizeOverTheCap_isNotFetched() async {
        let body = Self.blob(1024)
        let (uri, host) = Self.serve(body, sz: 5000)
        #expect(await Self.resolver(cap: 4096).resolve(uri) == nil)
        #expect(BlossomStubProtocol.requests(host: host) == 0)
    }

    /// An over-cap hint does not stop the next candidate: the first server
    /// sends too much, the second the real blob.
    @Test func oversizedCandidate_fallsThroughToTheNextServer() async {
        let body = Self.blob(2048)
        let hash = Self.hex(body)
        let big = "\(UUID().uuidString.lowercased()).blossom.test"
        let good = "\(UUID().uuidString.lowercased()).blossom.test"
        BlossomStubProtocol.set(host: big, route: .init(body: body + Self.blob(8192), declaredLength: nil))
        BlossomStubProtocol.set(host: good, route: .init(body: body, declaredLength: nil))
        let uri = "blossom:\(hash).jpg?xs=\(big)&xs=\(good)"
        let hit = await Self.resolver(cap: 4096).resolve(uri)
        #expect(hit == "https://\(good)/\(hash)")
    }

    @Test func defaultCapIsTwentyMegabytes() {
        #expect(BlossomUriResolver.defaultMaxBlobBytes == 20 * 1024 * 1024)
    }
}

// MARK: - Stub transport

/// Serves registered hosts from memory, in 64 KB chunks, and records how
/// many requests each host saw and whether a transfer was stopped before
/// its body was fully sent. Unregistered hosts get a 404.
nonisolated final class BlossomStubProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        let body: Data
        let declaredLength: Int?
        /// Repeat `body` until stopped (or the 64 MB safety bound).
        var endless = false
    }

    static let endlessBound = 64 * 1024 * 1024

    private struct HostState {
        var route: Route
        var requests = 0
        var stoppedEarly = false
        var sentBytes = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String: HostState] = [:]

    static func set(host: String, route: Route) {
        lock.withLock { hosts[host] = HostState(route: route) }
    }

    static func requests(host: String) -> Int {
        lock.withLock { hosts[host]?.requests ?? 0 }
    }

    static func stoppedEarly(host: String) -> Bool {
        lock.withLock { hosts[host]?.stoppedEarly ?? false }
    }

    static func sentBytes(host: String) -> Int {
        lock.withLock { hosts[host]?.sentBytes ?? 0 }
    }

    private let stateLock = NSLock()
    nonisolated(unsafe) private var stopped = false
    nonisolated(unsafe) private var finished = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let route: Route? = Self.lock.withLock {
            guard var state = Self.hosts[host] else { return nil }
            state.requests += 1
            Self.hosts[host] = state
            return state.route
        }
        guard let route else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = ["Content-Type": "image/jpeg"]
        if let declared = route.declaredLength { headers["Content-Length"] = String(declared) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // Deliver off the loading thread so stopLoading can land mid-body.
        let body = route.body
        let total = route.endless ? Self.endlessBound : body.count
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let chunk = 64 * 1024
            var offset = 0
            while offset < total {
                if stateLock.withLock({ stopped }) { break }
                let end = min(offset + chunk, total)
                var piece = Data(capacity: end - offset)
                var at = offset
                while at < end {
                    let from = at % body.count
                    let take = min(end - at, body.count - from)
                    piece.append(body.subdata(in: from..<(from + take)))
                    at += take
                }
                client?.urlProtocol(self, didLoad: piece)
                offset = end
                Self.lock.withLock { Self.hosts[host]?.sentBytes = offset }
                Thread.sleep(forTimeInterval: 0.001)
            }
            let sentAll = offset >= total
            let wasStopped = stateLock.withLock { () -> Bool in
                finished = true
                return stopped
            }
            if sentAll && !wasStopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        let earlyStop = stateLock.withLock { () -> Bool in
            stopped = true
            return !finished
        }
        guard earlyStop, let host = request.url?.host else { return }
        Self.lock.withLock { Self.hosts[host]?.stoppedEarly = true }
    }
}
