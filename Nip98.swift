import CryptoKit
import Foundation

/// NIP-98 HTTP Auth (kind 27235).
///
/// Signs a short-lived event bound to a specific URL, method, and
/// (optionally) request-body hash, then encodes it for the
/// `Authorization: Nostr <base64(event)>` header.
///
/// Byte-for-byte aligned with the zap.cooking frontend reference so the
/// server verifier accepts our headers:
///   - client: frontend `src/lib/nip98.ts` (`signNip98AuthHeader`)
///   - verifier: frontend `src/lib/nip98.server.ts` (`verifyNip98`)
///
/// Footguns the verifier is strict about:
///   - **URL**: the `u` tag is `origin + pathname` ONLY — query string and
///     fragment are dropped, and a trailing slash is stripped on non-root paths.
///   - **method**: upper-cased.
///   - **payload**: lowercase-hex SHA-256 of the exact body bytes sent.
///
/// This fork is local-key only (no NIP-46 / remote signer). Watch-only
/// accounts cannot produce a header — callers must gate signing-dependent
/// features on the presence of a signing keypair.
nonisolated enum Nip98 {
    static let kind = 27235

    enum Error: Swift.Error, CustomStringConvertible {
        case signingKeyMissing

        var description: String {
            switch self {
            case .signingKeyMissing:
                return "NIP-98 signing requires a local private key (watch-only?)"
            }
        }
    }

    /// Canonicalize a URL for the `u` tag. Must match `normalizeUrl` in
    /// nip98.ts: `origin + pathname`, query/fragment dropped, trailing
    /// slash stripped on non-root paths.
    ///
    /// Note: Foundation `URL.path` / `URLComponents.percentEncodedPath` is
    /// `""` for a URL with no path (e.g. `https://zap.cooking`), whereas
    /// JS `URL.pathname` is `"/"`. Empty is coerced to `"/"` so both sides agree.
    static func normalizeUrl(_ url: String) -> String {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              let host = components.host else {
            return url
        }
        let portPart: String
        if let port = components.port {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }
        var pathname = components.percentEncodedPath
        if pathname.isEmpty { pathname = "/" }
        if pathname.count > 1 && pathname.hasSuffix("/") {
            pathname = String(pathname.dropLast())
        }
        return "\(scheme)://\(host)\(portPart)\(pathname)"
    }

    /// Lowercase-hex SHA-256 of raw bytes — NIP-98 `payload` tag format.
    static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Build the NIP-98 tags for a request. When `bodyString` is non-nil,
    /// a `payload` tag binds the signature to those exact bytes.
    static func buildTags(method: String, url: String, bodyString: String?) -> [[String]] {
        var tags: [[String]] = [
            ["u", normalizeUrl(url)],
            ["method", method.uppercased()],
        ]
        if let bodyString {
            tags.append(["payload", sha256Hex(Data(bodyString.utf8))])
        }
        return tags
    }

    /// Encode an already-signed kind-27235 event into the header value.
    /// Canonical JSON key order is `id,pubkey,created_at,kind,tags,content,sig`
    /// with `created_at` as a number — matches `NostrEvent.toJSON()`.
    static func encodeAuthHeader(_ event: NostrEvent) -> String {
        let canonical = event.toJSON()
        let b64 = Data(canonical.utf8).base64EncodedString()
        return "Nostr \(b64)"
    }

    /// Sign and encode a NIP-98 `Authorization` header for a single request.
    /// Returns the full header value (with the `Nostr ` prefix).
    ///
    /// Throws `Error.signingKeyMissing` for watch-only / empty-privkey accounts
    /// so callers can fail cleanly without a fatal abort.
    static func authHeader(
        keypair: Keypair,
        method: String,
        url: String,
        bodyString: String? = nil
    ) async throws -> String {
        try await authHeader(
            signer: LocalNip98Signer(keypair: keypair),
            method: method,
            url: url,
            bodyString: bodyString
        )
    }

    /// Sign and encode via any `Nip98Signing` (production local key or test fake).
    static func authHeader(
        signer: Nip98Signing,
        method: String,
        url: String,
        bodyString: String? = nil
    ) async throws -> String {
        let tags = buildTags(method: method, url: url, bodyString: bodyString)
        let event = try await signer.signEvent(kind: kind, content: "", tags: tags)
        return encodeAuthHeader(event)
    }
}

/// Minimal signing surface for NIP-98. Local-key only in production;
/// tests inject a fake that stamps a dummy signature.
protocol Nip98Signing: Sendable {
    var pubkeyHex: String { get }
    func signEvent(kind: Int, content: String, tags: [[String]]) async throws -> NostrEvent
}

/// Production signer: wraps a `Keypair` and refuses watch-only / empty keys.
/// Watch-only accounts store an empty privkey sentinel — that is the gate.
nonisolated struct LocalNip98Signer: Nip98Signing {
    let keypair: Keypair

    var pubkeyHex: String { keypair.pubkey }

    func signEvent(kind: Int, content: String, tags: [[String]]) async throws -> NostrEvent {
        guard !keypair.privkey.isEmpty,
              Hex.decode(keypair.privkey)?.count == 32 else {
            throw Nip98.Error.signingKeyMissing
        }
        return try await Signer.sign(
            keypair: keypair,
            kind: kind,
            tags: tags,
            content: content
        )
    }
}
