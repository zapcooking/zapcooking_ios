import Foundation
import Testing
@testable import wisp

/// The reaction emoji catalog is generated from Unicode's RGI
/// `emoji-test.txt` and must stay identical on Android and web (parity
/// requirement — see `tools/gen-emoji-data.py`). These tests pin the
/// properties that matter: no duplicates, no skin-tone variants, complete
/// flags, and the cultural/seasonal emoji the old hand-curated set dropped.
struct EmojiDataTests {

    // MARK: - Catalog integrity

    @Test func catalogHasNoDuplicates() {
        let all = EmojiData.allEmojis
        #expect(all.count == Set(all).count)
    }

    @Test func noSkinToneVariantsAreListed() {
        let tones: Set<Character> = ["🏻", "🏼", "🏽", "🏾", "🏿"]
        for e in EmojiData.allEmojis {
            #expect(!e.contains(where: { tones.contains($0) }), "skin-tone variant listed: \(e)")
        }
    }

    @Test func everyCategoryIconIsInItsOwnList() {
        for c in EmojiData.categories {
            #expect(c.emojis.contains(c.icon), "\(c.name) icon \(c.icon) not in its own list")
        }
    }

    /// Tab icons are curated and stable — deriving them from each group's
    /// first emoji made the Activities tab a jack-o-lantern (emoji-test.txt
    /// opens that group with 🎃).
    @Test func categoryIconsAreTheCuratedStableSet() {
        let expected: [String: String] = [
            "Smileys": "😀", "People": "👋", "Animals": "🐶", "Food": "🍔",
            "Activities": "⚽", "Travel": "✈️", "Objects": "💡",
            "Symbols": "♻️", "Flags": "🏴‍☠️",
        ]
        for c in EmojiData.categories {
            #expect(c.icon == expected[c.name], "\(c.name) tab icon drifted: \(c.icon)")
        }
    }

    @Test func flagsCategoryShipsTheFullRGISet() {
        let flags = EmojiData.categories.first { $0.name == "Flags" }
        let count = flags?.emojis.count ?? 0
        #expect(count > 250, "flags catalog shrank: \(count)")
    }

    // MARK: - Coverage regressions

    /// The emoji the old Android-ported catalog dropped entirely — seasonal,
    /// cultural, and celebration picks a food app's users expect to find.
    @Test func catalogCoversCultureAndSeasonal() {
        let missing = ["🎃", "🎄", "🎅", "🦃", "🎉", "🪔", "🧨"].filter {
            !EmojiData.allEmojis.contains($0)
        }
        #expect(missing.isEmpty, "missing from catalog: \(missing)")
    }

    @Test func searchFindsThePumpkinByItsCldrKeyword() {
        #expect(EmojiData.searchEmojis("pumpkin").contains("🎃"))
    }

    // MARK: - Quick reactions (the 3×6 picker grid)

    @Test func quickReactionsFillTheGridExactly() {
        let quick = EmojiData.defaultQuickReactions
        #expect(quick.count == 24)
        #expect(Set(quick).count == 24)
        for e in quick {
            #expect(EmojiData.allEmojis.contains(e), "quick reaction not in catalog: \(e)")
        }
    }

    /// Rows 3-4 carry the culinary block: chef + food, grouped in sequence,
    /// with the everyday proteins/veg/dishes the food app's users react with.
    @Test func quickReactionsCoverEverydayFood() {
        let required = ["🥩", "🍗", "🐟", "🥦", "🍔", "🍜", "🍝", "🌮", "🍳", "🌶️", "🧑‍🍳"]
        let missing = required.filter { !EmojiData.defaultQuickReactions.contains($0) }
        #expect(missing.isEmpty, "missing from quick reactions: \(missing)")
    }

    /// All food appears together in one sequence: after the chef, the list
    /// runs uninterrupted food — no reaction emoji interleaved.
    @Test func foodIsGroupedTogetherAtTheEnd() throws {
        let quick = EmojiData.defaultQuickReactions
        let chefAt = try #require(quick.firstIndex(of: "🧑‍🍳"))
        let foodTail = Array(quick[chefAt...])
        let reactionEmoji: Set<String> = ["❤️", "🔥", "👍", "😂", "🙏", "🤙", "💯", "✨", "🎉", "🥂", "😋", "🤤", "🤌"]
        #expect(foodTail.first == "🧑‍🍳")
        for e in foodTail.dropFirst() {
            #expect(!reactionEmoji.contains(e), "\(e) interleaves the food block")
        }
    }

    @Test func seasonalEmojiStayOutOfTheDefaults() {
        // Seasonal picks (🎃 …) live in the catalog, not the defaults —
        // a pumpkin reaction reads oddly in April.
        #expect(!EmojiData.defaultQuickReactions.contains("🎃"))
        #expect(EmojiData.allEmojis.contains("🎃"))
    }

    // MARK: - Prior-default migration

    @Test func persistedPriorDefaultUpgradesToCanonicalSet() {
        #expect(EmojiData.upgradingPriorDefault(EmojiData.previousDefaultQuickReactions)
            == EmojiData.defaultQuickReactions)
    }

    @Test func customizedListsPassThroughUnmigrated() {
        let customized = ["🐸", "🚀"]
        #expect(EmojiData.upgradingPriorDefault(customized) == customized)
        #expect(EmojiData.upgradingPriorDefault([]) == [])
    }
}
