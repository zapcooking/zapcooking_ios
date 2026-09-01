import Foundation
import Testing
@testable import wisp

/// Pinned public pantry REQ. Fails if anyone changes authors/kinds or adds a tag.
struct NourishFilterShapeTests {
    private let service =
        "fdd263f69f9e95a2a0a58ec3e7e8053011214fa66007d93b26d2f4717d31917b"

    @Test func publicCorpus_authorsAndKindsArePinned() {
        let filter = NourishFilter.publicCorpus
        #expect(filter.kinds == [30078])
        #expect(filter.authors == [service])
        #expect(filter.authors?.count == 1)
        #expect(NourishFilter.encodedKeys(filter) == ["kinds", "authors", "limit"])
    }

    @Test func publicCorpus_hasNoTagFilters() {
        let keys = NourishFilter.encodedKeys(NourishFilter.publicCorpus)
        #expect(!keys.contains("#d"))
        #expect(!keys.contains("#l"))
        #expect(!keys.contains("#t"))
        #expect(!keys.contains("#e"))
        #expect(!keys.contains("#p"))
        #expect(!keys.contains("#a"))
        #expect(!keys.contains("#h"))
        #expect(!keys.contains("#q"))
        #expect(NourishFilter.publicCorpus.dTags == nil)
        #expect(NourishFilter.publicCorpus.lTags == nil)
    }

    @Test func addingATag_changesEncodedKeys() {
        var extra = NourishFilter.publicCorpus
        extra.dTags = ["nourish:30023:x:y"]
        #expect(NourishFilter.encodedKeys(extra).contains("#d"))
        #expect(NourishFilter.encodedKeys(extra) != NourishFilter.encodedKeys(NourishFilter.publicCorpus))
    }

    @Test func recipeScore_keepsAuthorsAndKinds_addsD() {
        let filter = NourishFilter.recipeScore(author: "abc", dTag: "stew")
        #expect(filter.kinds == [30078])
        #expect(filter.authors == [service])
        #expect(filter.dTags == ["nourish:30023:abc:stew"])
        #expect(NourishFilter.encodedKeys(filter).isSuperset(of: ["kinds", "authors", "#d"]))
    }

    @Test func labeled_keepsAuthorsAndKinds_addsL() {
        let filter = NourishFilter.labeled("protein:30plus")
        #expect(filter.kinds == [30078])
        #expect(filter.authors == [service])
        #expect(filter.lTags == ["protein:30plus"])
        #expect(NourishFilter.encodedKeys(filter).contains("#l"))
    }

    @Test func unfilteredExplore_isPublicCorpus() {
        let filter = NourishDiscovery.buildNourishAnalysisFilter()
        #expect(filter.kinds == NourishFilter.publicCorpus.kinds)
        #expect(filter.authors == NourishFilter.publicCorpus.authors)
        #expect(filter.limit == NourishFilter.publicCorpus.limit)
        #expect(filter.lTags == nil)
        #expect(NourishFilter.encodedKeys(filter) == ["kinds", "authors", "limit"])
    }
}
