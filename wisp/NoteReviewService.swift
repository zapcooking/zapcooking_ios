import Foundation

/// `POST /api/zappy/note-review` — draft a warm comment or a recipe guess
/// for a photo in a kind-1 note.
///
/// **Contract, read from the frontend handler on 2026-09-19**
/// (`zapcooking/frontend` `src/routes/api/zappy/note-review/+server.ts`,
/// last changed `eb99f009`, 2026-08-02): identity is a **required** NIP-98
/// header with body-hash binding — no body-pubkey fallback of any kind;
/// absent or invalid header → uniform 401 with no `code`. Success is
/// `{ ok: true, output, mode, creditsRemaining? }`; `creditsRemaining` only
/// appears on credit-spending requests, which iOS never makes, so it is
/// not decoded. Failures are `{ ok: false, error, code?, retryAfter? }`:
/// 400 (no code, bad body / non-image URL), 401 (no code), 403 `NOT_MEMBER`,
/// 503 `MEMBERSHIP_UNAVAILABLE` (fails CLOSED — frontend #512), 429
/// `RATE_LIMITED` (8/hour, 30/day per pubkey), 422 `IMAGE_UNREADABLE`, 422
/// `NOT_FOOD` (recipe mode only since `eb99f009`; comment mode is
/// universal), 500 (no code). Whole-response, no streaming; the vision call
/// can run several seconds, so the session is `HttpClientFactory.computeClient`.
///
/// Membership only: the credit-invoice / credit-status endpoints that
/// Android calls for non-members are deliberately not implemented here.
struct NoteReviewService {
    var client: URLSession = HttpClientFactory.computeClient

    static let path = "api/zappy/note-review"

    /// Build the request body. `noteText` is trimmed and hard-capped to
    /// `NoteReview.noteTextMaxChars` BEFORE serializing — the payload hash
    /// binds the signature to the exact bytes sent, so capping after signing
    /// would 401. Blank-after-trim context is omitted entirely; `noteId` is
    /// server-side logging only.
    nonisolated static func request(
        imageUrl: String,
        mode: NoteReview.Mode,
        noteText: String?,
        noteId: String?
    ) -> NoteReviewRequest {
        var capped: String? = nil
        if let noteText {
            let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { capped = String(trimmed.prefix(NoteReview.noteTextMaxChars)) }
        }
        return NoteReviewRequest(imageUrl: imageUrl, mode: mode, noteText: capped, noteId: noteId)
    }

    /// Sign and send one draft request. Never throws — every failure mode
    /// comes back as a `NoteReviewResult` for `NoteReview.phaseForResult`.
    func draft(_ request: NoteReviewRequest, signer: Nip98Signing) async -> NoteReviewResult {
        let body = ZapCookingApi.encodeJSON(request)
        do {
            let (response, data) = try await ZapCookingApi.authedPost(
                signer: signer,
                path: Self.path,
                body: body,
                client: client,
                isUnauthorized: { http, _ in http.statusCode == 401 }
            )
            return Self.map(status: response.statusCode, body: data)
        } catch {
            return Self.map(error: error)
        }
    }

    /// Map a response onto `NoteReviewResult`. Pure — unit-tested against
    /// the server's real shapes. The typed `code` in the body wins over the
    /// HTTP status (via `ZapCookingApi.throwErrorIfNeeded`); the status is
    /// the fallback for bodies that fail to parse.
    nonisolated static func map(status: Int, body: Data) -> NoteReviewResult {
        let envelope = try? JSONDecoder().decode(NoteReviewResponse.self, from: body)
        if (200..<300).contains(status) {
            if let envelope, envelope.ok {
                let output = envelope.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !output.isEmpty { return .success(output: output) }
                return .error(message: "Cheffy went quiet for a second. Please try again.")
            }
            // Defensive: a 2xx `{ ok: false }` — the server uses non-2xx today.
            if let code = envelope?.code, let typed = result(forCode: code, message: envelope?.error, retryAfter: envelope?.retryAfter) {
                return typed
            }
            return .error(message: envelope?.error ?? NoteReview.genericErrorLine)
        }
        do {
            try ZapCookingApi.throwErrorIfNeeded(status: status, body: body)
        } catch {
            return map(error: error)
        }
        return .error(message: NoteReview.genericErrorLine)
    }

