import Foundation
import Testing
@testable import wisp

/// Port of web `src/lib/freshFeed/topicList.test.ts` (parsing) and the
/// `parseSuggested` cases of `discovery.test.ts`.
@MainActor
struct FreshTopicCatalogTests {
    static let doc: [String: Any] = [
        "name": "feed.zap.cooking",
        "topics": [
            "namespace": "cooking.zap.topic",
            "featured_topics": [
                ["slug": "meat-seafood", "label": "Meat"],
                ["slug": "cakes", "label": " Cakes "],
            ],
            "parents": [
                [
                    "slug": "baking", "name": "Baking", "count_14d": 27,
                    "topics": [
                        ["slug": "sourdough", "name": "Sourdough", "count_14d": 6],
                        ["slug": "bread", "name": "Bread", "count_14d": 11],
                    ],
                ],
                ["slug": "drinks", "name": "Drinks", "topics": [["slug": "coffee", "name": "Coffee"]]],
            ],
        ] as [String: Any],
    ]

    // MARK: parseTopics

    @Test func readsGroupsAndTopicsInOrder_withTheir14DayCounts() {
        #expect(FreshTopicCatalog.parseTopics(Self.doc) == [
            FreshTopicGroup(slug: "baking", name: "Baking", count14d: 27, topics: [
                FreshTopic(slug: "sourdough", name: "Sourdough", count14d: 6),
                FreshTopic(slug: "bread", name: "Bread", count14d: 11),
            ]),
            FreshTopicGroup(slug: "drinks", name: "Drinks", count14d: 0, topics: [
                FreshTopic(slug: "coffee", name: "Coffee", count14d: 0),
            ]),
        ])
    }

    @Test func isEmptyWithoutATopicsField_orWithAMalformedOne() {
        #expect(FreshTopicCatalog.parseTopics(["name": "x"]).isEmpty)
        #expect(FreshTopicCatalog.parseTopics(nil).isEmpty)
        #expect(FreshTopicCatalog.parseTopics(["topics": ["parents": "nope"]]).isEmpty)
    }

    @Test func dropsBadSlugsMissingNamesEmptyGroups_badCountsReadAsZero() {
        let doc: [String: Any] = ["topics": ["parents": [
            ["slug": "Bad Slug", "name": "x", "topics": [["slug": "a", "name": "A"]]],
            ["slug": "empty", "name": "Empty", "topics": [Any]()],
            ["slug": "ok", "name": "OK", "count_14d": -3, "topics": [
                ["slug": "fine", "name": "Fine", "count_14d": "many"],
                ["slug": "noname"],
                ["slug": "x;drop", "name": "X"],
            ]],
        ]]]
        #expect(FreshTopicCatalog.parseTopics(doc) == [
            FreshTopicGroup(slug: "ok", name: "OK", count14d: 0, topics: [FreshTopic(slug: "fine", name: "Fine", count14d: 0)]),
        ])
    }

    // MARK: parseFeatured

    @Test func readsSlugsAndTrimmedShortLabelsInOrder() {
        #expect(FreshTopicCatalog.parseFeatured(Self.doc) == [
            FreshFeaturedTopic(slug: "meat-seafood", label: "Meat"),
            FreshFeaturedTopic(slug: "cakes", label: "Cakes"),
        ])
    }

    @Test func featuredNilWhenAbsent_badEntriesDropped() {
        #expect(FreshTopicCatalog.parseFeatured(["topics": ["parents": [Any]()]]) == nil)
        let doc: [String: Any] = ["topics": ["featured_topics": [
            ["slug": "ok", "label": "OK"],
            ["slug": "Bad", "label": "x"],
            ["slug": "nolabel"],
        ]]]
        #expect(FreshTopicCatalog.parseFeatured(doc) == [FreshFeaturedTopic(slug: "ok", label: "OK")])
    }

    // MARK: loadTopics (URL only: no network in this PR)

    @Test func nip11IsAskedOfTheFeedRelayOverHTTPS() {
        #expect(FreshTopicCatalog.nip11Url() == "https://feed.zap.cooking")
        #expect(FreshTopicCatalog.nip11Url("ws://localhost:7777") == "http://localhost:7777")
    }

    @Test func emptyCatalogFromABodyThatIsNotJSON() {
        #expect(FreshTopicCatalog.parse(nip11: Data("offline".utf8)) == .empty)
    }

    // MARK: parseSuggested (discovery.test.ts)

    @Test func suggested_dropsBadEntriesAndRepeats_trimsLabelsAndBlurbs_keepsOnlyWebPictures() {
        let doc: [String: Any] = ["topics": ["suggested": [
            ["slug": "Bad Slug", "label": "x"],
            ["slug": "ok", "label": "  "],
            NSNull(),
            ["slug": "beef", "label": " Beef ", "blurb": "  ", "image": "javascript:alert(1)", "count_14d": "40"],
            ["slug": "beef", "label": "Beef again"],
            ["slug": "pasta", "label": "Pasta", "image": " https://img.example/p.webp "],
        ] as [Any]]]
        #expect(FreshTopicCatalog.parseSuggested(doc) == [
            FreshSuggestedTopic(slug: "beef", label: "Beef", count14d: 40),
            FreshSuggestedTopic(slug: "pasta", label: "Pasta", image: "https://img.example/p.webp", count14d: 0),
        ])
        #expect(FreshTopicCatalog.parseSuggested(["topics": [String: Any]()]) == nil)
    }

    /// From the `suggestedRows` cases: the relay's order, blurb and picture
    /// kept; missing / empty / malformed lists read as nil or empty.
    @Test func suggested_keepsTheRelaysOrder_andIsEmptyWhenMissingOrMalformed() {
        let doc: [String: Any] = ["topics": ["suggested": [
            ["slug": "soups-stews", "label": "Soups & stews", "count_14d": 35],
            ["slug": "beer", "label": "Beer & brewing", "blurb": "Brewed, poured, shared.",
             "image": "https://img.example/beer.jpg", "count_14d": 11],
            ["slug": "tea", "label": "Tea"],
        ]]]
        #expect(FreshTopicCatalog.parseSuggested(doc) == [
            FreshSuggestedTopic(slug: "soups-stews", label: "Soups & stews", count14d: 35),
            FreshSuggestedTopic(slug: "beer", label: "Beer & brewing", blurb: "Brewed, poured, shared.",
                                image: "https://img.example/beer.jpg", count14d: 11),
            FreshSuggestedTopic(slug: "tea", label: "Tea", count14d: 0),
        ])
        #expect(FreshTopicCatalog.parseSuggested(nil) == nil)
        #expect(FreshTopicCatalog.parseSuggested(["topics": ["suggested": [Any]()]]) == [])
        #expect(FreshTopicCatalog.parseSuggested(["topics": ["suggested": "x"]]) == nil)
    }

    // MARK: iOS-only: the measured NIP-11 shape (build spec §2)

    @Test func parsesTheMeasuredDocument_includingImagePost() throws {
        let post = String(repeating: "ab", count: 32)
        let json = """
        {"name":"feed.zap.cooking","limitation":{"max_limit":500,"auth_required":false},
         "topics":{"namespace":"cooking.zap.topic",
          "parents":[{"slug":"preserving","name":"Preserving","count_14d":0,
            "topics":[{"slug":"sauerkraut","name":"Sauerkraut","count_14d":0},{"slug":"canning","name":"Canning","count_14d":0}]}],
          "featured_topics":[{"slug":"meat-seafood","label":"Meat"},{"slug":"pasta","label":"Pasta"}],
          "suggested":[{"slug":"pasta","label":"Pasta","blurb":"Noodles.","count_14d":12,
            "image":"https://blossom.example/x.jpg","image_post":"\(post)"},
            {"slug":"tea","label":"Tea","image_post":"not-an-id"}]}}
        """
        let catalog = FreshTopicCatalog.parse(nip11: Data(json.utf8))
        #expect(catalog.groups.map(\.slug) == ["preserving"])
        #expect(catalog.groups.first?.topics.map(\.count14d) == [0, 0])
        #expect(catalog.featured?.map(\.slug) == ["meat-seafood", "pasta"])
        let suggested = try #require(catalog.suggested)
        #expect(suggested[0].imagePost == post)
        #expect(suggested[0].count14d == 12)
        #expect(suggested[1].imagePost == nil)
    }
}
