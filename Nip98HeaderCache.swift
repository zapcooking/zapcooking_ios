import Foundation

/// TTL cache for NIP-98 `Authorization` headers (Phase 0 decision 1,
/// CHEFFY_NOTE_REVIEW_PLAN.md).
///
/// The zap.cooking verifier (`src/lib/nip98.server.ts`) accepts a signed
/// kind-27235 event while `|now - created_at| <= 60s` and keeps no replay
/// state, so one signed header may legally authenticate any number of
/// requests inside that window. Re-signing every request is wasted work —
/// and this cache reduces that to at most one sign per TTL window.
///
/// Keyed on `(pubkey, method, normalized URL, payload hash)`. The URL is
/// canonicalized with `Nip98.normalizeUrl` — the same normalization the
/// `u` tag uses — so requests that differ only in query string share one
/// header. A body-bearing request is keyed on its payload hash, so a
/// cached header can never be replayed against different body bytes.
///
/// The TTL is 30s — half the verifier window — so a cached header is never
/// presented during its clock-skew-sensitive final seconds. Fresh signs
/// always use a new `created_at` (never a cached timestamp).
final class Nip98HeaderCache: @unchecked Sendable {
    /// Process-wide singleton shared by `ZapCookingApi` (and future NIP-98
    /// callers) so a signed header is reused across requests inside its TTL
    /// window regardless of which call site issued it.
    static let shared = Nip98HeaderCache()

    static let defaultTTLMillis: Int64 = 30_000

    /// A header value plus whether it was served from cache (drives the 401 retry rule).
    struct CachedHeader: Sendable {
        let header: String
        let fromCache: Bool
    }

    /// The signer's pubkey is part of the key (audit finding B2): a header
    /// IS an identity assertion, and this cache can outlive an account
    /// switch — a cache hit must never hand one account's Authorization
    /// header to another.
    private struct Key: Hashable {
        let pubkey: String
        let method: String
        let normalizedUrl: String
        let payloadHash: String?
    }

    private struct Entry {
        let header: String
        let signedAtMillis: Int64
    }

    private let ttlMillis: Int64
    private let clock: () -> Int64
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    init(
        ttlMillis: Int64 = Nip98HeaderCache.defaultTTLMillis,
        clock: @escaping () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        }
    ) {
        self.ttlMillis = ttlMillis
        self.clock = clock
    }

    /// Return a cached header for this request shape AND signer identity,
    /// or sign a fresh one. Signing happens outside the lock; two concurrent
    /// misses may sign twice, which is harmless.
    func authHeader(
        signer: Nip98Signing,
        method: String,
        url: String,
        bodyString: String? = nil
    ) async throws -> CachedHeader {
        let key = keyFor(pubkeyHex: signer.pubkeyHex, method: method, url: url, bodyString: bodyString)
        lock.lock()
        let cached = entries[key]
        let now = clock()
        let hit = cached.flatMap { entry -> Entry? in
            (now - entry.signedAtMillis) < ttlMillis ? entry : nil
        }
        lock.unlock()
        if let hit {
            return CachedHeader(header: hit.header, fromCache: true)
        }

        let header = try await Nip98.authHeader(
            signer: signer,
            method: method,
            url: url,
            bodyString: bodyString
        )
        lock.lock()
        entries[key] = Entry(header: header, signedAtMillis: clock())
        lock.unlock()
        return CachedHeader(header: header, fromCache: false)
    }

    /// Convenience: local-key path used by production callers.
    func authHeader(
        keypair: Keypair,
        method: String,
        url: String,
        bodyString: String? = nil
    ) async throws -> CachedHeader {
        try await authHeader(
            signer: LocalNip98Signer(keypair: keypair),
            method: method,
            url: url,
            bodyString: bodyString
        )
    }

    /// Drop the cached header for this signer + request shape (if any).
    func invalidate(pubkeyHex: String, method: String, url: String, bodyString: String? = nil) {
        let key = keyFor(pubkeyHex: pubkeyHex, method: method, url: url, bodyString: bodyString)
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }

    /// Drop every cached header. Call on account switch as the belt to the
    /// per-pubkey key's suspenders.
    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Run `send` with a cached-or-fresh header. When `isUnauthorized` is
    /// true for the result AND the header came from the cache, invalidate,
    /// silently re-sign once, and retry once — a cached header can be
    /// rejected for staleness the client clock can't see. A rejection of a
    /// freshly signed header is returned as-is: re-signing cannot fix it.
    func withAuthHeader<T>(
        signer: Nip98Signing,
        method: String,
        url: String,
        bodyString: String? = nil,
        isUnauthorized: (T) -> Bool,
        send: (String) async throws -> T
    ) async throws -> T {
        let first = try await authHeader(
            signer: signer,
            method: method,
            url: url,
            bodyString: bodyString
        )
        let result = try await send(first.header)
        if !first.fromCache || !isUnauthorized(result) { return result }
        invalidate(pubkeyHex: signer.pubkeyHex, method: method, url: url, bodyString: bodyString)
        return try await send(
            try await authHeader(
                signer: signer,
                method: method,
                url: url,
                bodyString: bodyString
            ).header
        )
    }

    private func keyFor(
        pubkeyHex: String,
        method: String,
        url: String,
        bodyString: String?
    ) -> Key {
        Key(
            pubkey: pubkeyHex,
            method: method.uppercased(),
            normalizedUrl: Nip98.normalizeUrl(url),
            payloadHash: bodyString.map { Nip98.sha256Hex(Data($0.utf8)) }
        )
    }
}
