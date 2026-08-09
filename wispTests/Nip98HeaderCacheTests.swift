import Foundation
import Testing
@testable import wisp

/// `Nip98HeaderCache` behavior per Phase 0 decision 1
/// (CHEFFY_NOTE_REVIEW_PLAN.md): 30s TTL keyed on
/// (method, normalized URL, body hash); a 401 against a CACHED header is
/// invalidated, re-signed once, and retried once; a 401 against a fresh
/// header is returned as-is. Ported from Android `Nip98HeaderCacheTest`
/// with an injected clock.
struct Nip98HeaderCacheTests {

    private final class Clock: @unchecked Sendable {
        var now: Int64 = 0
    }

    private func makeCache(clock: Clock, ttlMillis: Int64 = Nip98HeaderCache.defaultTTLMillis) -> Nip98HeaderCache {
        Nip98HeaderCache(ttlMillis: ttlMillis, clock: { clock.now })
    }

    private let url = "https://zap.cooking/api/zappy/note-review/credit-status?id=abc"

    // MARK: - TTL / keying

    @Test func withinTtl_reusesHeaderWithoutResigning() async throws {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()

        let first = try await cache.authHeader(signer: signer, method: "GET", url: url)
        clock.now += 29_999
        let second = try await cache.authHeader(signer: signer, method: "GET", url: url)

        #expect(signer.signCount == 1)
        #expect(first.header == second.header)
        #expect(first.fromCache == false)
        #expect(second.fromCache == true)
    }

    @Test func afterTtl_resigns() async throws {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()

        let first = try await cache.authHeader(signer: signer, method: "GET", url: url)
        clock.now += 30_000
        let second = try await cache.authHeader(signer: signer, method: "GET", url: url)

        #expect(signer.signCount == 2)
        #expect(first.header != second.header)
        #expect(second.fromCache == false)
    }

    @Test func differentQueryString_sharesTheKey() async throws {
        // The u tag excludes the query (Nip98.normalizeUrl), so a header
        // signed for ?id=a is verifier-valid for ?id=b — the cache must
        // key the same way or the poll re-signs for no reason.
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()

        let a = try await cache.authHeader(
            signer: signer, method: "GET",
            url: "https://zap.cooking/api/x?id=a"
        )
        let b = try await cache.authHeader(
            signer: signer, method: "GET",
            url: "https://zap.cooking/api/x?id=b"
        )

        #expect(signer.signCount == 1)
        #expect(a.header == b.header)
        #expect(b.fromCache == true)
    }

    @Test func differentBody_getsItsOwnKey() async throws {
        // A cached header binds its payload hash; different body bytes
        // must never reuse it.
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()

        _ = try await cache.authHeader(
            signer: signer, method: "POST",
            url: "https://zap.cooking/api/x",
            bodyString: #"{"a":1}"#
        )
        let other = try await cache.authHeader(
            signer: signer, method: "POST",
            url: "https://zap.cooking/api/x",
            bodyString: #"{"a":2}"#
        )

        #expect(signer.signCount == 2)
        #expect(other.fromCache == false)
    }

    @Test func differentMethod_getsItsOwnKey() async throws {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()

        _ = try await cache.authHeader(
            signer: signer, method: "GET",
            url: "https://zap.cooking/api/x"
        )
        let post = try await cache.authHeader(
            signer: signer, method: "POST",
            url: "https://zap.cooking/api/x"
        )

        #expect(signer.signCount == 2)
        #expect(post.fromCache == false)
    }

    @Test func invalidate_forcesResign() async throws {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()

        _ = try await cache.authHeader(signer: signer, method: "GET", url: url)
        cache.invalidate(pubkeyHex: signer.pubkeyHex, method: "GET", url: url)
        let second = try await cache.authHeader(signer: signer, method: "GET", url: url)

        #expect(signer.signCount == 2)
        #expect(second.fromCache == false)
    }

    // MARK: - Identity scoping (audit B2)

