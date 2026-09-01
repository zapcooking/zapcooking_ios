import Foundation

/// Cheffy — shared voice lines and small helpers for Zap Cooking's kitchen
/// companion (Concern C-E). A **verbatim port of the web `$lib/cheffy.ts`**
/// (Android `cheffy/Cheffy.kt` is the same port) so the iOS assistant speaks
/// in exactly the same voice: the rotating line pools, the input
/// placeholders, and the structured-recipe gate that decides how a reply
/// renders and whether "Save to my recipes" attaches to it.
///
/// Pure (strings + regex), so the recipe gates are unit-tested against the
/// web's cases in `CheffyTests`.
nonisolated enum Cheffy {

    /// Cheffy's small, typed set of moods (mirrors the web `CheffyExpression`).
    enum Expression: String, CaseIterable, Sendable {
        case neutral, happy, thinking, excited, concerned, cooking
    }

    /// Rotating placeholders for the main Cheffy input.
    static let promptPlaceholders: [String] = [
        "What are we cooking?",
        "Tell me what is in your fridge.",
        "Can I substitute yogurt for sour cream?",
        "I burned the bottom. Can this be saved?",
        "I need dinner in 20 minutes.",
        "What goes well with salmon?",
    ]

    /// Shown while Cheffy is preparing a conversational reply.
    static let thinkingLines: [String] = [
        "Tasting the idea…",
        "Rummaging through the pantry…",
        "Thinking with my whole spatula…",
        "Checking what plays well together…",
        "Giving it a quick stir…",
    ]

    /// Shown while Cheffy is generating a full structured recipe.
    static let cookingLines: [String] = [
        "Firing up the burners…",
        "Plating this up…",
        "Dinner has entered the chat…",
        "Three ingredients, zero panic…",
        "Crisping the edges…",
    ]

    /// Cooking-flavored error lines. Each is paired in the UI with a real
    /// recovery action and the actual technical detail — these never hide a
    /// validation, membership, or network error.
    static let errorLines: [String] = [
        "Cheffy dropped a spoon. Try that again.",
        "The kitchen lost the signal for a second.",
        "That request did not finish cooking.",
        "Cheffy got distracted by something on the stove.",
    ]

    /// Pick a line from a pool, avoiding `avoid` (usually the previously
    /// shown line) so consecutive states don't repeat. Falls back to the
    /// first line for single-entry pools. Mirrors the web `pickLine`; the
    /// index source is injectable so the re-roll is testable.
    static func pickLine(
        _ pool: [String],
        avoid: String? = nil,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> String {
        if pool.isEmpty { return "" }
        if pool.count == 1 { return pool[0] }
        var next = pool[randomIndex(pool.count)]
        // One re-roll is enough to dodge an immediate repeat without risking a
        // pathological loop.
        if next == avoid, let i = pool.firstIndex(of: next) {
            next = pool[(i + 1) % pool.count]
        }
        return next
    }

    private static let ingredientsHeading = try! NSRegularExpression(
        pattern: #"^##\s*Ingredients\b"#, options: [.caseInsensitive, .anchorsMatchLines]
    )
    private static let directionsHeading = try! NSRegularExpression(
        pattern: #"^##\s*Directions\b"#, options: [.caseInsensitive, .anchorsMatchLines]
    )
    private static let titleHeading = try! NSRegularExpression(
        pattern: #"^#\s+\S"#, options: [.anchorsMatchLines]
    )

    /// Does this assistant message contain a full, structured recipe (the
    /// format `RecipeComposeViewModel.prefillFromMarkdown` parses), as
    /// opposed to a conversational answer? Requires a title heading plus
    /// both an Ingredients and a Directions section. Verbatim port of the
    /// web `looksLikeStructuredRecipe` — this gate decides whether the
    /// "Save to my recipes" action attaches to a reply.
    static func looksLikeStructuredRecipe(_ markdown: String?) -> Bool {
        guard let md = markdown, !md.isEmpty else { return false }
        let range = NSRange(md.startIndex..., in: md)
        return titleHeading.firstMatch(in: md, range: range) != nil
            && ingredientsHeading.firstMatch(in: md, range: range) != nil
            && directionsHeading.firstMatch(in: md, range: range) != nil
    }

    private static let recipeRequest = try! NSRegularExpression(
        pattern: #"\b(recipe|cook|dinner|lunch|breakfast|dessert|make me)\b"#,
        options: [.caseInsensitive]
    )
    private static let havePrefix = try! NSRegularExpression(
        pattern: #"\bi have:?\s"#, options: [.caseInsensitive]
    )

    /// Cosmetic only — does the user's text read like a recipe request, so
    /// the pending bubble shows the "cooking" expression + `cookingLines`
    /// instead of `thinkingLines`? Mirrors the web `looksLikeRecipeRequest`.
    static func looksLikeRecipeRequest(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return recipeRequest.firstMatch(in: text, range: range) != nil
            || havePrefix.firstMatch(in: text, range: range) != nil
    }

    /// Server-enforced caps (`api/zappy/+server.ts`), mirrored client-side
    /// for clean UX: the prompt is truncated before send, the history is
    /// the last N resolved turns.
    static let maxPromptChars = 2000
    static let maxHistoryTurns = 12

    // MARK: - Gate copy (message only — build spec §4.3)

    /// The members-gate message. Android `Cheffy.MEMBERS_ONLY_MESSAGE`
    /// verbatim. Message only: no purchase UI, no price, no link-out
    /// (`FeatureFlags.membershipLinkoutEnabled` is hard `false`).
    static let membersOnlyMessage = "Cheffy is a Pro Kitchen members feature."

    /// Second line under the gate for a watch-only (npub-only) account —
    /// Android `GatedState` verbatim.
    static let signInMessage = "Sign in with a key to cook with Cheffy."

    /// In-chat line for a bare 403 (no `code`). Deliberately NOT a flat
    /// denial: the membership lookup runs against pantry and an outage
    /// renders as the same 403, so the copy names both readings.
    static let unavailableMessage =
        "Cheffy isn't available for this account right now. Cheffy is a Pro Kitchen members feature, and the kitchen may also be briefly offline."

    /// 401 / NIP-98 rejected — a broken or stale signature, not a
    /// membership question.
    static let signatureRejectedMessage = "Cheffy couldn't verify your key. Try again."

    /// 429 (`RATE_LIMITED`). Derived from the web's note-review /
    /// fridge-scan limit lines with the noun changed.
    static let rateLimitedMessage = "Cheffy needs a breather — you've hit the chat limit for now."

    /// Compute-client timeout (75 s) — a "try again" case, not connectivity.
    static let timedOutMessage = "That one took too long to cook — try again in a moment."

    /// Everything else at the transport layer. Web `PHOTO_NETWORK_ERROR_LINE`
    /// with the noun generalized.
    static let networkErrorMessage = "Cheffy couldn't be reached. Check your connection and try again."

    /// The user-turn display text for "Surprise me" (Android verbatim).
    static let surpriseMeLabel = "Surprise me 🎲"

    /// "a minute" / "N minutes" for a server `retryAfter` (same rounding as
    /// `SousChefViewModel.formatRetryAfter`, duplicated because that one is
    /// main-actor-isolated and the bubble mapper is pure).
    static func formatRetryAfter(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return "a minute" }
        return "\(minutes) minutes"
    }
}

/// Kill switch → entry point (mirrors `SousChefGate.entryVisible`). The flag
/// is compile-time (`FeatureFlags.cheffyEnabled`); this seam is what the
/// entry-point call sites branch on so the off state is assertable.
enum CheffyGate {
    static func entryVisible(flagEnabled: Bool = FeatureFlags.cheffyEnabled) -> Bool {
        flagEnabled
    }
}
