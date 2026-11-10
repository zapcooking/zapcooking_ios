import Foundation

/// A Fresh row's identity for author spacing: the post's id and author.
nonisolated protocol FreshSpaceable {
    var spacingId: String { get }
    var spacingAuthor: String { get }
}

extension NostrEvent: FreshSpaceable {
    nonisolated var spacingId: String { id }
    nonisolated var spacingAuthor: String { pubkey }
}

/// Author spacing, ported from web `src/lib/freshFeed/spacing.ts`: one cook
/// posting several times in a row shouldn't fill the screen. A newly loaded
/// page is reordered so the same author doesn't appear twice within `gap`
/// consecutive posts where that's possible: a post that would be too close
/// is held back to the earliest slot far enough from the author's last post.
/// Posts already on screen never move; only the incoming page is reordered,
/// and only by deferring (a post is never moved up). A page that is all one
/// author keeps its order.
nonisolated enum FreshSpacing {
    static let authorGap = 3

    static func spaceAuthors<T: FreshSpaceable>(before: [T], incoming: [T], gap: Int = authorGap) -> [T] {
        let keep = max(gap - 1, 0)
        let recent = before.suffix(keep).map(\.spacingAuthor)
        var queue = incoming
        var out: [T] = []
        out.reserveCapacity(incoming.count)
        while !queue.isEmpty {
            let window = Array((recent + out.map(\.spacingAuthor)).suffix(keep))
            let i = queue.firstIndex { !window.contains($0.spacingAuthor) } ?? 0
            out.append(queue.remove(at: i))
        }
        return out
    }
}

/// Author spacing for a page that streams in (the first page), ported from
/// web `StreamSpacer`: each post is appended as it arrives unless it would sit
/// within `gap` of its author's last post; then it is held until another
/// author's post makes room. The page's end (EOSE) adds the held posts and
/// whatever the final page has that didn't stream, spaced the same way, at
/// the end. Nothing placed ever moves: what the reader sees mid-stream stays.
nonisolated struct FreshStreamSpacer<T: FreshSpaceable> {
    /// Placed so far, in order.
    private(set) var placed: [T] = []
    private var held: [T] = []
    private var ids: Set<String> = []
    private let gap: Int

    init(gap: Int = FreshSpacing.authorGap) {
        self.gap = gap
    }

    func has(_ id: String) -> Bool {
        ids.contains(id)
    }

    /// A streamed post: placed now if it fits, else held. Returns `placed`.
    @discardableResult
    mutating func push(_ p: T) -> [T] {
        guard !ids.contains(p.spacingId) else { return placed }
        ids.insert(p.spacingId)
        held.append(p)
        drain()
        return placed
    }

    /// Place every held post far enough from its author's last one, in arrival order.
    private mutating func drain() {
        let keep = max(gap - 1, 0)
        while true {
            let window = placed.suffix(keep).map(\.spacingAuthor)
            guard let i = held.firstIndex(where: { !window.contains($0.spacingAuthor) }) else { return }
            placed.append(held.remove(at: i))
        }
    }

    /// The page ended: the held posts and the final page's posts not seen yet
    /// are spaced after what is placed, and appended. Returns what was added.
    @discardableResult
    mutating func finish(_ final: [T]) -> [T] {
        var rest: [T] = []
        for p in final where !ids.contains(p.spacingId) {
            ids.insert(p.spacingId)
            rest.append(p)
        }
        let added = FreshSpacing.spaceAuthors(before: placed, incoming: held + rest, gap: gap)
        held = []
        placed.append(contentsOf: added)
        return added
    }
}