    @Test func sameRequestShape_underTwoSigners_neverSharesAHeader() async throws {
        // A cached Authorization header IS an identity assertion — an
        // account switch inside the TTL must never let one account's
        // header authenticate another's request.
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()
        let signerA = FakeNip98Signer(pubkeyHex: String(repeating: "cd", count: 32))

        let a = try await cache.authHeader(signer: signerA, method: "GET", url: url)
        let b = try await cache.authHeader(signer: signer, method: "GET", url: url)

        #expect(a.fromCache == false)
        #expect(b.fromCache == false) // B signed fresh — no cross-identity hit
        #expect(a.header != b.header)
        #expect(signerA.signCount == 1)
        #expect(signer.signCount == 1)

        // Each identity still enjoys its own cache.
        let aAgain = try await cache.authHeader(signer: signerA, method: "GET", url: url)
        #expect(aAgain.fromCache == true)
        #expect(a.header == aAgain.header)
        #expect(signerA.signCount == 1)
    }

    @Test func clear_dropsEveryCachedHeader() async throws {
        // The account-switch belt to the per-pubkey key's suspenders.
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()

        _ = try await cache.authHeader(signer: signer, method: "GET", url: url)
        cache.clear()
        let again = try await cache.authHeader(signer: signer, method: "GET", url: url)

        #expect(again.fromCache == false)
        #expect(signer.signCount == 2)
    }

    // MARK: - 401 retry rule

    @Test func unauthorizedOnCachedHeader_resignsAndRetriesOnce() async throws {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()
        let warm = try await cache.authHeader(signer: signer, method: "GET", url: url)
        var sentHeaders: [String] = []

        let result = try await cache.withAuthHeader(
            signer: signer,
            method: "GET",
            url: url,
            isUnauthorized: { $0 == 401 }
        ) { header in
            sentHeaders.append(header)
            return sentHeaders.count == 1 ? 401 : 200
        }

        #expect(result == 200)
        #expect(sentHeaders.count == 2)
        #expect(sentHeaders[0] == warm.header)       // first attempt used the cache
        #expect(sentHeaders[0] != sentHeaders[1])    // retry used a fresh sign
        #expect(signer.signCount == 2)               // warm + re-sign, nothing more
    }

    @Test func unauthorizedOnFreshHeader_isNotRetried() async throws {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()
        var sends = 0

        let result = try await cache.withAuthHeader(
            signer: signer,
            method: "GET",
            url: url,
            isUnauthorized: { $0 == 401 }
        ) { _ in
            sends += 1
            return 401
        }

        #expect(result == 401)
        #expect(sends == 1)
        #expect(signer.signCount == 1)
    }

    @Test func persistentUnauthorizedOnCachedHeader_retriesExactlyOnce() async throws {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()
        _ = try await cache.authHeader(signer: signer, method: "GET", url: url) // warm
        var sends = 0

        let result = try await cache.withAuthHeader(
            signer: signer,
            method: "GET",
            url: url,
            isUnauthorized: { $0 == 401 }
        ) { _ in
            sends += 1
            return 401
        }

        #expect(result == 401)
        #expect(sends == 2)
        #expect(signer.signCount == 2)
    }

    @Test func successOnCachedHeader_doesNotResign() async throws {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        let signer = FakeNip98Signer()
        _ = try await cache.authHeader(signer: signer, method: "GET", url: url) // warm
        var sends = 0

        let result = try await cache.withAuthHeader(
            signer: signer,
            method: "GET",
            url: url,
            isUnauthorized: { $0 == 401 }
        ) { _ in
            sends += 1
            return 200
        }

        #expect(result == 200)
        #expect(sends == 1)
        #expect(signer.signCount == 1)
    }
}

/// JVM-only FakeNip98Signer port: builds a real unsigned event id (sha256)
/// and stamps a dummy signature. Each sign gets a distinct, monotonically
/// increasing `created_at`, so a re-sign always yields different header bytes.
private final class FakeNip98Signer: Nip98Signing, @unchecked Sendable {
    let pubkeyHex: String
    private(set) var signCount = 0

    init(pubkeyHex: String = String(repeating: "ab", count: 32)) {
        self.pubkeyHex = pubkeyHex
    }

    func signEvent(kind: Int, content: String, tags: [[String]]) async throws -> NostrEvent {
        signCount += 1
        let createdAt = 1_700_000_000 + signCount
        let id = NostrEvent.computeId(
            pubkey: pubkeyHex,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )
        return NostrEvent(
            id: id,
            pubkey: pubkeyHex,
            kind: kind,
            createdAt: createdAt,
            tags: tags,
            content: content,
            sig: String(repeating: "0", count: 128)
        )
    }
}
