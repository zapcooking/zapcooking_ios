import Foundation

/// The expanded food-hashtag set for the OnlyFood social feed (Concern 3.3),
/// ported from Android `nostr/FoodHashtags.kt` (web `FoodstrFeedOptimized.svelte`
/// `FOOD_HASHTAGS`).
///
/// Breadth is deliberate: filtering on `foodstr` alone makes the stream look
/// empty. Ambiguous tags (`#beef`, `#steak`, `#snack`) let some non-food noise
/// through — mute lists catch the worst. Do **not** run the NSpam scorer on this
/// set in v1 (§7.3): hashtag- and link-heavy food posts over-filter at 0.7.
nonisolated enum FoodHashtags {

    /// Deduped, order-preserved. Used as the `#t` filter for kind-1 notes.
    static let all: [String] = [
        "foodstr", "cook", "cookstr", "zapcooking", "cooking", "drinkstr",
        "foodies", "carnivor", "carnivorediet", "soup", "soupstr", "drink",
        "eat", "burger", "steak", "steakstr", "dine", "dinner", "lunch",
        "breakfast", "supper", "yum", "snack", "snackstr", "dessert", "beef",
        "chicken", "bbq", "coffee", "mealprep", "meal", "recipe", "recipestr",
        "recipes", "food", "foodie", "foodporn", "instafood", "foodstagram",
        "foodblogger", "homecooking", "fromscratch", "baking", "baker",
        "pastry", "chef", "chefs", "cuisine", "gourmet", "restaurant",
        "restaurants", "pasta", "pizza", "sushi", "tacos", "taco", "burrito",
        "sandwich", "salad", "stew", "curry", "stirfry", "grill", "grilled",
        "roast", "roasted", "fried", "baked", "smoked", "fermented", "pickled",
        "preserved", "homemade", "vegan", "vegetarian", "keto", "paleo",
        "glutenfree", "dairyfree", "healthy", "nutrition", "nutritionist",
        "dietitian", "mealplan", "batchcooking",
    ]

    /// Lowercase membership set for O(1) ``hasFoodTag`` lookups.
    ///
    /// `String.lowercased()` is Unicode default mapping (locale-invariant).
    /// That is the Swift equivalent of Android's `Locale.ROOT` — hashtags are
    /// protocol identifiers, so a Turkish locale must not map `I` → `ı`.
    static let allSet: Set<String> = Set(all.map { $0.lowercased() })

    /// True when `event` carries a `t`-tag in ``allSet`` (case-insensitive).
    /// Mirrors the relay-side `tTags = FoodHashtags.all` filter so a cache
    /// paint can replicate food-relevance before the OnlyFood choke-point.
    static func hasFoodTag(_ event: NostrEvent) -> Bool {
        for tag in event.tags {
            if tag.count >= 2, tag[0] == "t", allSet.contains(tag[1].lowercased()) {
                return true
            }
        }
        return false
    }
}
