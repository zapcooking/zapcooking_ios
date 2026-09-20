import Foundation
import Testing
@testable import wisp

/// Parity suite for `ImageUrls` — mirrors the web `imageUrls.test.ts`
/// case-for-case, then pins each divergence from `ContentParser`'s
/// renderer-oriented detection (Android finding 0.5). The note-review
/// server validates image URLs with the same web module, so these tests
/// are the contract.
struct ImageUrlsTests {

    // MARK: isImageUrl (imageUrls.test.ts)

    @Test func acceptsExtensionBearingImageUrls() {
        #expect(ImageUrls.isImageUrl("https://example.com/dish.jpg"))
        #expect(ImageUrls.isImageUrl("https://example.com/dish.jpeg?w=800"))
        #expect(ImageUrls.isImageUrl("https://example.com/a/b/dish.WEBP"))
        #expect(ImageUrls.isImageUrl("https://example.com/dish.avif"))
    }

    @Test func acceptsKnownImageHostsWithoutAnExtension() {
        #expect(ImageUrls.isImageUrl("https://image.nostr.build/abc123"))
        #expect(ImageUrls.isImageUrl("https://nostr.build/i/abc123"))
        #expect(ImageUrls.isImageUrl("https://i.ibb.co/xyz/photo"))
        #expect(ImageUrls.isImageUrl("https://primal.b-cdn.net/media-cache?u=foo"))
    }

    @Test func rejectsNonImageUrls() {
        #expect(!ImageUrls.isImageUrl("https://example.com/recipe.html"))
        #expect(!ImageUrls.isImageUrl("https://example.com/video.mp4"))
        #expect(!ImageUrls.isImageUrl("https://nostr.build/blog/post"))
        // extension in query only — the path is what counts
        #expect(!ImageUrls.isImageUrl("https://example.com/page?img=x.jpg"))
    }

    @Test func rejectsInvalidUrls() {
        #expect(!ImageUrls.isImageUrl("not a url"))
        #expect(!ImageUrls.isImageUrl(""))
    }

    @Test func rejectsLookalikeHostsThatOnlyContainATrustedDomainAsASubstring() {
        #expect(!ImageUrls.isImageUrl("https://imgur.com.evil.example/abc"))
        #expect(!ImageUrls.isImageUrl("https://image.nostr.build.evil.example/abc"))
        #expect(!ImageUrls.isImageUrl("https://notimgur.com/abc"))
        #expect(!ImageUrls.isImageUrl("https://evil.example/imgur.com/abc"))
        #expect(!ImageUrls.isImageUrl("https://myimgproxyish.com/abc"))
    }

    @Test func stillAcceptsRealSubdomainsAndImgproxyInstances() {
        #expect(ImageUrls.isImageUrl("https://i.imgur.com/abc"))
        #expect(ImageUrls.isImageUrl("https://imgproxy.iris.to/foo/bar"))
    }

    // MARK: extractImageUrls

    @Test func extractsImageUrlsFromRawNoteContentInOrder() {
        let content = "made this tonight https://image.nostr.build/aaa.jpg and plated it https://example.com/b.png"
        #expect(ImageUrls.extractImageUrls(content) == ["https://image.nostr.build/aaa.jpg", "https://example.com/b.png"])
    }

    @Test func ignoresNonImageUrls() {
        #expect(ImageUrls.extractImageUrls("see https://zap.cooking/recipe/123 for the recipe").isEmpty)
    }

    @Test func deduplicatesRepeatedUrls() {
        let u = "https://example.com/x.jpg"
        #expect(ImageUrls.extractImageUrls("\(u) again \(u)") == [u])
    }

    @Test func stripsTrailingProsePunctuation() {
        #expect(ImageUrls.extractImageUrls("look: https://example.com/x.jpg!") == ["https://example.com/x.jpg"])
    }

    @Test func handlesEmptyAndImageFreeContent() {
        #expect(ImageUrls.extractImageUrls("").isEmpty)
        #expect(ImageUrls.extractImageUrls("no links here").isEmpty)
    }

    // MARK: filterImageUrls

    @Test func filtersDedupesAndPreservesFirstOccurrenceOrder() {
        let a = "https://example.com/a.jpg"
        let b = "https://example.com/b.png"
        #expect(ImageUrls.filterImageUrls([a, "https://example.com/page.html", b, a, ""]) == [a, b])
    }

    // MARK: Divergences from ContentParser — iOS matches web

    @Test func divergence1_heicAndHeifAreExcludedByDesign() {
        // ContentParser renders heic/heif; the note-review server (same web
        // module) rejects them — parity wins.
        #expect(!ImageUrls.isImageUrl("https://example.com/photo.heic"))
        #expect(!ImageUrls.isImageUrl("https://example.com/photo.heif"))
    }

    @Test func divergence1_webOnlyExtensionsAreAccepted() {
        // ContentParser's set is missing bmp; the web module has it.
        #expect(ImageUrls.isImageUrl("https://example.com/logo.svg"))
        #expect(ImageUrls.isImageUrl("https://example.com/scan.bmp"))
        #expect(ImageUrls.isImageUrl("https://example.com/dish.avif"))
    }

    @Test func divergence2_fragmentDoesNotDefeatTheExtensionCheck() {
        #expect(ImageUrls.isImageUrl("https://example.com/photo.jpg#gallery"))
    }

    @Test func divergence3_blossomBareHashPathsAreNotImages() {
        let hash = String(repeating: "a", count: 64)
        #expect(!ImageUrls.isImageUrl("https://blossom.example.com/\(hash)"))
        #expect(ImageUrls.extractImageUrls("stored at https://blossom.example.com/\(hash)").isEmpty)
    }

    @Test func divergence4_schemelessAndWebsocketTokensAreNotExtracted() {
        #expect(ImageUrls.extractImageUrls("see example.com/x.jpg").isEmpty)
        #expect(ImageUrls.extractImageUrls("wss://relay.example.com/x.jpg").isEmpty)
    }

    @Test func divergence5_uppercaseHostsAreNormalizedLikeTheBrowser() {
        #expect(ImageUrls.isImageUrl("https://IMGUR.COM/abc"))
        #expect(ImageUrls.isImageUrl("https://Image.Nostr.Build/abc123"))
    }
}
