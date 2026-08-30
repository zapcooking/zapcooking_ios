import Foundation

/// The curated, sectioned topic taxonomy shown in onboarding ("What do you
/// like to cook?"). Port of Android `nostr/FoodTopics.kt`.
///
/// Food sections match the web client's `CURATED_TAG_SECTIONS`. This is **not**
/// a strictly food-only taxonomy: the "Beyond food" section includes broad
/// Nostr interests that do **not** normalize into ``FoodHashtags/all``. Those
/// publish as ordinary `#t` interests and do not affect the OnlyFood feed.
///
/// Single source of truth for the onboarding topic picker (Concern 3.4);
/// do not hardcode a second flat list elsewhere. Tags are stored as display
/// labels (e.g. "Gluten Free"); ``toHashtag`` normalizes a label into a
/// nostr `#t` hashtag when the selection is published as a kind-30015 set.
nonisolated enum FoodTopics {

    struct Section: Equatable, Sendable {
        var emoji: String
        var title: String
        var tags: [String]
        var note: String? = nil
    }

    static let sections: [Section] = [
        Section(
            emoji: "🍽️",
            title: "Why are you cooking?",
            tags: ["Easy", "Quick", "Breakfast", "Lunch", "Supper", "Dessert", "Snack", "Drinks"]
        ),
        Section(
            emoji: "🌍",
            title: "Explore by culture",
            tags: [
                "American", "Asian", "Chinese", "French", "German", "Greek", "Indian", "Italian",
                "Japanese", "Mexican", "Spanish", "Thai", "Turkish", "Vietnamese", "Mediterranean",
                "Middle-Eastern", "Brazilian", "Filipino", "Lebanese",
            ]
        ),
        Section(
            emoji: "🥩",
            title: "Proteins",
            tags: ["Beef", "Chicken", "Fish", "Lamb", "Pork", "Seafood", "Steak", "Turkey", "Duck", "Eggs", "Tofu"]
        ),
        Section(
            emoji: "🥕",
            title: "Ingredients",
            tags: [
                "Apple", "Beans", "Bread", "Cheese", "Chocolate", "Coconut", "Corn", "Cream", "Fruit",
                "Garlic", "Mushrooms", "Noodles", "Pasta", "Peppers", "Potato", "Rice", "Spinach",
                "Tomato", "Vegetables",
            ]
        ),
        Section(
            emoji: "🍳",
            title: "Meals",
            tags: ["Pizza", "Pasta", "Soup", "Salad", "Sandwich", "Smoothie", "Breakfast", "Lunch", "Supper"]
        ),
        Section(
            emoji: "🔥",
            title: "Methods",
            tags: ["Baked", "Fry", "Oven", "Roast", "Slowcooked", "Grill", "Smoked", "Fermented", "Pickled", "Stir-fry"]
        ),
        Section(
            emoji: "🥗",
            title: "Lifestyle",
            tags: ["Vegan", "Keto", "Healthy", "Gluten Free", "Vegetarian", "Paleo", "Dairy-Free"]
        ),
        Section(
            emoji: "🌶️",
            title: "Flavor",
            tags: ["Spicy", "Sweet", "Curry"]
        ),
        Section(
            emoji: "🍴",
            title: "From the foodstr feed",
            tags: [
                "Foodstr", "Foodie", "Homemade", "From Scratch", "Home Cooking", "Meal Prep", "BBQ",
                "Coffee", "Gourmet", "Chef", "Pastry", "Sushi", "Tacos", "Burrito",
            ]
        ),
        Section(
            emoji: "🌐",
            title: "Beyond food",
            tags: [
                "Ask Nostr", "Homesteading", "Sports", "AI", "Bitcoin", "Nostr", "Photography", "Art",
                "Music", "Gardening", "Travel", "Health",
            ],
            note: "Zap Cooking is all about food — but Nostr is a wide-open network. Here are a few "
                + "other topics people post about, if you'd like them in your interests too."
        ),
    ]

    /// Normalize a display tag to a nostr `#t` hashtag: lowercase with spaces
    /// and hyphens stripped, e.g. "Gluten Free" → "glutenfree",
    /// "Middle-Eastern" → "middleeastern". Matches ``FoodHashtags/all``.
    static func toHashtag(_ tag: String) -> String {
        tag.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
