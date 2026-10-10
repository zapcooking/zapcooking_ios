import Foundation
import UIKit

/// GIF search against gifs.nostr.build, nostr.build's GIF index.
///
/// Ported from the web composer (itself ported from Sidecar, the reference
/// implementation of this picker). The web app proxies requests through its
/// server because a key shipped in a browser bundle is public; the
/// gifs.nostr.build guide reserves `Authorization` headers for server and
/// native clients, and this is a native client — so the key is bundled here
/// (gitignored resource, see `GifsNostrBuildConfig`) and requests go to the
/// API directly.
///
/// Every result is already hosted on a Nostr media host (image.nostr.build),
/// so picking a GIF attaches its URL and nothing is uploaded. The URL goes
/// into a published note, so results that cannot be published as-is (http
/// links, mp4 renditions, unknown shapes) are dropped rather than shown.
enum GifSearch {
    static let apiBase = URL(string: "https://gifs.nostr.build/api/v1")!

    static let pageSize = 24
    /// A query's list is at most 200 long, and the API rejects an offset past 199.
    static let lastOffset = 199
    static let queryMax = 500
    static let suggestLimit = 6
    /// The grid packs columns about this wide, two to five, shortest column first.
    static let columnWidth: CGFloat = 170
    /// Within this many points of the grid's bottom the next page loads.
    static let loadMoreMargin: CGFloat = 160

    /// There is no trending list to open on, so the picker opens on topic
    /// chips — search terms, not interface text: they are what the index is
    /// tagged with.
    static let topics = ["gm", "gn", "pv", "zap", "bitcoin", "coffee", "lfg", "wow"]

    /// The chips in the order the picker offers them: gm first through the
    /// day, gn first in the evening and overnight, by the device's own clock.
    /// Nothing is searched until one is tapped, so the clock only decides
    /// which comes first.
    static func topicsFor(now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let hour = calendar.component(.hour, from: now)
        let first = (hour >= 4 && hour < 18) ? "gm" : "gn"
        return [first] + topics.filter { $0 != first }
    }

    // MARK: - Requests

    static func clipQuery(_ query: String) -> String {
        String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(queryMax))
    }

    /// `safe=1` is the API's default, spelled out: adult GIFs stay out of a
    /// picker anyone can open.
    static func searchURL(query: String, offset: Int = 0) -> URL? {
        var components = URLComponents(url: apiBase.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: clipQuery(query)),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(max(offset, 0))),
            URLQueryItem(name: "safe", value: "1"),
        ]
        return components?.url
    }

    static func suggestURL(query: String) -> URL? {
        var components = URLComponents(url: apiBase.appendingPathComponent("suggest"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: clipQuery(query)),
            URLQueryItem(name: "limit", value: String(suggestLimit)),
            URLQueryItem(name: "safe", value: "1"),
        ]
        return components?.url
    }

    // MARK: - Parsing

    /// One result, or nil when it cannot be shown and posted as it is. The
    /// URL goes into a published note, so it has to be an https link in one
    /// of the two formats the index serves. The grid shows the w240 preview,
    /// the size the API documents for column grids, animated when it can be
    /// and its first frame when the GIF is too big to animate.
    static func gif(fromItem item: Any?) -> Gif? {
        guard let it = item as? [String: Any] else { return nil }
        guard let url = it["url"] as? String, isHTTPS(url) else { return nil }
        guard let format = it["format"] as? String, format == "gif" || format == "webp" else { return nil }
        let previews = it["previews"] as? [String: Any]
        let rendition = previews?["w240"] as? [String: Any] ?? previews?["medium"] as? [String: Any]
        let preview = rendition.flatMap { rendition in
            [rendition["animated"], rendition["still"]].compactMap { $0 as? String }.first(where: isHTTPS)
        }
        guard let preview,
              let width = toNumber(it["width"]), width > 0,
              let height = toNumber(it["height"]), height > 0 else { return nil }
        let title = (it["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Gif(url: url, preview: preview, width: width, height: height, title: title, format: format)
    }

    /// A page of results, and the offset of the next page or nil at the end.
    /// `count` is the length of the query's whole list — and the offset counts
    /// every item the API sent, shown or not, or the next page repeats one —
    /// so paging stops at count or at the API's last offset, whichever comes
    /// first.
    static func parsePage(_ body: Any?) -> GifPage {
        let obj = body as? [String: Any]
        let items = obj?["items"] as? [Any] ?? []
        let offset = toNumber(obj?["offset"]).map(Int.init) ?? 0
        let count = toNumber(obj?["count"]).map(Int.init) ?? 0
        let gifs = items.compactMap(gif(fromItem:))
        let next = offset + items.count
        return GifPage(
            gifs: gifs,
            next: items.isEmpty ? nil : (next < count && next <= lastOffset ? next : nil)
        )
    }

    static func parseSuggestions(_ body: Any?) -> [String] {
        let terms = (body as? [String: Any])?["terms"] as? [Any] ?? []
        var out: [String] = []
        for entry in terms {
            guard let term = (entry as? [String: Any])?["term"] as? String else { continue }
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !out.contains(trimmed) { out.append(trimmed) }
        }
        return Array(out.prefix(suggestLimit))
    }

    /// What the picker says when a request fails. 401 and 403 are the API
    /// refusing the key and 503 is search being down or unconfigured —
    /// nothing anyone at the keyboard can fix, so it says so rather than
    /// suggesting a retry.
    static func errorMessage(forStatus status: Int) -> String {
        switch status {
        case 401, 403, 503:
            return "GIF search isn’t available right now."
        case 429:
            return "Too many searches. Try again in a minute."
        default:
            return "Couldn’t load GIFs. Check your connection and try again."
        }
    }

    // MARK: - Paging

    /// Whether the grid should load its next page now.
    static func shouldLoadMore(loading: Bool, nextOffset: Int?, scrollTop: CGFloat, clientHeight: CGFloat, scrollHeight: CGFloat) -> Bool {
        if loading || nextOffset == nil { return false }
        return scrollTop + clientHeight >= scrollHeight - loadMoreMargin
    }

    /// Whether a page moved the cursor forward. The picker re-checks the
    /// bottom only then, so a page of duplicates (which doesn't grow the
    /// grid and so fires no new appearance) can't stall paging, and a cursor
    /// that doesn't move can't loop.
    static func pageAdvanced(_ offset: Int, _ next: Int?) -> Bool {
        guard let next else { return false }
        return next > offset
    }

    // MARK: - JSON helpers

    /// `https://` plus at least one non-whitespace character, and no
    /// whitespace anywhere in the rest — the shape a published note's link
    /// must have (`http:`, `javascript:` and half-written URLs fail).
    static func isHTTPS(_ url: String) -> Bool {
        let rest = url.dropFirst("https://".count)
        guard url.hasPrefix("https://"), !rest.isEmpty else { return false }
        return rest.allSatisfy { !$0.isWhitespace }
    }

    /// Numbers come back as NSNumber but junk as strings/bools/null; only a
    /// real number (or a string holding one) has a width to lay out with.
    static func toNumber(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        case let s as String:
            return Double(s)
        default:
            return nil
        }
    }
}

