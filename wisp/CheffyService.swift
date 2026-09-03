import Foundation

/// Cheffy chat — `POST /api/zappy` (Concern C-E).
///
/// **Contract, verified against the web handler and production on
/// 2026-09-01** (`zapcooking/frontend` `src/routes/api/zappy/+server.ts`,
/// NIP-98 since `04cf67cd`, 2026-08-17): identity is a **NIP-98 header**
/// with body-hash binding; a body `pubkey` is ignored. The header is
/// optional server-side (absent = anonymous → 403 non-member), so the
/// request model carries no identity at all and the signer is a call-site
/// argument — auth-agnostic by construction, the one-call swap the build
/// spec asks for already made. Present-but-invalid → 401.
///
/// Whole-response, no streaming: the server awaits one OpenAI completion
/// (`max_tokens` 2048) and answers `{ ok: true, output }`. Real answers
/// take 5–30 s, so the session is pinned to `HttpClientFactory.computeClient`
/// (75 s) and `CheffyTests.serviceUsesComputeClient` asserts the identity.
///
/// Failures are `{ ok: false, error, code? }` on a non-2xx status. The only
/// `code` this endpoint emits is `CHEFFY_EXPERIENCE_USED` (web-only preview
/// path, 429). The members-only 403 carries **no `code`**, so it reaches
/// callers as `.apiRejected(code: nil, message:)` — never `.membersOnly` —
/// because a pantry outage renders as the same 403 and must not read as a
/// definitive denial (build spec 0.7a). Verified 2026-09-02 against
/// `origin/main` (handler unchanged since `04cf67cd`): the handler's
/// "fail open on outage" branch is unreachable because
/// `hasActiveMembership` catches every error and returns `false`.
struct CheffyService {
    var client: URLSession = HttpClientFactory.computeClient

    /// Send one turn. `history` is the live thread the client re-sends every
    /// request (the server is stateless; it keeps the last 12 turns).
    func send(_ request: CheffyRequest, signer: Nip98Signing) async throws -> String {
        let body = ZapCookingApi.encodeJSON(request)
        let (response, data) = try await ZapCookingApi.authedPost(
            signer: signer,
            path: "api/zappy",
            body: body,
            client: client,
            isUnauthorized: { http, _ in http.statusCode == 401 }
        )
        try ZapCookingApi.throwErrorIfNeeded(status: response.statusCode, body: data)
        let decoded = try ZapCookingApi.decode(data, as: CheffyResponse.self)
        guard decoded.ok, let output = decoded.output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            // Defensive — the server uses non-2xx for failures today.
            throw ZapCookingApiError.apiRejected(code: decoded.code, message: decoded.error)
        }
        return output
    }
}

/// Cheffy chat mode. `chat` = conversation; `hungry` = "Surprise me" (the
/// server supplies its own prompt, `prompt` is sent empty). `format` and
/// the web-only `experience` flag are deliberately absent.
nonisolated enum CheffyMode: String, Encodable, Sendable {
    case chat
    case hungry
}

/// One prior turn in the stateless history the client re-sends each request.
nonisolated struct CheffyMessage: Encodable, Equatable, Sendable {
    let role: String // "user" | "assistant"
    let content: String
}

/// `POST /api/zappy` body. **No identity field** — see `CheffyService`.
nonisolated struct CheffyRequest: Encodable, Equatable, Sendable {
    let prompt: String
    let mode: CheffyMode
    let messages: [CheffyMessage]
}

/// `POST /api/zappy` response envelope. Lenient — every field defaulted so
/// a partial body never throws.
nonisolated struct CheffyResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var output: String?
    var error: String?
    var code: String?

    init(ok: Bool = false, output: String? = nil, error: String? = nil, code: String? = nil) {
        self.ok = ok
        self.output = output
        self.error = error
        self.code = code
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ok: try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false,
            output: try c.decodeIfPresent(String.self, forKey: .output),
            error: try c.decodeIfPresent(String.self, forKey: .error),
            code: try c.decodeIfPresent(String.self, forKey: .code)
        )
    }

    enum CodingKeys: String, CodingKey { case ok, output, error, code }
}
