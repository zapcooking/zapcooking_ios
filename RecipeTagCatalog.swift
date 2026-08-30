import Foundation

/// One curated browse category. `tag` is the slug used on the wire as
/// `<root>-<tag>` (e.g. `zapcooking-italian`).
struct RecipeTag: Equatable, Hashable, Sendable {
    var tag: String
    var label: String
    var emoji: String
}

/// Curated recipe categories shared by:
/// - Recipes tab chips
/// - Recipe tag feed header metadata
/// - (later) Search "Tags" tab instant matches
///
/// Port of Android `nostr/RecipeTagCatalog.kt`. The catalog is the browse
/// list — it is **not** derived from events. Per-recipe `<root>-<slug>`
/// t-tags (`zapcooking-tuscan-peposo-(black-pepper-beef-stew)`) are not
/// browse categories and must not appear here
/// (`ZAPCOOKING_IOS_BUILD.md` §2 / Concern 1.7).
enum RecipeTagCatalog {

    static let recipeTags: [RecipeTag] = [
        RecipeTag(tag: "breakfast", label: "Breakfast", emoji: "🍳"),
        RecipeTag(tag: "lunch", label: "Lunch", emoji: "🥪"),
        RecipeTag(tag: "dinner", label: "Dinner", emoji: "🍽️"),
        RecipeTag(tag: "snack", label: "Snacks", emoji: "🍿"),
        RecipeTag(tag: "dessert", label: "Desserts", emoji: "🍰"),
        RecipeTag(tag: "baking", label: "Baking", emoji: "🧁"),
        RecipeTag(tag: "bread", label: "Bread", emoji: "🍞"),
        RecipeTag(tag: "soup", label: "Soups", emoji: "🥣"),
        RecipeTag(tag: "salad", label: "Salads", emoji: "🥗"),
        RecipeTag(tag: "pasta", label: "Pasta", emoji: "🍝"),
        RecipeTag(tag: "pizza", label: "Pizza", emoji: "🍕"),
        RecipeTag(tag: "grill", label: "Grill", emoji: "🔥"),
        RecipeTag(tag: "bbq", label: "BBQ", emoji: "🍖"),
        RecipeTag(tag: "vegan", label: "Vegan", emoji: "🥦"),
        RecipeTag(tag: "vegetarian", label: "Vegetarian", emoji: "🥕"),
        RecipeTag(tag: "chicken", label: "Chicken", emoji: "🍗"),
        RecipeTag(tag: "beef", label: "Beef", emoji: "🥩"),
        RecipeTag(tag: "seafood", label: "Seafood", emoji: "🦐"),
        RecipeTag(tag: "rice", label: "Rice", emoji: "🍚"),
        RecipeTag(tag: "noodles", label: "Noodles", emoji: "🍜"),
        RecipeTag(tag: "curry", label: "Curry", emoji: "🍛"),
        RecipeTag(tag: "tacos", label: "Tacos", emoji: "🌮"),
        RecipeTag(tag: "sandwich", label: "Sandwiches", emoji: "🥪"),
        RecipeTag(tag: "mealprep", label: "Meal Prep", emoji: "📦"),
        RecipeTag(tag: "onepot", label: "One Pot", emoji: "🍲"),
        RecipeTag(tag: "cocktail", label: "Cocktails", emoji: "🍸"),
        RecipeTag(tag: "coffee", label: "Coffee", emoji: "☕"),
        RecipeTag(tag: "italian", label: "Italian", emoji: "🇮🇹"),
        RecipeTag(tag: "mexican", label: "Mexican", emoji: "🇲🇽"),
        RecipeTag(tag: "indian", label: "Indian", emoji: "🇮🇳"),
    ]

    private static let byTagIndex: [String: RecipeTag] = {
        Dictionary(uniqueKeysWithValues: recipeTags.map { ($0.tag, $0) })
    }()

    private static let popularTagKeys = [
        "breakfast",
        "dinner",
        "dessert",
        "chicken",
        "vegan",
        "pasta",
        "soup",
        "cocktail",
    ]

    /// Lowercased, trimmed slug. Empty when `tag` is blank.
    static func normalize(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func byTag(_ tag: String) -> RecipeTag? {
        byTagIndex[normalize(tag)]
    }

    /// Header metadata for a tag feed. Catalog hits keep their emoji/label;
    /// an unknown slug (a detail-chip category that is not a browse entry)
    /// still renders, rather than collapsing to a generic "Tag".
    static func display(for tag: String) -> RecipeTag {
        let normalized = normalize(tag)
        if let known = byTagIndex[normalized] { return known }
        return RecipeTag(tag: normalized, label: Self.titleCase(normalized), emoji: "🏷️")
    }

    static var popularRecipeTags: [RecipeTag] {
        popularTagKeys.compactMap { byTagIndex[$0] }
    }

    static func search(_ query: String) -> [RecipeTag] {
        let needle = normalize(query)
        if needle.isEmpty { return [] }
        return recipeTags.filter { tag in
            tag.tag.contains(needle) || tag.label.lowercased().contains(needle)
        }
    }

    /// `mealprep` → "Mealprep". Catalog entries supply their own label;
    /// this is only the unknown-slug fallback.
    private static func titleCase(_ slug: String) -> String {
        guard let first = slug.first else { return slug }
        return first.uppercased() + slug.dropFirst()
    }
}
