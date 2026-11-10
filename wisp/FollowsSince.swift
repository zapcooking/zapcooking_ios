import Foundation

/// The `since` the Follows feed sends with a load (#188). Pure, so the
/// decision can be tested without a view model or a socket.
///
/// `anchor` is the timestamp Follows believes it is already synced to;
/// where that comes from is the caller's business.
nonisolated enum FollowsSince {
    /// Re-request this much before the anchor, to absorb relay clock skew
    /// and notes that reached a relay late.
    static let overlapSeconds = 5 * 60
    /// The same, from the newest note already in the list.
    static let listOverlapSeconds = 60

    /// How far back a load reaches when there is no anchor: shorter for a
    /// larger follow list, whose relays return more per day.
    static func window(followCount: Int) -> Int {
        switch followCount {
        case ...10: return 7 * 24 * 3600
        case ...30: return 5 * 24 * 3600
        case ...75: return 3 * 24 * 3600
        case ...150: return 2 * 24 * 3600
        case ...300: return 36 * 3600
        default: return 24 * 3600
        }
    }

    /// A load into an empty list (cold start): from the anchor, but never
    /// further back than the window.
    static func coldStart(anchor: Int?, followCount: Int, now: Int) -> Int {
        let defaultSince = now - window(followCount: followCount)
        if let anchor, anchor > 0 {
            return max(anchor - overlapSeconds, defaultSince)
        }
        return defaultSince
    }

    /// Pull-to-refresh, and the load that follows picking Follows in the
    /// feed picker. With notes in the list, from the newest of them.
    static func refresh(listNewest: Int?, anchor: Int?, followCount: Int, now: Int) -> Int? {
        if let listNewest { return listNewest - listOverlapSeconds }
        // Behaviour as extracted, unchanged: the anchor raw, with no
        // overlap and no window. #188's fix replaces this line.
        return anchor
    }
}
