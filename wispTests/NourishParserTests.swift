import Foundation
import Testing
@testable import wisp

/// Android `NourishParserTest` goldens — pantry content + compute response.
struct NourishParserTests {
    private let fullV3 = """
        {
          "realFood": {"score": 8, "label": "Strong"},
          "gut": {"score": 7, "label": "Strong"},
          "protein": {"score": 6, "label": "Moderate"},
          "antiInflammatory": {"score": 5, "label": "Moderate"},
          "bloodSugar": {"score": 4, "label": "Fair"},
          "immuneSupportive": {"score": 7, "label": "Strong"},
          "brainHealth": {"score": 6, "label": "Moderate"},
          "heartHealth": {"score": 9, "label": "Excellent"},
          "overall": {"score": 7, "label": "Strong"},
          "improvements": ["Add a leafy green", "Swap to olive oil", ""],
          "promptVersion": "3"
        }
        """

    private func fullV4(
        confidence: String = "estimate",
        servingsParsed: Bool = true,
        servingsUsed: Int = 4,
        extraFields: String = ""
    ) -> String {
        """
        {
          "realFood": {"score": 8, "label": "Strong"},
          "gut": {"score": 7, "label": "Strong"},
          "protein": {"score": 6, "label": "Moderate"},
          "antiInflammatory": {"score": 5, "label": "Moderate"},
          "bloodSugar": {"score": 4, "label": "Fair"},
          "immuneSupportive": {"score": 7, "label": "Strong"},
          "brainHealth": {"score": 6, "label": "Moderate"},
          "heartHealth": {"score": 9, "label": "Excellent"},
          "overall": {"score": 7, "label": "Strong"},
          "improvements": ["Add a leafy green", "Swap to olive oil"],
          "promptVersion": "4",
          "macros": {
            "perServing": {"kcal": 420, "protein_g": 32, "carbs_g": 28, "fat_g": 18},
            "servingsUsed": \(servingsUsed),
            "servingsParsed": \(servingsParsed),
            "confidence": "\(confidence)",
            "method": "llm-per100g-v1"\(extraFields)
          }
        }
        """
    }

