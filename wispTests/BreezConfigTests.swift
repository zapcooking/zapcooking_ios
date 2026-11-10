import Foundation
import Testing
@testable import wisp

/// `BreezConfig` mirrors facts the app can't read back from the SDK at
/// runtime: the Lightning-address domain and the pinned SDK version shown
/// in wallet settings. `sdkVersion` already drifted once (it said 0.14.0
/// while Package.resolved held 0.23.1), so these tests pin both the
/// shape of the domain and the mirror against the resolved package.
struct BreezConfigTests {

    /// The domain must be a bare hostname — the SDK sends it verbatim in
    /// LNURL paths, so a scheme, slash, or surrounding whitespace would
    /// silently break address registration and lookups.
    @Test func lnurlDomainIsBareHostname() {
        let domain = BreezConfig.lnurlDomain
        #expect(!domain.isEmpty)
        #expect(!domain.contains("://"))
        #expect(!domain.contains("/"))
        #expect(domain == domain.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(domain.contains("."))
    }

    /// `sdkVersion` is displayed in wallet settings as the pinned SDK
    /// version, so it must match what SwiftPM actually resolved. Reads the
    /// pin straight out of Package.resolved in the repo next to this test.
    @Test func sdkVersionMatchesResolvedPackage() throws {
        let resolved = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // wispTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("wisp.xcodeproj")
            .appendingPathComponent("project.xcworkspace")
            .appendingPathComponent("xcshareddata")
            .appendingPathComponent("swiftpm")
            .appendingPathComponent("Package.resolved")
        let data = try Data(contentsOf: resolved)
        let pins = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try #require(pins["pins"] as? [[String: Any]])
        let breez = try #require(list.first { ($0["identity"] as? String) == "breez-sdk-spark-swift" })
        let state = try #require(breez["state"] as? [String: Any])
        let version = try #require(state["version"] as? String)
        #expect(BreezConfig.sdkVersion == version)
    }
}
