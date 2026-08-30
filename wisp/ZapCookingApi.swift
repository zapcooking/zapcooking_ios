import Foundation

/// HTTPS client for the zap.cooking backend (build spec §2, Concern 0.7).
///
/// **Backend-as-API rule** (build spec §premise): AI and membership live
/// server-side on `zap.cooking`. The app NEVER holds OpenAI/Stripe/Strike
/// keys — it calls HTTPS endpoints and does not reimplement them in Swift.
///
/// **Two URLSession tiers** (via `HttpClientFactory`):
/// - `generalClient` (15 s) — membership, invoice mint, credit-status.
/// - `computeClient` (~75 s) — LLM/vision endpoints (Cheffy, Nourish,
///   extract-recipe, Note Review), where whole-response latency dominates.
///   Android learned the hard way that the general 15 s client times out on
///   Nourish (LLM + awaited pantry publish) and Cheffy (whole-response, no
///   streaming); this tier is built up front (build spec §2).
///
/// **Auth model** (verified against `ZapCookingApi.kt`):
/// - NIP-98 (kind 27235) for `/api/membership/check-status`,
///   `/api/extract-recipe`, and the Note Review endpoints.
/// - pubkey-in-body for `/api/zappy`, `/api/nourish` (Phase 2 AI endpoints —
///   identity in the body, a one-call swap when the server finishes its
///   NIP-98 migration).
/// - none for `/api/membership` (public batch) and `/api/extract-recipe/public`.
///
/// Request models are kept auth-agnostic so the pubkey-in-body endpoints can
/// adopt NIP-98 with a single-call change, not a rewrite.
nonisolated enum ZapCookingApi {
    static let baseURL = URL(string: "https://zap.cooking")!

    // MARK: - Membership

    /// `GET /api/membership?pubkeys=<hex>` — public, unauthenticated **batch**
    /// read of membership status. The server takes a comma-separated `pubkeys`
    /// query param (NOT a singular `pubkey`) and answers an object keyed by the
    /// **lowercased** pubkey, each value `{ active, tier, expiresAt? }`. A
    /// missing key maps to an inactive status. Use for badge surfaces and for
    /// read-only accounts (which cannot sign).
    static func getPublicMembership(pubkeyHex: String) async throws -> MembershipStatus {
        let lookupKey = pubkeyHex.lowercased()
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/membership"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ZapCookingApiError.badRequest("invalid membership URL")
        }
        components.queryItems = [URLQueryItem(name: "pubkeys", value: lookupKey)]
        guard let url = components.url else {
            throw ZapCookingApiError.badRequest("invalid membership URL")
        }
        let (status, data) = try await get(url: url, client: HttpClientFactory.generalClient)
        try throwErrorIfNeeded(status: status.statusCode, body: data)
        let batch = try decode(data, as: [String: PublicMembershipEntry].self)
        return MembershipStatus(batchEntry: batch[lookupKey])
    }

    /// `POST /api/membership/check-status` — NIP-98 verified owner lookup.
    /// The backend returns the full owner record only when the signature is
    /// valid AND the signing pubkey equals the queried pubkey. An
    /// absent/invalid/mismatched signature silently degrades to the public
    /// shape (it does NOT error), so the proof the server accepted our NIP-98
    /// is `MembershipStatus.owner`. **Acceptance signal is `owner == true`,
    /// not bare HTTP 200** (build spec §0) — a 200 with no `owner` field means
    /// the byte contract is wrong, not that verification succeeded.
    static func checkMembershipStatus(signer: Nip98Signing) async throws -> MembershipStatus {
        let body = encodeJSON(CheckStatusRequest(pubkey: signer.pubkeyHex))
        let (status, data) = try await authedPost(
            signer: signer,
            path: "api/membership/check-status",
            body: body,
            client: HttpClientFactory.generalClient,
            isUnauthorized: { response, bodyData in
                // Bad/missing/mismatched sig degrades to 200 with owner != true
                // (never a 401). A true 401 is the other unauthorized signal.
                if response.statusCode == 401 { return true }
                if response.statusCode == 200 {
                    return (try? JSONDecoder().decode(MembershipStatus.self, from: bodyData))?.owner != true
                }
                return false
            }
        )
        try throwErrorIfNeeded(status: status.statusCode, body: data)
        return try decode(data, as: MembershipStatus.self)
    }

    // MARK: - Request spine (shared by membership + the Phase 2 AI endpoints)

    /// NIP-98-authenticated POST. Signs `body` via `signer` (the exact bytes
    /// hashed into the `payload` tag are the bytes sent — single source of
    /// truth), then runs the shared send/error path. One silent
    /// re-sign-and-retry when a *cached* header is rejected (stale beyond the
    /// client clock's view) — `isUnauthorized` inspects the raw response so
    /// both a real 401 and the check-status 200-degrade trigger the retry on
    /// the same terms. A rejection of a freshly signed header is returned
    /// as-is: re-signing cannot fix it.
    private static func authedPost(
        signer: Nip98Signing,
        path: String,
        body: String,
        client: URLSession,
        isUnauthorized: (HTTPURLResponse, Data) -> Bool
    ) async throws -> (HTTPURLResponse, Data) {
        let url = baseURL.appendingPathComponent(path)
        do {
            let cached = try await Nip98HeaderCache.shared.authHeader(
                signer: signer, method: "POST",
                url: url.absoluteString, bodyString: body
            )
            let first = try await rawPost(
                url: url, body: body, authorization: cached.header, client: client
            )
            if cached.fromCache && isUnauthorized(first.0, first.1) {
                Nip98HeaderCache.shared.invalidate(
                    pubkeyHex: signer.pubkeyHex, method: "POST",
                    url: url.absoluteString, bodyString: body
                )
                let fresh = try await Nip98HeaderCache.shared.authHeader(
                    signer: signer, method: "POST",
                    url: url.absoluteString, bodyString: body
                )
                return try await rawPost(
                    url: url, body: body, authorization: fresh.header, client: client
                )
            }
            return first
        } catch let error as Nip98.Error {
            // Watch-only / empty-privkey account cannot produce a header.
            throw ZapCookingApiError.notSignedIn(error.description)
        }
    }

    /// Unauthenticated GET sharing the send path.
    private static func get(url: URL, client: URLSession) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await send(request, client: client)
    }

    /// Unauthenticated JSON POST sharing the send path. The Phase 2 AI
    /// endpoints gate on a body pubkey (not NIP-98), so they use this rather
    /// than `authedPost`.
    static func post(
        path: String,
        body: String,
        client: URLSession = HttpClientFactory.generalClient
    ) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await send(request, client: client)
    }

    private static func rawPost(
        url: URL, body: String, authorization: String?, client: URLSession
    ) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data(body.utf8)
        return try await send(request, client: client)
    }

    private static func send(
        _ request: URLRequest, client: URLSession
    ) async throws -> (HTTPURLResponse, Data) {
        do {
            let (data, response) = try await client.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ZapCookingApiError.transport(URLError(.badServerResponse).localizedDescription)
            }
            return (http, data)
        } catch let error as ZapCookingApiError {
            throw error
        } catch {
            throw ZapCookingApiError.transport(error.localizedDescription)
        }
    }

    // MARK: - Error mapping

    /// Non-2xx → typed error. Dispatches on the body's additive `code`
    /// first (the stable vocabulary from zapcooking/frontend), then
    /// falls back to HTTP status for responses that don't carry one.
    ///
    /// Status-only branching is the fragility the extract-recipe
    /// re-taxonomy (400 → 400/422/503/500) is queued behind: Android
    /// still body-parses only in its 400 branch. Codes stay put when
    /// statuses move.
    ///
    /// Known codes that already have dedicated cases:
    ///   `NOT_MEMBER` → `membersOnly`
    ///   `RATE_LIMITED` → `rateLimited`
    /// Everything else with a `code` — including
    /// `MEMBERSHIP_UNAVAILABLE` — uses `apiRejected`, the same case as
    /// 200-with-`{ok:false}`. A bare 403 (no code) is also
    /// `apiRejected`, not `membersOnly`: a pantry outage must not
    /// render as a definitive membership denial.
    ///
    /// Callers that need a 200-with-`{ok:false}` rejection still decode
    /// the body themselves — membership endpoints never use that shape.
    static func throwErrorIfNeeded(status: Int, body: Data) throws {
        guard !(200..<300).contains(status) else { return }

        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        if let code = envelope?.code?.trimmingCharacters(in: .whitespacesAndNewlines),
           !code.isEmpty {
            throw error(forCode: code, message: envelope?.error, retryAfter: envelope?.retryAfter)
        }

        switch status {
        case 401:
            throw ZapCookingApiError.notSignedIn(envelope?.error)
        case 403:
            throw ZapCookingApiError.apiRejected(code: nil, message: envelope?.error)
        case 429:
            throw ZapCookingApiError.rateLimited(retryAfter: envelope?.retryAfter)
        default:
            throw ZapCookingApiError.requestFailed(
                status: status, body: String(data: body, encoding: .utf8)
            )
        }
    }

    /// Map a server `code` onto the existing error cases. Unknown codes
    /// pass through `apiRejected` rather than a second taxonomy.
    private static func error(
        forCode code: String,
        message: String?,
        retryAfter: TimeInterval?
    ) -> ZapCookingApiError {
        switch code {
        case "NOT_MEMBER":
            return .membersOnly
        case "RATE_LIMITED":
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .apiRejected(code: code, message: message)
        }
    }

    // MARK: - JSON helpers

    static func encodeJSON(_ value: some Encodable) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            // All request models here are trivial Codable structs; an encode
            // failure is a programmer error, not a runtime condition.
            return "{}"
        }
        return string
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ZapCookingApiError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Errors

