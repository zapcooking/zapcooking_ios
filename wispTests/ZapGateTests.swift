import Testing
@testable import wisp

/// Pins the `FeatureFlags.zapsOnPosts` kill switch (build spec §4.2 / §4.8).
/// The flip must remove every post-level zap affordance and leave
/// profile-level zaps alone; both halves are asserted here on the seam the
/// views branch on, independent of the flag's shipped value.
@Suite @MainActor struct ZapGateTests {

    @Test func postLevelFollowsTheFlag() {
        #expect(ZapGate.postZapVisible(flagEnabled: true))
        #expect(!ZapGate.postZapVisible(flagEnabled: false))
    }

    @Test func profileLevelIsIndependentOfTheFlag() {
        #expect(ZapGate.profileZapVisible(flagEnabled: true))
        #expect(ZapGate.profileZapVisible(flagEnabled: false))
    }

    @Test func defaultsReadTheShippedFlag() {
        #expect(ZapGate.postZapVisible() == FeatureFlags.zapsOnPosts)
        #expect(ZapGate.profileZapVisible())
    }

    /// The other two compliance switches are hard `false` on iOS and have no
    /// UI behind them (§4.3): no purchase, no price, no link-out. If either
    /// ever flips, the surface it would enable has to be built and gated
    /// first, so a flip without code is caught here.
    @Test func sellNothingFlagsStayOff() {
        #expect(!FeatureFlags.membershipLinkoutEnabled)
        #expect(!FeatureFlags.noteReviewCreditPurchaseEnabled)
    }
}
