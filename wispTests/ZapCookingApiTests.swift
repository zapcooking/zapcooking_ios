import Foundation
import Testing
@testable import wisp

/// Concern 0.7 — `ZapCookingApi` membership model mapping. Mirrors the
/// Android `mapBatchMembership` unit tests: pure decode/projection over
/// real-shape fixtures, no network.
struct ZapCookingApiTests {

    // MARK: - Batch projection (public `/api/membership`)

    @Test
    func absentBatchEntry_isInactive() {
        let status = MembershipStatus(batchEntry: nil)
        #expect(status.found == false)
        #expect(status.isActive == false)
        #expect(status.owner == false)
        #expect(status.member == nil)
    }

    @Test
    func presentBatchEntry_mapsActiveTierAndExpiry() {
        let status = MembershipStatus(
            batchEntry: PublicMembershipEntry(
                active: true, tier: "cook_plus", expiresAt: "2026-12-31"
            )
        )
        #expect(status.found == true)
        #expect(status.isActive == true)
        #expect(status.member?.tier == "cook_plus")
        #expect(status.member?.subscriptionEnd == "2026-12-31")
    }

    @Test
    func batchResponse_decodesKeyedByLowercasedPubkey() throws {
        // Real shape: object keyed by lowercased pubkey, value {active, tier, expiresAt?}.
        let json = """
        {"319ad3e7deadbeef":
            {"active": true, "tier": "cook_plus", "expiresAt": "2026-12"}}
        """.data(using: .utf8)!
        let batch = try JSONDecoder().decode([String: PublicMembershipEntry].self, from: json)
        let entry = batch["319ad3e7deadbeef"]
        #expect(entry?.active == true)
        #expect(entry?.tier == "cook_plus")
        #expect(entry?.expiresAt == "2026-12")

        // Empty batch (`{}` response or pubkey absent) → inactive status.
        let absent = MembershipStatus(batchEntry: batch["ffffffff"])
        #expect(absent.isActive == false)
    }

    // MARK: - check-status decode (lenient owner shape)

    @Test
    func checkStatus_ownerTrue_isAcceptance() throws {
        // A verified ephemeral non-member gets {"found":false,"owner":true}.
        let json = #"{"found":false,"owner":true}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(MembershipStatus.self, from: json)
        #expect(status.owner == true)
        #expect(status.found == false)
    }

    @Test
    func checkStatus_ownerMissing_isNotAccepted() throws {
        // Bad/missing/mismatched sig silently degrades to 200 with no `owner`
        // — this is the signal that drives the re-sign-and-retry in ZapCookingApi.
        let json = #"{"found":false}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(MembershipStatus.self, from: json)
        #expect(status.owner == false)
    }

    @Test
    func checkStatus_emptyObject_decodesToDefaults() throws {
        // Lenient: every field optional, unknown keys ignored.
        let json = #"{}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(MembershipStatus.self, from: json)
        #expect(status.found == false)
        #expect(status.isActive == false)
        #expect(status.owner == false)
        #expect(status.member == nil)
    }

    @Test
    func checkStatus_memberSnakeCaseKeys_decoded() throws {
        // Nested `member` uses snake_case wire keys (subscription_end, etc.).
        let json = #"{"owner":true,"isActive":true,"member":{"tier":"cook_plus","subscription_end":"2026-12-31","payment_method":"lightning"}}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(MembershipStatus.self, from: json)
        #expect(status.member?.tier == "cook_plus")
        #expect(status.member?.subscriptionEnd == "2026-12-31")
        #expect(status.member?.paymentMethod == "lightning")
    }

    // MARK: - Error dispatch (code first, status fallback)

    /// Vocabulary verified against zapcooking/frontend:
    /// `src/lib/extractErrors.ts`, `/api/zappy/ask-photo`,
    /// `/api/zappy/note-review`, `/api/zappy/meal-plan`, `/api/zappy`.

    @Test
    func throwError_2xx_doesNotThrow_evenWithErrorCodeInBody() throws {
        try ZapCookingApi.throwErrorIfNeeded(
            status: 200,
            body: Data(#"{"ok":false,"code":"NOT_MEMBER"}"#.utf8)
        )
        try ZapCookingApi.throwErrorIfNeeded(status: 204, body: Data())
    }

    @Test
    func throwError_notMemberCode_isMembersOnly_regardlessOfStatus() {
        #expect(throws: ZapCookingApiError.membersOnly) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 400,
                body: Data(#"{"ok":false,"code":"NOT_MEMBER","error":"Cheffy is available to Cook+ members."}"#.utf8)
            )
        }
    }

