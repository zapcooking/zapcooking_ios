import Foundation
import Testing
@testable import wisp

/// Gate for Concern 0.7b — the `computeClient` tier of `HttpClientFactory`.
///
/// The client itself shipped with Phase 0 foundation (#14); what was missing
/// was any test pinning its configuration to the build-spec §2 contract
/// (~75 s for AI endpoints, where whole-response latency dominates). These
/// assert the shipped values so a future edit can't silently collapse the
/// tier back into `generalClient`'s 15 s — the exact regression Android paid
/// for on Nourish and Cheffy.
struct HttpClientFactoryTests {

    @Test func computeClientUsesDocumentedLongTimeouts() {
        let config = HttpClientFactory.computeClient.configuration
        #expect(config.timeoutIntervalForRequest == 75)
        #expect(config.timeoutIntervalForResource == 75)
    }

    @Test func computeClientTimeoutsDifferFromGeneralClient() {
        let compute = HttpClientFactory.computeClient.configuration
        let general = HttpClientFactory.generalClient.configuration
        #expect(compute.timeoutIntervalForRequest != general.timeoutIntervalForRequest)
        #expect(compute.timeoutIntervalForResource != general.timeoutIntervalForResource)
    }

    @Test func computeAndGeneralClientsShareConnectionsPerHostBudget() {
        let compute = HttpClientFactory.computeClient.configuration
        let general = HttpClientFactory.generalClient.configuration
        #expect(compute.httpMaximumConnectionsPerHost == 4)
        #expect(general.httpMaximumConnectionsPerHost == 4)
    }

    @Test func computeClientBypassesCacheAndGeneralClientDoesNot() {
        let compute = HttpClientFactory.computeClient.configuration
        let general = HttpClientFactory.generalClient.configuration
        #expect(compute.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(general.requestCachePolicy != .reloadIgnoringLocalCacheData)
    }
}
