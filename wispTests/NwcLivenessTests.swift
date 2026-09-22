import Testing
@testable import wisp

/// The liveness classifier decides what a failed NWC probe means: a decoded
/// response of any kind (even an error code or a malformed one) proves a
/// live wallet service answered, an authorization refusal means the
/// connection was revoked or restricted, and silence — timeout, no relay,
/// no session — means unresponsive. `WalletStore` turns these into the
/// few-second alert copy; getting them backwards either scares users off a
/// working wallet or leaves them staring at a revoked one.
@MainActor
struct NwcLivenessTests {

    // MARK: - A response means alive

    @Test func aResponse_alwaysMeansAlive() {
        #expect(NwcWallet.classifyLiveness(nil) == .alive)
    }

    // MARK: - Authorization refusals mean revoked

    @Test func authorizationRefusals_meanRefused() {
        #expect(NwcWallet.classifyLiveness(.rpcError(code: "UNAUTHORIZED", message: "")) == .refused)
        #expect(NwcWallet.classifyLiveness(.rpcError(code: "RESTRICTED", message: "permission denied")) == .refused)
        #expect(NwcWallet.classifyLiveness(.rpcError(code: "INTERNAL", message: "connection was revoked by the user")) == .refused)
        #expect(NwcWallet.classifyLiveness(.rpcError(code: "OTHER", message: "Unauthorized client")) == .refused)
    }

    // MARK: - Odd answers still prove a live wallet

    @Test func answeredButRefusedMethods_meanAlive() {
        // A wallet that says "not supported" is alive — it spoke.
        #expect(NwcWallet.classifyLiveness(.rpcError(code: "NOT_SUPPORTED", message: "get_info")) == .alive)
        // A malformed payload came from somewhere — a live service sent it.
        #expect(NwcWallet.classifyLiveness(.decodeFailed("weird payload")) == .alive)
    }

    // MARK: - Silence means unresponsive

    @Test func silence_meansUnresponsive() {
        #expect(NwcWallet.classifyLiveness(.timeout) == .unresponsive)
        #expect(NwcWallet.classifyLiveness(.notConnected) == .unresponsive)
        #expect(NwcWallet.classifyLiveness(.other("No relay accepted the request")) == .unresponsive)
    }
}
