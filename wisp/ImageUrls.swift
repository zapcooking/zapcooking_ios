import Foundation

/// Shared image-URL detection — a **strict parity port of the web
/// `src/lib/imageUrls.ts`** (Android `cheffy/ImageUrls.kt` is the same port).
/// That module is the single source of truth: the `/api/zappy/note-review`
/// server validates incoming `imageUrl`s with the SAME code, so a detector
/// that is looser than web would surface a Cheffy trigger the server then
/// 400s, and one that is stricter would hide triggers web shows. Any
/// behavioral change must land in all three repos with mirrored tests
/// (`imageUrls.test.ts` ↔ `ImageUrlsTest.kt` ↔ `ImageUrlsTests`).
///
/// Deliberate consequences of parity (Android finding 0.5):
///  - `heic`/`heif` are NOT images here even though `ContentParser`
///    renders them — the server would reject them.
///  - Blossom-style bare-hash paths (64-hex, no extension) do NOT match
///    unless the host is on the rescue list — same as web.
///  - Only `https?://` tokens are extracted from note content; scheme-less
///    bare domains and `wss://` (which the renderer tokenizes) are ignored.
///
/// Hostnames are lowercased before the host match, as the browser `URL`
/// does. Invalid URLs are never images, exactly like web's
/// `try { new URL(url) } catch { return false }`.
nonisolated enum ImageUrls {

    // Verbatim from imageUrls.ts. Tested against the parsed path, so the
    // `(\?.*)?$` arm is vestigial (a path never contains `?`) — kept
    // byte-identical to the reference anyway.
    private static let imageExtensions = try! NSRegularExpression(
        pattern: #"\.(jpg|jpeg|png|gif|webp|svg|bmp|avif)(\?.*)?$"#,
        options: [.caseInsensitive]
    )

    // Bare https?:// URL matcher for raw note content. Trailing punctuation
    // that commonly follows a pasted URL in prose is stripped after the match.
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#)
    private static let trailingProsePunctuation = try! NSRegularExpression(pattern: #"[.,;:!?]+$"#)

    // Hosts that commonly serve images WITHOUT a file extension. This list
    // only rescues extensionless URLs — the extension test already admits
    // any host, so it is a detection heuristic, not a trust boundary (our
    // infra never fetches these URLs; OpenAI does).
    private static let extensionlessImageHosts = [
        "image.nostr.build",
        "imgur.com",
        "primal.b-cdn.net",
        "media.tenor.com",
        "i.ibb.co",
    ]

    /// Exact domain or subdomain-of match. Never substring — `imgur.com`
    /// must not match `imgur.com.evil.example` or `notimgur.com`.
    private static func matchesHost(_ hostname: String, _ domain: String) -> Bool {
        hostname == domain || hostname.hasSuffix("." + domain)
    }

    /// True when the URL plausibly points at an image: the path carries an
    /// image extension, or the host is a known image CDN whose URLs often
    /// omit one. Invalid URLs are never images.
    static func isImageUrl(_ url: String) -> Bool {
        guard let parsed = URLComponents(string: url),
              let rawHost = parsed.host, !rawHost.isEmpty else {
            return false
        }
        let hostname = rawHost.lowercased()
        // The percent-encoded path is the browser `pathname`: query and
        // fragment are excluded, so `photo.jpg#gallery` still matches.
        let pathname = parsed.percentEncodedPath
        let pathRange = NSRange(pathname.startIndex..., in: pathname)
        if imageExtensions.firstMatch(in: pathname, range: pathRange) != nil { return true }
        if extensionlessImageHosts.contains(where: { matchesHost(hostname, $0) }) { return true }
        if matchesHost(hostname, "nostr.build") && pathname.contains("/i/") { return true }
        // Nostr clients run imgproxy instances under their own domains
        // (imgproxy.iris.to, imgproxy.snort.social, …) — match the host
        // label, not a substring.
        if hostname.split(separator: ".").contains("imgproxy") { return true }
        return false
    }

    /// Filter candidate URLs down to image URLs, preserving first-occurrence
    /// order and deduplicating. Dedup is load-bearing on web for lightbox
    /// index math and here for the sheet's thumbnail picker.
    static func filterImageUrls(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for url in urls where !url.isEmpty && !seen.contains(url) && isImageUrl(url) {
            seen.insert(url)
            result.append(url)
        }
        return result
    }

    /// Extract image URLs from raw note content (kind-1 text), in order of
    /// appearance, deduplicated. Works on the raw string — no parser needed.
    static func extractImageUrls(_ content: String) -> [String] {
        if content.isEmpty { return [] }
        let nsContent = content as NSString
        let candidates = urlRegex
            .matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            .map { match -> String in
                let raw = nsContent.substring(with: match.range)
                let range = NSRange(raw.startIndex..., in: raw)
                return trailingProsePunctuation.stringByReplacingMatches(
                    in: raw, range: range, withTemplate: ""
                )
            }
        return filterImageUrls(candidates)
    }
}
