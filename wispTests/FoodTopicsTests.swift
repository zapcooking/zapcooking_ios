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

    @Test func allHashtags_isNormalized_dedupedAndCoversEverySection() {
        let all = FoodTopics.allHashtags
        #expect(Set(all).count == all.count)
        for hashtag in all {
            #expect(Nip51Hashtags.normalize(hashtag) == hashtag, "\(hashtag) must already be a valid #t value")
        }
        for section in FoodTopics.sections {
            for tag in section.tags { #expect(all.contains(FoodTopics.toHashtag(tag))) }
        }
        // "Pasta" and "Breakfast" appear in two sections each; dedupe keeps one.
        #expect(all.filter { $0 == "pasta" }.count == 1)
        #expect(all.first == "easy")
    }

    @Test func foodSections_normalizeIntoFoodHashtags_forKnownOverlap() {
        for label in ["Breakfast", "Vegan", "Pasta", "Foodstr", "Chef"] {
            #expect(FoodHashtags.allSet.contains(FoodTopics.toHashtag(label)))
        }
    }
}
