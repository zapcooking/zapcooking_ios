import Foundation
import Observation

/// Process-wide cache of splash food-photo URLs, harvested from `#foodstr`
/// notes and kind-30023 recipes. Mirrors Android's `SplashViewModel`, but the
/// fetch is decoupled from the splash view: `warmIfNeeded()` is called at app
/// launch (see `ContentView`) so the 24h cache is fresh whenever the splash
/// shows — even on a fast login — and `SplashViewModel` just reads it.
actor FoodPhotoCache {
    static let shared = FoodPhotoCache()

    private static let urlsKey = "splash_food_photos_v2"
    private static let tsKey = "splash_food_photos_ts_v2"
    private static let ttl: TimeInterval = 24 * 60 * 60

    /// UserDefaults read — callable without awaiting the actor. Falls back to
    /// the bundled photo set when the cache is empty so the splash is never
    /// blank on a cold first launch.
    nonisolated static func current() -> [String] {
        let raw = UserDefaults.standard.string(forKey: urlsKey) ?? ""
        let cached = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return cached.isEmpty ? SplashFoodFallback.urls : cached
    }

    /// Refresh the cache if it's empty or stale. Serialized by the actor, so
    /// concurrent callers (app-launch warm + splash view) don't double-fetch:
    /// the first fetches + writes, the rest see the fresh cache and return.
    func warmIfNeeded() async {
        let empty = Self.current().isEmpty
        let stale = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: Self.tsKey) > Self.ttl
        guard empty || stale else { return }
        let picked = await Self.fetch()
        guard !picked.isEmpty else { return }
        UserDefaults.standard.set(picked.joined(separator: "\n"), forKey: Self.urlsKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.tsKey)
    }

    // MARK: - Fetch (two sources, fanned out concurrently)

    private struct Candidate: Sendable { let url: String; let pubkey: String }

    private static let foodstrRelays = [
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.nostr.net",
    ]
    /// Recipes (kind-30023) always carry a cover photo — reliable food imagery.
    private static let articleRelays = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://eden.nostr.land",
    ]
    private static let roundTimeout: TimeInterval = 3
    private static let maxPerAuthor = 3
    private static let targetPhotos = 80
    // `##"…"##` because each filter JSON contains `"#t` (a `"#` that closes `#"…"#`).
    private static let foodstrFilter = ##"{"kinds":[1],"#t":["foodstr"],"limit":300}"##
    private static let recipeFilter = ##"{"kinds":[30023],"#t":["zapcooking","nostrcooking"],"limit":150}"##

    private static let imageURLRegex = try? NSRegularExpression(
        pattern: #"https?://\S+\.(?:jpg|jpeg|png)(?:[?#]\S*)?"#,
        options: .caseInsensitive
    )

    private static func fetch() async -> [String] {
        let jobs: [(relay: String, filter: String)] =
            foodstrRelays.map { ($0, foodstrFilter) } +
            articleRelays.map { ($0, recipeFilter) }
        let batches = await withTaskGroup(of: [Candidate].self, returning: [Candidate].self) { group in
            for job in jobs {
                group.addTask { await collect(from: job.relay, filter: job.filter) }
            }
            var all: [Candidate] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
        guard !batches.isEmpty else { return [] }

        // Dedup by URL, cap per author (≤3), first-seen order.
        var seen = Set<String>()
        var perAuthor: [String: Int] = [:]
        var picked: [String] = []
        for c in batches {
            guard seen.insert(c.url).inserted else { continue }
            let count = perAuthor[c.pubkey, default: 0]
            guard count < maxPerAuthor else { continue }
            perAuthor[c.pubkey] = count + 1
            picked.append(c.url)
            if picked.count >= targetPhotos { break }
        }
        return picked
    }

    /// Open one relay, REQ the filter, harvest image URLs from content +
    /// imeta/image tags. Single round, deadline-bounded.
    private nonisolated static func collect(from relayURL: String, filter: String) async -> [Candidate] {
        guard let url = URL(string: relayURL) else { return [] }
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        // `##"…"##`: the embedded `filter` contains `"#t`, whose `"#` closes `#"…"#`.
        let req = ##"["REQ","splash_food",\##(filter)]"##
        try? await ws.send(.string(req))

        var out: [Candidate] = []
        let deadline = Date().addingTimeInterval(roundTimeout)
        var eoseGrace: Date?

        while Date() < deadline {
            if let grace = eoseGrace, Date() >= grace { break }
            do {
                let message = try await ws.receive()
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      let type = arr.first as? String else { continue }

                if type == "EVENT", arr.count >= 3,
                   let event = arr[2] as? [String: Any] {
                    let pubkey = (event["pubkey"] as? String) ?? ""
                    for u in extractImageUrls(from: event) {
                        out.append(Candidate(url: u, pubkey: pubkey))
                    }
                } else if type == "EOSE", eoseGrace == nil {
                    eoseGrace = Date().addingTimeInterval(0.5)
                }
            } catch {
                break
            }
        }
        return out
    }

    private nonisolated static func extractImageUrls(from event: [String: Any]) -> [String] {
        var urls: [String] = []
        if let tags = event["tags"] as? [[Any]] {
            for tag in tags {
                guard let key = tag.first as? String, key == "imeta" || key == "image" else { continue }
                for v in tag.dropFirst() {
                    guard let s = v as? String else { continue }
                    let cleaned = s.hasPrefix("url ") ? String(s.dropFirst(4)) : s
                    if matchesImage(cleaned) { urls.append(cleaned); break }
                }
            }
        }
        if let content = event["content"] as? String, let regex = imageURLRegex {
            let ns = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            for m in matches { urls.append(ns.substring(with: m.range)) }
        }
        return urls
    }

    private nonisolated static func matchesImage(_ s: String) -> Bool {
        imageURLRegex?.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }
}

/// Thin observer for the splash view: reads the shared cache instantly, then
/// refreshes it in the background so newly-fetched photos appear.
@Observable
@MainActor
final class SplashViewModel {
    var foodPhotos: [String] = []

    init() {
        foodPhotos = FoodPhotoCache.current()
        Task {
            await FoodPhotoCache.shared.warmIfNeeded()
            foodPhotos = FoodPhotoCache.current()
        }
    }
}