    /// Map a thrown transport / taxonomy error. `membersOnly` is the ONLY
    /// path into the members gate; every other rejection — including
    /// `MEMBERSHIP_UNAVAILABLE` and a bare 403 with no code — is a
    /// retryable error, never a membership denial.
    nonisolated static func map(error: Error) -> NoteReviewResult {
        guard let api = error as? ZapCookingApiError else {
            return .error(message: NoteReview.genericErrorLine)
        }
        switch api {
        case .membersOnly:
            return .notMember
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .apiRejected(let code, let message):
            if let code, let typed = result(forCode: code, message: message, retryAfter: nil) {
                return typed
            }
            return .error(message: message ?? NoteReview.genericErrorLine)
        case .notSignedIn:
            // The signer could not produce a header (watch-only) or the
            // server rejected it even after a fresh sign — "your signer".
            return .signFailed
        case .requestFailed(let status, let body):
            // Status fallback for bodies without a `code` (Android parity).
            let envelope = body.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(NoteReviewResponse.self, from: $0) }
            switch status {
            case 503: return .membershipUnavailable
            case 422: return .deadEnd
            default: return .error(message: envelope?.error ?? NoteReview.genericErrorLine)
            }
        case .transport(let message):
            if message == ZapCookingApi.timedOutTransportMessage {
                return .error(message: Cheffy.timedOutMessage)
            }
            return .error(message: Cheffy.networkErrorMessage)
        case .encoding, .decoding, .badRequest:
            return .error(message: NoteReview.genericErrorLine)
        }
    }

    /// The server's typed vocabulary → result. Unknown codes return nil so
    /// the caller falls back to the message.
    nonisolated private static func result(
        forCode code: String,
        message: String?,
        retryAfter: TimeInterval?
    ) -> NoteReviewResult? {
        switch code {
        case "NOT_MEMBER": return .notMember
        case "MEMBERSHIP_UNAVAILABLE": return .membershipUnavailable
        case "RATE_LIMITED": return .rateLimited(retryAfter: retryAfter)
        case "NOT_FOOD", "IMAGE_UNREADABLE": return .deadEnd
        default: return nil
        }
    }
}

/// `POST /api/zappy/note-review` body. **No identity field** — the NIP-98
/// header carries it. Optionals are omitted from the wire body when nil,
/// exactly like the web client's `noteText?` / `noteId?`.
nonisolated struct NoteReviewRequest: Encodable, Equatable, Sendable {
    let imageUrl: String
    let mode: NoteReview.Mode
    let noteText: String?
    let noteId: String?
}

/// `{ ok, output?, error?, code?, retryAfter? }` — lenient: every field
/// defaulted so a partial body never throws. `creditsRemaining` is not
/// decoded (iOS never spends a credit).
nonisolated struct NoteReviewResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var output: String?
    var error: String?
    var code: String?
    var retryAfter: TimeInterval?

    init(ok: Bool = false, output: String? = nil, error: String? = nil, code: String? = nil, retryAfter: TimeInterval? = nil) {
        self.ok = ok
        self.output = output
        self.error = error
        self.code = code
        self.retryAfter = retryAfter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ok: try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false,
            output: try c.decodeIfPresent(String.self, forKey: .output),
            error: try c.decodeIfPresent(String.self, forKey: .error),
            code: try c.decodeIfPresent(String.self, forKey: .code),
            retryAfter: try c.decodeIfPresent(TimeInterval.self, forKey: .retryAfter)
        )
    }

    enum CodingKeys: String, CodingKey { case ok, output, error, code, retryAfter }
}
