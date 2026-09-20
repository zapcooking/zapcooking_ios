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

    /// The pills, in order — the same set in the same order on web
    /// (`hashtagPills.ts`), iOS and Android (#84): with a scrolling row the
    /// order is the design, and the same person should not see a different
    /// menu per device. Every entry is in `FoodHashtags.allSet` (tested), so
    /// a single tapped pill is enough to reach OnlyFood. The set came from a
    /// 60-day kind-1 count per tag on the OnlyFood relays (2026-09-19,
    /// nos.lol / relay.primal.net, limit 500): foodstr 500/22, food 331/500,
    /// coffee 157/188, cooking 38/0, breakfast 35/2, dinner 20/64, cookstr
    /// 7/1, lunch 7/0. `foodstr` leads as the canonical community tag, then
    /// the specific tags people reach for; `food` goes last despite its
    /// count because next to `foodstr` it reads as the same choice twice.
    /// `cookstr` and `lunch` are thin but are the community's own tags.
    /// `#gratitude` was proposed and is deliberately absent: it is not a
    /// food tag, so a note carrying only it would still dead-end.
    static let suggestedTags: [String] = [
        defaultTag, "coffee", "cooking", "breakfast", "dinner", "lunch", "cookstr", "food",
    ]

    static let hint = "Tap a tag so this shows up in OnlyFood."

    // MARK: - The row's order and the picker's set

    /// The row's candidate order: every food tag already in the body
    /// (`bodyTags`, the composer's derived hashtags in body order) comes
    /// first, so a tag picked from the full set or typed by hand is never
    /// hidden behind the "+"; then the suggested tags that are not yet
    /// selected, in their measured-usage order.
    static func rowOrder(bodyTags: [String], suggested: [String]) -> [String] {
        let selected = bodyTags.filter { FoodHashtags.allSet.contains($0) }
        let rest = suggested.filter { !selected.contains($0) }
        return selected + rest
    }

    /// The picker's first section: the eight pills, in order.
    static var pickerPopular: [String] { suggestedTags }

    /// The picker's second section: every other food tag the OnlyFood
    /// filter matches on, alphabetical. `FoodHashtags.all` backs the
    /// picker (not `FoodTopics`): a tag from this list is what makes a
    /// note reachable in OnlyFood, and 66 of the taxonomy's tags are not
    /// in it.
    static let pickerRest: [String] = {
        let popular = Set(suggestedTags)
        return FoodHashtags.all.map { $0.lowercased() }
            .filter { !popular.contains($0) }
            .sorted()
    }()

    /// Search: a leading "#" is ignored, matching is case-insensitive and
    /// by substring. Empty query returns `tags` unchanged.
    static func pickerMatches(_ tags: [String], query: String) -> [String] {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while q.hasPrefix("#") { q.removeFirst() }
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.contains(q) }
    }

    /// One row, one "+": how many leading entries of the ordered row fit
    /// in `available` points, and how many *selected* entries fall past
    /// the cut. The "+" widens to "+N" when N selected tags are hidden,
    /// which can push one more entry out, so the pair is iterated to a
    /// fixed point (it converges in a step or two: N only grows).
    static func rowLayout(
        widths: [CGFloat], selected: [Bool], plusWidth: (Int) -> CGFloat,
        spacing: CGFloat, available: CGFloat
    ) -> (count: Int, hiddenSelected: Int) {
        let selectedTotal = selected.filter { $0 }.count
        var hidden = 0
        var count = 0
        for _ in 0..<4 {
            count = visiblePillCount(
                widths: widths, plusWidth: plusWidth(hidden), spacing: spacing, available: available
            )
            let shown = selected.prefix(count).filter { $0 }.count
            let next = selectedTotal - shown
            if next == hidden { break }
            hidden = next
        }
        return (count, hidden)
    }

    /// How many leading pills fit on one row of `available` points, keeping
    /// room for the trailing "+" pill. The row neither wraps nor scrolls:
    /// the pills are the head of `suggestedTags` and the "+" opens the
    /// full set. `widths` are the pills' measured widths in order.
    static func visiblePillCount(
        widths: [CGFloat], plusWidth: CGFloat, spacing: CGFloat, available: CGFloat
    ) -> Int {
        var used = plusWidth
        var count = 0
        for width in widths {
            let next = used + spacing + width
            if next > available { break }
            used = next
            count += 1
        }
        return count
    }
    static let placeholder = "What are you cooking?"

    /// The "No food tag yet" confirm's message. Under the cap the one-tap
    /// fix is offered; at or over it the message says how many tags the
    /// note really has (`count`, which can exceed the cap when typed) and
    /// how many to remove so `#foodstr` fits.
    static func noFoodTagMessage(count: Int) -> String {
        let base = "This note won't appear in OnlyFood without a food tag"
        guard count >= maxTags else { return base + "." }
        let toRemove = count - maxTags + 1
        let remove = toRemove == 1 ? "Remove one" : "Remove \(toRemove)"
        return base + ", and it already has \(count) tags. \(remove) to add #\(defaultTag)."
    }

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
        // A removed token leaves a run of spaces, a space against a newline,
        // or a space at the very start. Collapse runs until stable: one pass
        // turns three spaces into two.
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.replacingOccurrences(of: " \n", with: "\n")
        out = out.replacingOccurrences(of: "\n ", with: "\n")
        while out.first == " " { out.removeFirst() }
        return trimmingTrailingWhitespace(out)
    }

    /// A line made only of hashtag tokens as the composer derives them
    /// (`#` plus 1–64 letters / digits / underscores). `#foodstr,` is not
    /// one, so a pill after it starts a new paragraph instead of joining
    /// the punctuation.
    private static func isHashtagLine(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { $0.wholeMatch(of: hashtagTokenRegex) != nil }
    }

    private static let hashtagTokenRegex = /#[\p{L}\p{N}_]{1,64}/

    private static func trimmingTrailingWhitespace(_ s: String) -> String {
        var view = Substring(s)
        while let last = view.last, last.isWhitespace || last.isNewline { view.removeLast() }
        return String(view)
    }
}