/// Failures from the zap.cooking backend, mapped at the HTTP boundary. All
/// associated values are `Sendable` so the enum crosses actor boundaries
/// cleanly under Swift 6 concurrency.
enum ZapCookingApiError: Error, Sendable, Equatable {
    /// 401, or NIP-98 signing key missing (watch-only account).
    case notSignedIn(String?)
    /// Genuine non-member (`code: NOT_MEMBER`). Not every 403 — a pantry
    /// outage is `MEMBERSHIP_UNAVAILABLE` (or a bare 403 with no code),
    /// both of which surface as `apiRejected` so callers can render
    /// "temporarily unavailable" rather than a definitive denial.
    case membersOnly
    /// 429 / `code: RATE_LIMITED`.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx HTTP status with no `code`.
    case requestFailed(status: Int, body: String?)
    /// Server rejected the request with a typed `code` (or a bare 403 with no code).
    /// Used for non-2xx bodies that carry `code` and for callers that choose to
    /// surface 200-with-`{ok:false}` responses as an error.
    case apiRejected(code: String?, message: String?)
    case encoding(String)
    case decoding(String)
    case transport(String)
    case badRequest(String)
}

/// Additive error envelope used by zap.cooking (`{ error, code?, retryAfter? }`).
/// Shared by `{ok:false}` AI bodies and `{success:false}` extract-recipe
/// bodies. Extra keys (`ok`, `success`, …) are ignored.
private struct ErrorEnvelope: Decodable {
    var code: String?
    var error: String?
    var retryAfter: TimeInterval?
}

