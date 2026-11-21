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

    /// A zap without a recipient lightning address always fails at send time
    /// (`ZapSender.Failure.noLightningAddress`), so the flag alone isn't
    /// enough — the affordance is only offered when the recipient has a
    /// `lud16` (`ProfileData` is iOS's only address source).
    @Test func postLevelRequiresRecipientAddress() {
        #expect(ZapGate.postZapVisible(recipientLud16: "pleb@zap.cooking", flagEnabled: true))
        #expect(!ZapGate.postZapVisible(recipientLud16: nil, flagEnabled: true))
        #expect(!ZapGate.postZapVisible(recipientLud16: "", flagEnabled: true))
        #expect(!ZapGate.postZapVisible(recipientLud16: "   ", flagEnabled: true))
        #expect(!ZapGate.postZapVisible(recipientLud16: "pleb@zap.cooking", flagEnabled: false))
        #expect(!ZapGate.postZapVisible(recipientLud16: nil, flagEnabled: false))
    }

    @Test func profileLevelIsIndependentOfTheFlag() {
        #expect(ZapGate.profileZapVisible(flagEnabled: true))
        #expect(ZapGate.profileZapVisible(flagEnabled: false))
    }

    @Test func defaultsReadTheShippedFlag() {
        #expect(ZapGate.postZapVisible() == FeatureFlags.zapsOnPosts)
        #expect(ZapGate.postZapVisible(recipientLud16: "pleb@zap.cooking") == FeatureFlags.zapsOnPosts)
        #expect(!ZapGate.postZapVisible(recipientLud16: nil))
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
