import Foundation

/// `POST /api/zappy/ask-photo` with `purpose: "alt"` — generate a draft
/// accessibility description for a composer attachment (Cook+ members).
///
/// **Contract, read from the frontend handler on 2026-09-20**
/// (`zapcooking/frontend` `src/routes/api/zappy/ask-photo/+server.ts` and the
/// handoff doc `docs/accessibility/alt-text-imeta-handoff.md` §4): identity is
/// a required NIP-98 header with body-hash binding (the note-review pattern).
/// Body is `{ image: <base64, no data: prefix>, purpose: "alt" }` — the
/// member's question field is omitted entirely in this mode, which selects a
/// neutral describer instruction with no food-only gate (alt must describe
/// screenshots, people, places — anything). Success is
/// `{ ok: true, output }`; failures are `{ ok: false, error, code? }`:
/// 403 `NOT_MEMBER`, 503 `MEMBERSHIP_UNAVAILABLE` (fails CLOSED), 429
/// `RATE_LIMITED` (8/hour + 30/day per pubkey), 422 `IMAGE_UNREADABLE`.
/// Whole-response, no streaming; the vision call runs seconds, so the session
/// is `HttpClientFactory.computeClient`.
///
/// The server caps base64 at 14 M chars — sized for a 10 MiB file (base64 is
/// 4/3 of the input) — so this client downscales oversized images through
/// `MediaCompressor` before sending and refuses anything still over the cap.
struct AltTextService {
    var client: URLSession = HttpClientFactory.computeClient

    static let path = "api/zappy/ask-photo"
    /// File-size ceiling that survives the server's 14 M-char base64 cap.
    static let maxImageBytes = 10 * 1024 * 1024

    enum Result: Equatable {
        /// A draft description. Always lands in the editor's text field for
        /// the member to review and edit — never published sight-unseen.
        case success(String)
        /// 403 `NOT_MEMBER` — message-only, no upsell (build spec §4.3).
        case notMember
        case rateLimited(retryAfter: TimeInterval?)
        /// 422 `IMAGE_UNREADABLE`, or bytes we couldn't fetch/decode locally.
        case imageUnreadable
        /// Image survived compression still over the wire cap.
        case tooLarge
        /// The signer couldn't produce a NIP-98 header (watch-only account).
        case notSignedIn
        case error(String)
    }

    /// Compress-if-needed, base64, sign, send. Never throws.
    func generateAlt(imageData: Data, signer: Nip98Signing) async -> Result {
        let prepared = Self.prepare(imageData: imageData)
        switch prepared {
        case .failure(let result):
            return result
        case .success(let bytes):
            let body = ZapCookingApi.encodeJSON(
                AltTextRequest(image: bytes.base64EncodedString(), purpose: "alt")
            )
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
    }

    /// Downscale anything big through the upload pipeline's compressor, then
    /// enforce the wire cap. Small files pass through untouched.
    nonisolated static func prepare(imageData: Data) -> ResultEnvelope {
        guard !imageData.isEmpty else { return .failure(.imageUnreadable) }
        var bytes = imageData
        if bytes.count > MediaCompressor.skipBelowBytes {
            // Round-trip through the same compressor the upload path uses;
            // animated payloads bypass it inside (re-encoding would strip
            // frames), which the cap check below still covers.
            bytes = MediaCompressor.compressImage(data: bytes, mime: "image/jpeg").data
        }
        guard bytes.count <= maxImageBytes else { return .failure(.tooLarge) }
        return .success(bytes)
    }

    enum ResultEnvelope: Equatable {
        case success(Data)
        case failure(Result)
    }

    /// Map a response onto `Result`. Pure — unit-testable against the
    /// server's real shapes. Same skeleton as `NoteReviewService.map`.
    nonisolated static func map(status: Int, body: Data) -> Result {
        let envelope = try? JSONDecoder().decode(AltTextResponse.self, from: body)
        if (200..<300).contains(status) {
            if let envelope, envelope.ok == true {
                let output = envelope.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !output.isEmpty { return .success(output) }
                return .error("Cheffy went quiet for a second. Please try again.")
            }
            // Defensive: a 2xx `{ ok: false }` — the server uses non-2xx today.
            if let code = envelope?.code, let typed = typedError(code: code, retryAfter: envelope?.retryAfter) {
                return typed
            }
            return .error(envelope?.error ?? "Couldn't generate a description.")
        }
        do {
            try ZapCookingApi.throwErrorIfNeeded(status: status, body: body)
        } catch {
            return map(error: error)
        }
        return .error("Couldn't generate a description.")
    }

    /// `membersOnly` is the ONLY path into the Cook+ notice; every other
    /// rejection — including `MEMBERSHIP_UNAVAILABLE` and a bare 403 with no
    /// code — is a retryable error, never a membership denial.
    nonisolated static func map(error: Error) -> Result {
        guard let api = error as? ZapCookingApiError else {
            return .error("Couldn't reach Cheffy. Check your connection and try again.")
        }
        switch api {
        case .membersOnly:
            return .notMember
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .notSignedIn:
            return .notSignedIn
        case .apiRejected(let code, let message):
            if let code, let typed = typedError(code: code, retryAfter: nil) {
                return typed
            }
            return .error(message ?? "Couldn't generate a description.")
        default:
            return .error("Couldn't reach Cheffy. Check your connection and try again.")
        }
    }

    private static func typedError(code: String, retryAfter: TimeInterval?) -> Result? {
        switch code {
        case "RATE_LIMITED": return .rateLimited(retryAfter: retryAfter)
        case "IMAGE_UNREADABLE": return .imageUnreadable
        default: return nil
        }
    }
}

/// `{ image, purpose }` — `purpose` is always `"alt"` here; the question
/// field the endpoint also accepts is deliberately omitted in this mode.
private struct AltTextRequest: Encodable {
    let image: String
    let purpose: String
}

/// `{ ok, output, error?, code?, retryAfter? }` — additive envelope, unknown
/// keys ignored.
private struct AltTextResponse: Decodable {
    var ok: Bool?
    var output: String?
    var error: String?
    var code: String?
    var retryAfter: TimeInterval?
}