// MARK: - Response models

/// Membership status, shared by the public batch read and the NIP-98 owner
/// check (mirrors Android `MembershipStatus`). Lenient by design — the public
/// and owner shapes differ and unknown keys are ignored. `owner` is `true`
/// only when the server verified a NIP-98 signature from the queried pubkey
/// itself.
struct MembershipStatus: Decodable, Sendable, Equatable {
    var found: Bool
    var isActive: Bool
    var isExpired: Bool?
    var owner: Bool
    var member: Member?
    var error: String?

    init(
        found: Bool = false,
        isActive: Bool = false,
        isExpired: Bool? = nil,
        owner: Bool = false,
        member: Member? = nil,
        error: String? = nil
    ) {
        self.found = found
        self.isActive = isActive
        self.isExpired = isExpired
        self.owner = owner
        self.member = member
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            found: try c.decodeIfPresent(Bool.self, forKey: .found) ?? false,
            isActive: try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false,
            isExpired: try c.decodeIfPresent(Bool.self, forKey: .isExpired),
            owner: try c.decodeIfPresent(Bool.self, forKey: .owner) ?? false,
            member: try c.decodeIfPresent(Member.self, forKey: .member),
            error: try c.decodeIfPresent(String.self, forKey: .error)
        )
    }

    /// Absent batch entry → inactive status (mirrors Android
    /// `mapBatchMembership`). A present entry maps `active` → `isActive`,
    /// `tier` → `member.tier`, `expiresAt` → `member.subscriptionEnd`.
    init(batchEntry: PublicMembershipEntry?) {
        self.init()
        guard let entry = batchEntry else { return }
        found = true
        isActive = entry.active
        member = Member(tier: entry.tier, subscriptionEnd: entry.expiresAt)
    }

    enum CodingKeys: String, CodingKey {
        case found, isActive, isExpired, owner, member, error
    }

    struct Member: Decodable, Sendable, Equatable {
        var pubkey: String?
        var tier: String?
        var status: String?
        var subscriptionEnd: String?
        var subscriptionStart: String?
        var paymentMethod: String?

        init(
            pubkey: String? = nil,
            tier: String? = nil,
            status: String? = nil,
            subscriptionEnd: String? = nil,
            subscriptionStart: String? = nil,
            paymentMethod: String? = nil
        ) {
            self.pubkey = pubkey
            self.tier = tier
            self.status = status
            self.subscriptionEnd = subscriptionEnd
            self.subscriptionStart = subscriptionStart
            self.paymentMethod = paymentMethod
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                pubkey: try c.decodeIfPresent(String.self, forKey: .pubkey),
                tier: try c.decodeIfPresent(String.self, forKey: .tier),
                status: try c.decodeIfPresent(String.self, forKey: .status),
                subscriptionEnd: try c.decodeIfPresent(String.self, forKey: .subscriptionEnd),
                subscriptionStart: try c.decodeIfPresent(String.self, forKey: .subscriptionStart),
                paymentMethod: try c.decodeIfPresent(String.self, forKey: .paymentMethod)
            )
        }

        enum CodingKeys: String, CodingKey {
            case pubkey, tier, status
            case subscriptionEnd = "subscription_end"
            case subscriptionStart = "subscription_start"
            case paymentMethod = "payment_method"
        }
    }
}

/// One entry in the `/api/membership` batch response
/// (`{ active, tier, expiresAt? }`). Distinct from `MembershipStatus` because
/// the batch endpoint uses `active`/top-level `tier`, whereas `check-status`
/// uses `isActive`/nested `member.tier`. Lenient defaults so a partial entry
/// never throws.
struct PublicMembershipEntry: Decodable, Sendable, Equatable {
    var active: Bool
    var tier: String?
    var expiresAt: String?

    init(active: Bool = false, tier: String? = nil, expiresAt: String? = nil) {
        self.active = active
        self.tier = tier
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
    }

    enum CodingKeys: String, CodingKey { case active, tier, expiresAt }
}

// MARK: - Request models

/// `POST /api/membership/check-status` body. Auth-agnostic shape: the pubkey
/// is echoed in the body today and verified via the NIP-98 header; if the
/// server drops the body requirement after its NIP-98 migration, this struct
/// is the only call site that changes.
private struct CheckStatusRequest: Encodable {
    let pubkey: String
}
