import Foundation
import Testing
@testable import wisp

struct FoodHashtagsTests {

    @Test func all_hasEightyFiveTags_orderPreserved() {
        #expect(FoodHashtags.all.count == 85)
        #expect(FoodHashtags.all.first == "foodstr")
        #expect(FoodHashtags.all.last == "batchcooking")
        #expect(Set(FoodHashtags.all).count == 85)
        #expect(FoodHashtags.allSet.count == 85)
    }

    @Test func hasFoodTag_isCaseInsensitive() {
        let tagged = note(tags: [["t", "FoodStr"]])
        let missing = note(tags: [["t", "bitcoin"]])
        let empty = note(tags: [])
        #expect(FoodHashtags.hasFoodTag(tagged))
        #expect(!FoodHashtags.hasFoodTag(missing))
        #expect(!FoodHashtags.hasFoodTag(empty))
    }

    @Test func hasFoodTag_ignoresNonTTags() {
        let pOnly = note(tags: [["p", "foodstr"]])
        #expect(!FoodHashtags.hasFoodTag(pOnly))
    }

    private func note(tags: [[String]]) -> NostrEvent {
        NostrEvent(
            id: "e",
            pubkey: "pk",
            kind: 1,
            createdAt: 1,
            tags: tags,
            content: "",
            sig: ""
        )
    }
}
