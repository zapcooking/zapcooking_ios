import Foundation

/// The one seam every zap affordance consults for `FeatureFlags.zapsOnPosts`
/// (build spec §4.2 / §4.8, Gate 0-F).
///
/// The Damus precedent (2023, Guideline 3.1.1): Apple objected to tips
/// *connected to digital content* and accepted tips at the profile level.
/// So the split is by what the tip is attached to, not by which screen it
/// lives on:
///
/// - **Post-level** — any bolt that zaps a specific event or addressable
///   content: the kind-1 card action bar (tap, long-press quick zap, and the
///   NIP-69 zap-poll vote rows), the article / recipe action bar, and the
///   live-stream screen (the host zap carries the stream's `a` tag; the chat
///   zap carries the message id). Hidden when the flag is off.
/// - **Profile-level** — the lightning-address tap and zap button on
///   `ProfileView` (`eventId: nil`, no `a` tag). Always shown.
///
/// Call sites branch on these functions only, never on the flag directly, so
/// a review-driven flip is one edit in `FeatureFlags` and the hermetic
/// `ZapGateTests` truth table pins the semantics.
enum ZapGate {
    /// Whether post-level zap affordances render. Defaults to the flag; the
    /// parameter is the test seam.
    static func postZapVisible(flagEnabled: Bool = FeatureFlags.zapsOnPosts) -> Bool {
        flagEnabled
    }

    /// Whether a post-level zap affordance renders for a specific recipient:
    /// the flag must be on AND the recipient must have a lightning address.
    /// A zap without one always fails at send time ("Recipient has no
    /// lightning address", `ZapSender`), so the bolt is never offered.
    /// `lud16` is the only address iOS reads (`ProfileData`); nil, empty, or
    /// whitespace-only counts as no address.
    static func postZapVisible(recipientLud16: String?, flagEnabled: Bool = FeatureFlags.zapsOnPosts) -> Bool {
        flagEnabled && hasLightningAddress(recipientLud16)
    }

    private static func hasLightningAddress(_ lud16: String?) -> Bool {
        guard let lud16 else { return false }
        return !lud16.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Profile-level zaps survive the flip — that is the whole point of the
    /// switch. Takes the flag so the truth table can prove independence.
    static func profileZapVisible(flagEnabled _: Bool = FeatureFlags.zapsOnPosts) -> Bool {
        true
    }
}
