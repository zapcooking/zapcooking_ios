import Foundation
import Testing
@testable import wisp

struct FoodTopicsTests {

    @Test func toHashtag_stripsSpacesAndHyphens() {
        #expect(FoodTopics.toHashtag("Gluten Free") == "glutenfree")
        #expect(FoodTopics.toHashtag("Middle-Eastern") == "middleeastern")
        #expect(FoodTopics.toHashtag("Dairy-Free") == "dairyfree")
        #expect(FoodTopics.toHashtag("From Scratch") == "fromscratch")
        #expect(FoodTopics.toHashtag("BBQ") == "bbq")
    }

    @Test func sections_includeBeyondFood_whichIsNotAFoodHashtag() {
        #expect(FoodTopics.sections.count == 10)
        #expect(FoodTopics.sections.last?.title == "Beyond food")
        #expect(FoodTopics.sections.last?.note != nil)
        let bitcoin = FoodTopics.toHashtag("Bitcoin")
        #expect(!FoodHashtags.allSet.contains(bitcoin))
    }

    @Test func foodSections_normalizeIntoFoodHashtags_forKnownOverlap() {
        for label in ["Breakfast", "Vegan", "Pasta", "Foodstr", "Chef"] {
            #expect(FoodHashtags.allSet.contains(FoodTopics.toHashtag(label)))
        }
    }
}
