import Foundation

/// The feed relay's topic catalog, from its NIP-11 document (`topics`),
/// ported from web `src/lib/freshFeed/topicList.ts` (parsing; the GET and
/// its cache are `FreshTopicList`). Used by the spotlight cards; v1 has no
/// topic chip row and no topic screen.
///
/// Shape as measured (build spec §2 "Fresh feed relay", NIP-11): `parents[]`
/// groups `{slug, name, count_14d, topics[]}`, `featured_topics[]`
/// `{slug, label}`, `suggested[]` `{slug, label, blurb, count_14d, image,
/// image_post}`.
///
/// ≠ web: `image_post` (the event id the suggested topic's picture came
/// from) is kept as `imagePost` when it is a 64-char hex id; web drops it.
nonisolated struct FreshTopic: Equatable, Sendable {
    let slug: String
    let name: String
    /// Posts in the last 14 days (0 when the relay doesn't say).
    let count14d: Int
}

nonisolated struct FreshTopicGroup: Equatable, Sendable {
    let slug: String
    let name: String
    let count14d: Int
    let topics: [FreshTopic]
}

nonisolated struct FreshFeaturedTopic: Equatable, Sendable {
    let slug: String
    let label: String
}

nonisolated struct FreshSuggestedTopic: Equatable, Sendable {
    let slug: String
    let label: String
    /// The admins' one-liner, when the list has one.
    var blurb: String? = nil
    /// A picture for the topic (http/https), when the list has one.
    var image: String? = nil
    /// The event id the picture came from, when the list names one.
    var imagePost: String? = nil
    let count14d: Int

    init(slug: String, label: String, blurb: String? = nil, image: String? = nil,
         imagePost: String? = nil, count14d: Int) {
        self.slug = slug
        self.label = label
        self.blurb = blurb
        self.image = image
        self.imagePost = imagePost
        self.count14d = count14d
    }
}

nonisolated struct FreshTopicCatalog: Equatable, Sendable {
    let groups: [FreshTopicGroup]
    /// nil when the relay doesn't publish it.
    let featured: [FreshFeaturedTopic]?
    /// nil when the relay doesn't publish it.
    let suggested: [FreshSuggestedTopic]?

    static let empty = FreshTopicCatalog(groups: [], featured: nil, suggested: nil)

    /// The whole catalog from a NIP-11 JSON body; `.empty` when it isn't JSON.
    static func parse(nip11 data: Data) -> FreshTopicCatalog {
        guard let doc = try? JSONSerialization.jsonObject(with: data) else { return .empty }
        return parse(doc: doc)
    }

    static func parse(doc: Any?) -> FreshTopicCatalog {
        FreshTopicCatalog(groups: parseTopics(doc), featured: parseFeatured(doc), suggested: parseSuggested(doc))
    }

    /// The relay's HTTP URL for NIP-11 (wss:// → https://, ws:// → http://).
    static func nip11Url(_ relayUrl: String = FeedRelay.url) -> String {
        if relayUrl.hasPrefix("wss://") { return "https://" + relayUrl.dropFirst(6) }
        if relayUrl.hasPrefix("ws://") { return "http://" + relayUrl.dropFirst(5) }
        return relayUrl
    }

    // MARK: - Parsing

    /// `topics.parents`, validated; [] when absent or malformed. A group with
    /// no valid topics is dropped.
    static func parseTopics(_ doc: Any?) -> [FreshTopicGroup] {
        guard let parents = topics(doc)?["parents"] as? [Any] else { return [] }
        var out: [FreshTopicGroup] = []
        for p in parents {
            guard let p = p as? [String: Any], let (slug, name) = okTopic(p) else { continue }
            let topics = (p["topics"] as? [Any] ?? []).compactMap { raw -> FreshTopic? in
                guard let t = raw as? [String: Any], let (s, n) = okTopic(t) else { return nil }
                return FreshTopic(slug: s, name: n, count14d: count(t["count_14d"]))
            }
            if topics.isEmpty { continue }
            out.append(FreshTopicGroup(slug: slug, name: name, count14d: count(p["count_14d"]), topics: topics))
        }
        return out
    }

    /// `topics.featured_topics`, validated; nil when the relay doesn't publish it.
    static func parseFeatured(_ doc: Any?) -> [FreshFeaturedTopic]? {
        guard let list = topics(doc)?["featured_topics"] as? [Any] else { return nil }
        return list.compactMap { raw in
            guard let x = raw as? [String: Any],
                  let slug = x["slug"] as? String, isSlug(slug),
                  let label = (x["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return nil }
            return FreshFeaturedTopic(slug: slug, label: label)
        }
    }

    /// `topics.suggested`, validated, in the relay's order; nil when the relay
    /// doesn't publish it. A slug listed twice keeps its first place.
    static func parseSuggested(_ doc: Any?) -> [FreshSuggestedTopic]? {
        guard let list = topics(doc)?["suggested"] as? [Any] else { return nil }
        var out: [FreshSuggestedTopic] = []
        for raw in list {
            guard let t = raw as? [String: Any],
                  let slug = t["slug"] as? String, isSlug(slug),
                  let label = (t["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty,
                  !out.contains(where: { $0.slug == slug }) else { continue }
            let blurb = (t["blurb"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let image = (t["image"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let imagePost = (t["image_post"] as? String)?.lowercased() ?? ""
            out.append(FreshSuggestedTopic(
                slug: slug,
                label: label,
                blurb: blurb.isEmpty ? nil : blurb,
                image: isWebImage(image) ? image : nil,
                imagePost: isEventId(imagePost) ? imagePost : nil,
                count14d: count(t["count_14d"])
            ))
        }
        return out
    }

    private static func topics(_ doc: Any?) -> [String: Any]? {
        (doc as? [String: Any])?["topics"] as? [String: Any]
    }

    private static func okTopic(_ t: [String: Any]) -> (String, String)? {
        guard let slug = t["slug"] as? String, isSlug(slug),
              let name = t["name"] as? String, !name.isEmpty else { return nil }
        return (slug, name)
    }

    /// `^[a-z0-9]+(-[a-z0-9]+)*$`
    static func isSlug(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("-"), !s.hasSuffix("-"), !s.contains("--") else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `^https?://\S+$` (web keeps only web pictures; `javascript:` etc. are dropped).
    private static func isWebImage(_ s: String) -> Bool {
        guard s.hasPrefix("https://") || s.hasPrefix("http://") else { return false }
        let rest = s.hasPrefix("https://") ? s.dropFirst(8) : s.dropFirst(7)
        return !rest.isEmpty && !rest.contains(where: { $0.isWhitespace })
    }

    private static func isEventId(_ s: String) -> Bool {
        s.count == 64 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Web `count()`: `Number(x)` finite and > 0, floored; anything else 0.
    /// ≠ web: a value too large for `Int` (`1e100`) is 0, not a trap.
    static func count(_ raw: Any?) -> Int {
        let n: Double
        switch raw {
        case let v as NSNumber:
            // JSON booleans arrive as NSNumber too; web's Number(true) is 1.
            n = v.doubleValue
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            n = Double(trimmed) ?? .nan
        default:
            return 0
        }
        guard n.isFinite, n > 0 else { return 0 }
        return Int(exactly: n.rounded(.down)) ?? 0
    }
}
