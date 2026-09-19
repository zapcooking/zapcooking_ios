import Foundation

/// Composing a kind-1 note from the OnlyFood tab.
///
/// OnlyFood reads kind-1 over the ``FoodHashtags`` `#t` filter, so a note
/// composed there without a food hashtag never comes back into the feed
/// the author just posted to. Neither Android nor web solves this: both
/// open a hashtag-agnostic composer and accept the dead end.
///
/// C-H closed it with a visible `#foodstr` prefill. That put a tag into
/// every note automatically, so it is gone: **nothing is added to a note
/// unless the user taps.** The OnlyFood composer instead shows a row of
/// suggestion pills (`HashtagSuggestionRow`) under the editor. A tap
/// appends the hashtag to the body; a second tap removes it. The body
/// stays the single source of truth — the composer's ordinary hashtag
/// derivation turns it into the chips and the `t` tags — so the pills,
/// the chips, the tags and the §7.3 structural cap all agree.
///
/// The cap (`OnlyFoodFilter.maxHashtags`, counted as the filter counts it)
/// is enforced here: once the note carries the maximum, unselected pills
/// are disabled, and the row shows the count. Typing past it by hand is
/// flagged, not prevented. Publishing from OnlyFood with no tag from the
/// food set raises a confirm (`needsFoodTagConfirm`) whose "Add #foodstr"
/// is itself a tap.
nonisolated enum OnlyFoodCompose {
    /// First entry of `FoodHashtags.all` on all three platforms and the
    /// community's canonical food tag. The confirm's one-tap fix.
    static let defaultTag = "foodstr"

    /// The pills, in order. Every entry is in `FoodHashtags.allSet` (tested),
    /// so a single tapped pill is enough to reach OnlyFood. Chosen from a
    /// 60-day kind-1 count per tag on the OnlyFood relays (2026-09-19,
    /// nos.lol / relay.primal.net, limit 500): foodstr 500/22, food 331/500,
    /// coffee 157/188, cooking 38/0, breakfast 35/2, dinner 20/64, cookstr
    /// 7/1, lunch 7/0. `cookstr` and `lunch` are thin but are the
    /// community's own tags. `#gratitude` was proposed and is deliberately
    /// absent: it is not a food tag, so a note carrying only it would still
    /// dead-end.
    static let suggestedTags: [String] = [
        "foodstr", "food", "cooking", "cookstr", "breakfast", "lunch", "dinner", "coffee",
    ]

    static let hint = "Tap a tag so this shows up in OnlyFood."
    static let placeholder = "What are you cooking?"

    /// The structural cap, from the filter that applies it.
    static var maxTags: Int { OnlyFoodFilter.maxHashtags }

    /// The hashtag count exactly as `OnlyFoodFilter.isStructuralSpam` sees a
    /// note built from this body: `max(content #tags, t-tags)`. The content
    /// side counts every occurrence, so a duplicate typed tag is not free.
    static func tagCount(content: String, hashtags: [String]) -> Int {
        max(OnlyFoodFilter.countContentHashtags(content), hashtags.count)
    }

    static func atCap(content: String, hashtags: [String]) -> Bool {
        tagCount(content: content, hashtags: hashtags) >= maxTags
    }

    static func overCap(content: String, hashtags: [String]) -> Bool {
        tagCount(content: content, hashtags: hashtags) > maxTags
    }

    /// True when at least one derived hashtag is in the food set — the
    /// same test the feed's own-publish insert applies.
    static func reachesOnlyFood(hashtags: [String]) -> Bool {
        hashtags.contains { FoodHashtags.allSet.contains($0.lowercased()) }
    }

    // MARK: - Body edits (pure)

    /// Append `#tag` to the body. Tags gather on a trailing tag line: if the
    /// last non-blank line is only hashtags, the tag joins it; otherwise it
    /// starts a new paragraph. Trailing whitespace is dropped first so the
    /// result is deterministic.
    static func appending(tag: String, to content: String) -> String {
        let body = trimmingTrailingWhitespace(content)
        if body.isEmpty { return "#\(tag)" }
        let lastLine = body.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if isHashtagLine(lastLine) { return body + " #\(tag)" }
        return body + "\n\n#\(tag)"
    }

    /// Remove every `#tag` token (case-insensitive, whole token) from the
    /// body and tidy the whitespace it leaves behind.
    static func removing(tag: String, from content: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}_])#" + NSRegularExpression.escapedPattern(for: tag) + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return content }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var out = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "")
        // A removed token leaves a double space, a space against a newline,
        // or a space at the very start.
        out = out.replacingOccurrences(of: "  ", with: " ")
        out = out.replacingOccurrences(of: " \n", with: "\n")
        out = out.replacingOccurrences(of: "\n ", with: "\n")
        while out.first == " " { out.removeFirst() }
        return trimmingTrailingWhitespace(out)
    }

    private static func isHashtagLine(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { $0.hasPrefix("#") && $0.count > 1 }
    }

    private static func trimmingTrailingWhitespace(_ s: String) -> String {
        var view = Substring(s)
        while let last = view.last, last.isWhitespace || last.isNewline { view.removeLast() }
        return String(view)
    }
}