    @Test
    func throwError_membershipUnavailable_isApiRejected_notMembersOnly() {
        // Fail-closed outage on ask-photo / note-review. Must not look
        // like a genuine non-member even if the status is 403.
        #expect(throws: ZapCookingApiError.apiRejected(
            code: "MEMBERSHIP_UNAVAILABLE",
            message: "Cheffy can't check your membership right now. Please try again shortly."
        )) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 403,
                body: Data(#"{"ok":false,"code":"MEMBERSHIP_UNAVAILABLE","error":"Cheffy can't check your membership right now. Please try again shortly."}"#.utf8)
            )
        }
    }

    @Test
    func throwError_rateLimitedCode_winsOverStatus_andKeepsRetryAfter() {
        #expect(throws: ZapCookingApiError.rateLimited(retryAfter: 1800)) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 400,
                body: Data(#"{"ok":false,"code":"RATE_LIMITED","error":"Cheffy needs a breather.","retryAfter":1800}"#.utf8)
            )
        }
    }

    @Test
    func throwError_extractCodes_passThroughApiRejected() {
        // src/lib/extractErrors.ts — codes stay put when statuses move.
        for code in ["INVALID_REQUEST", "SOURCE_BLOCKED", "AI_UNAVAILABLE", "INTERNAL"] {
            #expect(throws: ZapCookingApiError.apiRejected(code: code, message: "x")) {
                try ZapCookingApi.throwErrorIfNeeded(
                    status: 500,
                    body: Data("{\"success\":false,\"code\":\"\(code)\",\"error\":\"x\"}".utf8)
                )
            }
        }
    }

    @Test
    func throwError_zappyVisionAndMealPlanCodes_passThroughApiRejected() {
        #expect(throws: ZapCookingApiError.apiRejected(code: "NOT_FOOD", message: "no")) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 422,
                body: Data(#"{"ok":false,"code":"NOT_FOOD","error":"no"}"#.utf8)
            )
        }
        #expect(throws: ZapCookingApiError.apiRejected(code: "IMAGE_UNREADABLE", message: "blur")) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 422,
                body: Data(#"{"ok":false,"code":"IMAGE_UNREADABLE","error":"blur"}"#.utf8)
            )
        }
        #expect(throws: ZapCookingApiError.apiRejected(code: "no-candidates", message: "none")) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 400,
                body: Data(#"{"ok":false,"code":"no-candidates","error":"none"}"#.utf8)
            )
        }
        #expect(throws: ZapCookingApiError.apiRejected(code: "CHEFFY_EXPERIENCE_USED", message: "spent")) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 429,
                body: Data(#"{"ok":false,"code":"CHEFFY_EXPERIENCE_USED","error":"spent"}"#.utf8)
            )
        }
    }

    @Test
    func throwError_bare403_isNotMembersOnly() {
        #expect(throws: ZapCookingApiError.apiRejected(
            code: nil,
            message: "Cheffy is available to Cook+ members."
        )) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 403,
                body: Data(#"{"ok":false,"error":"Cheffy is available to Cook+ members."}"#.utf8)
            )
        }
    }

    @Test
    func throwError_emptyCode_fallsBackToStatus() {
        #expect(throws: ZapCookingApiError.apiRejected(code: nil, message: "x")) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 403,
                body: Data(#"{"ok":false,"code":"","error":"x"}"#.utf8)
            )
        }
    }

    @Test
    func throwError_statusFallback_401_429_500() {
        #expect(throws: ZapCookingApiError.notSignedIn("Authentication required")) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 401,
                body: Data(#"{"error":"Authentication required"}"#.utf8)
            )
        }
        #expect(throws: ZapCookingApiError.rateLimited(retryAfter: 30)) {
            try ZapCookingApi.throwErrorIfNeeded(
                status: 429,
                body: Data(#"{"retryAfter":30}"#.utf8)
            )
        }
        #expect(throws: ZapCookingApiError.requestFailed(status: 500, body: "boom")) {
            try ZapCookingApi.throwErrorIfNeeded(status: 500, body: Data("boom".utf8))
        }
    }
}
