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
}
