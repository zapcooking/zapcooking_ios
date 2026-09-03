import Foundation

/// Compile-time feature kill switches for App Store compliance (build spec
/// §4.2 / §4.3, Gate 0-F).
///
/// iOS-specific posture: the app sells nothing and links out nowhere. Gated
/// features show a message only — "Cook+ members feature" — with no purchase
/// UI, no checkout, no price, and no link-out (build spec §4.3). These flags
/// mirror Android's `MEMBERSHIP_LINKOUT_ENABLED` / `FeatureFlags` pattern:
/// each is a compile-time constant, so a review-driven change is a flag flip
/// and a resubmit, not a refactor. Flip a value here only — never branch the
/// behavior at call sites with a local literal.
enum FeatureFlags {
    /// Zaps on posts (NIP-57 tip affordance on feed posts / recipes).
    ///
    /// In 2023 Apple forced Damus to remove post-level zaps (Guideline 3.1.1),
    /// treating tips tied to digital content as IAP-requiring; profile-level
    /// zaps were allowed. Primal ships post-level zaps on iOS today, so the
    /// landscape has eased — but that is precedent-by-observation, not a
    /// written rule change, and review is uneven. Ship `true`; when `false`,
    /// every post-level zap affordance is removed (kind-1 card bolt and
    /// quick zap, zap-poll vote rows, article / recipe bar bolt, live-stream
    /// host and chat zaps) and only the profile-level zap on `ProfileView`
    /// remains. Views consult `ZapGate`, never this constant directly; the
    /// truth table is `ZapGateTests`. If review pushes back, flip to `false`
    /// and resubmit.
    static let zapsOnPosts: Bool = true

    /// Link-out to `zap.cooking/membership`. **Hard `false` on iOS.** Outside
    /// the US, external-link UI for digital goods generally requires the
    /// StoreKit External Purchase Link Entitlement, and shipping the link
    /// without a region check fails review for non-US regions (build spec
    /// §4.3). A global app with no link at all has zero exposure. Members-only
    /// surfaces render a message, never a "tap to subscribe" link.
    static let membershipLinkoutEnabled: Bool = false

    /// Sous Chef URL import (Concern 2.5) — free anonymous
    /// `/api/extract-recipe/public` extraction into a preview + publish
    /// flow. Nothing on the URL path is gated or sold, so this is a plain
    /// operational kill switch, not a compliance one: when `false`, the
    /// Recipes-tab entry point disappears (`SousChefGate.entryVisible`)
    /// and no Sous Chef surface is reachable.
    static let sousChefImportEnabled: Bool = true

    /// Nourish read (Concern 3.5) — pantry kind-30078 Explore + recipe-detail
    /// card. Operational kill switch, not a compliance one: when `false`, the
    /// My Kitchen Nourish tab and the detail card disappear. Compute
    /// (`POST /api/nourish`) is deferred (build-doc item 15).
    static let nourishEnabled: Bool = true

    /// Cheffy chat (Concern C-E) — member-gated `POST /api/zappy` behind
    /// NIP-98. Operational kill switch, not a compliance one: the gate
    /// itself is server-side and renders message-only (§4.3). When `false`,
    /// the Recipes-tab sparkle-menu entry disappears (`CheffyGate.entryVisible`)
    /// and no Cheffy surface is reachable.
    static let cheffyEnabled: Bool = true

    /// Lightning credit purchase for Note Review (21-sat pay-per-use LLM).
    /// **Hard `false` on iOS, and the purchase code path is intentionally NOT
    /// ported.** Paying Lightning in-app to unlock an in-app AI feature is the
    /// single clearest 3.1.1 violation in the Android codebase (build spec
    /// §4.3). This flag exists so any future port can be gated from one place
    /// rather than threaded through every call site.
    static let noteReviewCreditPurchaseEnabled: Bool = false
}
