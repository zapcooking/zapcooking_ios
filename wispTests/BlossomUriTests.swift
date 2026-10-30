//
//  BlossomUriTests.swift
//  wispTests
//
//  Pins the BUD-10 `blossom:` reference parser — including the exact URI
//  shape seen in the field (note 000006b1… by 1ec454…, "This is a test of
//  BUD-10") — and the ContentParser classification that turns such a URI
//  into an image segment so the media pipeline can resolve and render it.
//

import Testing
@testable import wisp

struct BlossomUriTests {

    private static let fieldUri =
        "blossom:d819b922fbbf3a47e606dab12a6c316b9a0445ff4aa69d749d638ce83884cf1c.jpg" +
        "?xs=blossom.laantungir.net&xs=cdn.satellite.earth&xs=blossom.primal.net" +
        "&as=1ec454734dcbf6fe54901ce25c0c7c6bca5edd89443416761fadc321d38df139&sz=117475"

    @Test func parsesTheFieldUri() {
        let uri = BlossomUri.parse(Self.fieldUri)
        #expect(uri != nil)
        #expect(uri?.sha256 == "d819b922fbbf3a47e606dab12a6c316b9a0445ff4aa69d749d638ce83884cf1c")
        #expect(uri?.ext == "jpg")
        #expect(uri?.serverHints == ["blossom.laantungir.net", "cdn.satellite.earth", "blossom.primal.net"])
        #expect(uri?.authors == ["1ec454734dcbf6fe54901ce25c0c7c6bca5edd89443416761fadc321d38df139"])
        #expect(uri?.sizeBytes == 117475)
    }

    @Test func parsesBareHashWithNoExtensionOrQuery() {
        let uri = BlossomUri.parse("blossom:\(String(repeating: "a", count: 64))")
        #expect(uri?.sha256 == String(repeating: "a", count: 64))
        #expect(uri?.ext == nil)
        #expect(uri?.serverHints.isEmpty == true)
        #expect(uri?.sizeBytes == nil)
    }

    @Test func rejectsNonBlossomAndMalformedReferences() {
        #expect(BlossomUri.parse("https://cdn.satellite.earth/\(String(repeating: "a", count: 64)).jpg") == nil)
        #expect(BlossomUri.parse("blossom:xyz.jpg") == nil)
        #expect(BlossomUri.parse("blossom:") == nil)
        #expect(BlossomUri.parse("blossom:d819.jpg") == nil)
    }

    @Test func candidateUrlsUseTheBareHashOnHttps() {
        let uri = BlossomUri.parse(Self.fieldUri)!
        #expect(
            uri.candidateUrls("blossom.laantungir.net")
                == "https://blossom.laantungir.net/d819b922fbbf3a47e606dab12a6c316b9a0445ff4aa69d749d638ce83884cf1c"
        )
        // A hint that already carries a scheme is used as-is; trailing slashes are trimmed.
        #expect(
            uri.candidateUrls("https://cdn.satellite.earth/")
                == "https://cdn.satellite.earth/d819b922fbbf3a47e606dab12a6c316b9a0445ff4aa69d749d638ce83884cf1c"
        )
    }

    @Test func contentParserClassifiesTheFieldUriAsAnImage() {
        let segments = ContentParser.parse(content: Self.fieldUri, tags: [])
        var sawImage = false
        for segment in segments {
            if case .image(let meta) = segment {
                sawImage = true
                // Trailing sentence punctuation is trimmed; the query rides along.
                #expect(meta.url.hasSuffix("sz=117475"))
                #expect(meta.url.hasPrefix("blossom:"))
            }
        }
        #expect(sawImage)
    }

    @Test func contentParserTrimsTrailingSentencePeriod() {
        let content = Self.fieldUri + "."
        let segments = ContentParser.parse(content: content, tags: [])
        for segment in segments {
            if case .image(let meta) = segment {
                #expect(meta.url.hasSuffix("sz=117475"))
                return
            }
        }
        Issue.record("expected an image segment")
    }
}