/// One publishable search result, deduplicated by `url`.
struct Gif: Hashable, Identifiable {
    let url: String
    /// The w240 (or medium) preview URL the grid shows.
    let preview: String
    let width: Double
    let height: Double
    /// The GIF's own title, seeded as the attachment's alt description.
    let title: String
    let format: String

    var id: String { url }

    var mime: String { format == "webp" ? "image/webp" : "image/gif" }

    var previewURL: URL? { URL(string: preview) }
}

struct GifPage {
    let gifs: [Gif]
    let next: Int?
}

/// API key for gifs.nostr.build, read from a bundled resource
/// (`wisp/Resources/gifs-nostr-build-api-key.txt`, gitignored — copy the
/// `.example` sibling and paste the key of the registered "zapcooking-ios"
/// client from the gifs.nostr.build dashboard). Empty when unconfigured: the
/// picker still opens and maps the API's 401/403 to "search isn't available".
enum GifsNostrBuildConfig {
    static let apiKey: String = {
        guard let url = Bundle.main.url(forResource: "gifs-nostr-build-api-key", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed
    }()
}

enum GifSearchError: Error {
    /// Search failed; `message` is already what the picker should say.
    case failed(message: String)

    var message: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// One-shot GETs against gifs.nostr.build with the Bearer key, an 8-second
/// timeout, and Task-cancellation-aware aborts. Status errors surface as
/// `GifSearchError.failed` carrying `GifSearch.errorMessage` so the picker
/// never shows a raw HTTP code.
struct GifSearchClient {
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    func search(query: String, offset: Int = 0) async throws -> GifPage {
        guard let url = GifSearch.searchURL(query: query, offset: offset) else {
            throw GifSearchError.failed(message: GifSearch.errorMessage(forStatus: 0))
        }
        return GifSearch.parsePage(try await get(url))
    }

    func suggest(query: String) async throws -> [String] {
        guard let url = GifSearch.suggestURL(query: query) else { return [] }
        return GifSearch.parseSuggestions(try await get(url))
    }

    private func get(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !GifsNostrBuildConfig.apiKey.isEmpty {
            request.setValue("Bearer \(GifsNostrBuildConfig.apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw GifSearchError.failed(message: GifSearch.errorMessage(forStatus: status))
            }
            return try JSONSerialization.jsonObject(with: data)
        } catch let error as GifSearchError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession reports Swift-level cancellation as URLError; surface
            // it as CancellationError so callers can tell "superseded" from
            // "the network is down".
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GifSearchError.failed(message: GifSearch.errorMessage(forStatus: 0))
        }
    }
}
