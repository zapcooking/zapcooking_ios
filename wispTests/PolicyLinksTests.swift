import Foundation
import Testing
@testable import wisp

/// In-app policy links (Phase 4 item 4.3). The destinations must be the same
/// pages Android's `AboutScreen.PolicyLinks` opens, over https, on the
/// zap.cooking origin.
@Suite struct PolicyLinksTests {

    @Test func matchesAndroidPaths() {
        #expect(PolicyLinks.privacyPolicy.url.absoluteString == "https://zap.cooking/privacy")
        #expect(PolicyLinks.termsOfService.url.absoluteString == "https://zap.cooking/terms")
        #expect(PolicyLinks.childSafety.url.absoluteString == "https://zap.cooking/child-safety")
    }

    @Test func everyLinkIsHttpsOnTheSiteOrigin() {
        for link in PolicyLinks.all {
            #expect(link.url.scheme == "https", "\(link.label)")
            #expect(link.url.host() == "zap.cooking", "\(link.label)")
            #expect(!link.label.isEmpty)
        }
    }

    @Test func privacyAndChildSafetyAreListed() {
        #expect(PolicyLinks.all.contains(PolicyLinks.privacyPolicy))
        #expect(PolicyLinks.all.contains(PolicyLinks.childSafety))
        #expect(PolicyLinks.all.count == 3)
    }

    @Test func labelsMatchAndroidStrings() {
        #expect(PolicyLinks.all.map(\.label) == ["Privacy Policy", "Terms of Service", "Child Safety Standards"])
    }
}
