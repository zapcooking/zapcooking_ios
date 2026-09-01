import Foundation

/// Concern C-H — composing a kind-1 note from the OnlyFood tab.
///
/// OnlyFood reads kind-1 over the ``FoodHashtags`` `#t` filter, so a note
/// composed there without a food hashtag never comes back into the feed
/// the author just posted to. Neither Android nor web solves this: both
/// open a hashtag-agnostic composer and accept the dead end (web's only
/// guidance is a members-tab empty-state line suggesting cooking tags).
///
/// iOS closes it the way Android's onboarding first-post screen prefills
/// `#introductions`: the editor opens with a **visible, removable**
/// `#foodstr` on its own line and the caret below it. The composer's
/// ordinary hashtag derivation turns that text into the `t` tag and shows
/// it as a chip, so the author sees exactly what will be published and can
/// delete it. Nothing is appended silently. The tag costs one of the five
/// the §7.3 structural cap allows (`max(content #tags, t-tags) > 5`).
nonisolated enum OnlyFoodCompose {
    /// First entry of `FoodHashtags.all` on all three platforms and the
    /// community's canonical food tag. `zapcooking` is the recipe root tag
    /// stamped on kind-30023 recipes, so it reads as a brand marker on a
    /// kind-1 note rather than a topic.
    static let defaultTag = "foodstr"

    /// Editor seed: tag first, blank line, caret at the end (the composer
    /// text view places the caret after a diff-from-empty). Same shape as
    /// Android `OnboardingFirstPostScreen.INTRO_PREFIX`.
    static let prefill = "#\(defaultTag)\n\n"
}