    @Test func servicePubkey_matchesFrontendSourceOfTruth() {
        #expect(
            NourishParser.servicePubkey
                == "fdd263f69f9e95a2a0a58ec3e7e8053011214fa66007d93b26d2f4717d31917b"
        )
        #expect(NourishParser.kind == 30078)
    }

    @Test func parsesAllDimensionsAndOverall() throws {
        let s = try #require(NourishParser.parse(fullV3))
        #expect(s.overall == 7)
        #expect(s.overallLabel == "Strong")
        #expect(s.dimensions.count == 8)
        #expect(s.dimensions.first == NourishDimension(name: "Real Food", score: 8))
        #expect(s.dimensions.last == NourishDimension(name: "Heart", score: 9))
        #expect(s.improvements == ["Add a leafy green", "Swap to olive oil"])
        #expect(s.macros == nil)
        #expect(NourishParser.macrosRowView(s.macros) == nil)
    }

    @Test func trustsStoredOverall_doesNotRecomputeFromDims() throws {
        let json = """
            {"realFood":{"score":1},"gut":{"score":1},"protein":{"score":1},
             "antiInflammatory":{"score":0},"bloodSugar":{"score":0},
             "immuneSupportive":{"score":0},"brainHealth":{"score":0},
             "heartHealth":{"score":0},"overall":{"score":9,"label":"Excellent"}}
            """
        #expect(try #require(NourishParser.parse(json)).overall == 9)
    }

    @Test func legacyEvent_missingDims_defaultToZero() throws {
        let json = """
            {"gut":{"score":6},"protein":{"score":5},"realFood":{"score":7},
             "overall":{"score":6,"label":"Moderate"}}
            """
        let s = try #require(NourishParser.parse(json))
        #expect(s.overall == 6)
        #expect(s.dimensions.first { $0.name == "Heart" }?.score == 0)
        #expect(s.dimensions.first { $0.name == "Blood Sugar" }?.score == 0)
        #expect(s.dimensions.first { $0.name == "Real Food" }?.score == 7)
    }

    @Test func missingOverall_yieldsNil() {
        #expect(NourishParser.parse(#"{"gut":{"score":5}}"#) == nil)
    }

    @Test func malformed_yieldsNil_noCrash() {
        #expect(NourishParser.parse("not json") == nil)
        #expect(NourishParser.parse("") == nil)
    }

    @Test func outOfRangeScores_areClampedTo0to10() throws {
        let json = """
            {"realFood":{"score":15},"gut":{"score":-3},"protein":{"score":7},
             "antiInflammatory":{"score":0},"bloodSugar":{"score":0},
             "immuneSupportive":{"score":0},"brainHealth":{"score":0},
             "heartHealth":{"score":0},"overall":{"score":99}}
            """
        let s = try #require(NourishParser.parse(json))
        #expect(s.overall == 10)
        #expect(s.dimensions.first { $0.name == "Real Food" }?.score == 10)
        #expect(s.dimensions.first { $0.name == "Gut" }?.score == 0)
    }

    @Test func parseScores_computeResponsePath_trustsStoredOverall() throws {
        let response = """
            {
              "success": true,
              "scores": {
                "realFood": {"score": 1}, "gut": {"score": 1}, "protein": {"score": 1},
                "antiInflammatory": {"score": 0}, "bloodSugar": {"score": 0},
                "immuneSupportive": {"score": 0}, "brainHealth": {"score": 0},
                "heartHealth": {"score": 0}, "overall": {"score": 8, "label": "Strong"}
              },
              "improvements": ["Add greens"],
              "audience_scores": {"kidFriendly": {"score": 5}},
              "promptVersion": "3",
              "createdAt": 1700000000
            }
            """
        let obj = try #require(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        let scores = try #require(obj["scores"] as? [String: Any])
        let s = try #require(
            NourishParser.parseScores(scores, improvements: NourishParser.extractImprovements(obj))
        )
        #expect(s.overall == 8)
        #expect(s.overallLabel == "Strong")
        #expect(s.dimensions.count == 8)
        #expect(s.improvements == ["Add greens"])
    }

    @Test func dTag_format() {
        #expect(
            NourishParser.dTag(
                recipeAuthor: "abc",
                recipeDTag: "tuscan-peposo-(black-pepper-beef-stew)"
            ) == "nourish:30023:abc:tuscan-peposo-(black-pepper-beef-stew)"
        )
    }

    @Test func v4_parsesMacros_estimate() throws {
        let s = try #require(NourishParser.parse(fullV4()))
        #expect(s.overall == 7)
        let m = try #require(s.macros)
        #expect(m.perServing.kcal == 420)
        #expect(m.perServing.proteinG == 32)
        #expect(m.perServing.carbsG == 28)
        #expect(m.perServing.fatG == 18)
        #expect(m.servingsUsed == 4)
        #expect(m.servingsParsed)
        #expect(m.confidence == "estimate")
        #expect(m.method == "llm-per100g-v1")
        let row = try #require(NourishParser.macrosRowView(m))
        #expect(row.label == "Estimated per serving")
        #expect(row.tone == "estimate")
        #expect(row.kcal == 420)
    }

    @Test func v4_rough_confidence_mapsToRoughEstimate() throws {
        let s = try #require(NourishParser.parse(fullV4(confidence: "rough")))
        #expect(s.macros?.confidence == "rough")
        #expect(NourishParser.macrosRowView(s.macros)?.label == "Rough estimate")
        #expect(NourishParser.macrosRowView(s.macros)?.tone == "rough")
    }

    @Test func servingsParsedFalse_appendsAssumedServings() throws {
        let s = try #require(
            NourishParser.parse(fullV4(servingsParsed: false, servingsUsed: 4))
        )
        #expect(s.macros?.servingsParsed == false)
        #expect(
            NourishParser.macrosRowView(s.macros)?.label
                == "Estimated per serving (servings assumed: 4)"
        )
    }

    @Test func malformedMacros_degradeToAbsent_scoresStillParse() throws {
        let json = """
            {
              "realFood":{"score":8},"gut":{"score":7},"protein":{"score":6},
              "antiInflammatory":{"score":5},"bloodSugar":{"score":4},
              "immuneSupportive":{"score":7},"brainHealth":{"score":6},
              "heartHealth":{"score":9},"overall":{"score":7,"label":"Strong"},
              "improvements":[],
              "macros": {"confidence": "estimate", "servingsUsed": 4}
            }
            """
        let s = try #require(NourishParser.parse(json))
        #expect(s.overall == 7)
        #expect(s.macros == nil)
        #expect(NourishParser.macrosRowView(nil) == nil)
    }

    @Test func invalidConfidence_degradesToAbsent() throws {
        let s = try #require(NourishParser.parse(fullV4(confidence: "high")))
        #expect(s.overall == 7)
        #expect(s.macros == nil)
    }

    @Test func unknownFutureMacrosFields_areTolerated() throws {
        let s = try #require(
            NourishParser.parse(
                fullV4(extraFields: #", "fiber_g": 12, "sodium_mg": 400, "futureBlock": {"x": 1}"#)
            )
        )
        #expect(s.macros != nil)
        #expect(s.macros?.perServing.kcal == 420)
    }
}
