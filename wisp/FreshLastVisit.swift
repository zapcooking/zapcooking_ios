import Foundation

/// Where the "new since your last visit" mark is kept. Device-local only;
/// nothing about viewing leaves the device (build spec §2). Throwing so a
/// failing store can be modelled; `UserDefaults` never throws.
nonisolated protocol FreshVisitStorage {
    func freshVisitValue(forKey key: String) throws -> String?
    func setFreshVisitValue(_ value: String, forKey key: String) throws
}

extension UserDefaults: FreshVisitStorage {
    nonisolated func freshVisitValue(forKey key: String) throws -> String? {
        string(forKey: key)
    }
    nonisolated func setFreshVisitValue(_ value: String, forKey key: String) throws {
        set(value, forKey: key)
    }
}

/// "New since your last visit", ported from web `src/lib/freshFeed/lastVisit.ts`.
///
/// The stored value is the newest post time the reader was shown last time.
/// A visit reads it once (`beginVisit`) and keeps that value for the whole
/// session, so refreshes and tab switches don't move the divider; the newest
/// post seen now is stored for next time (`recordNewest`).
///
/// ≠ web: the mark is per account (`fresh_last_visit_<pubkey>`), since an
/// iOS device holds several accounts; web keeps one browser-wide key. A
/// session is this object's lifetime: hold one per app run (`shared`).
nonisolated final class FreshLastVisit: @unchecked Sendable {
    static let shared = FreshLastVisit()

    static func key(pubkey: String) -> String { "fresh_last_visit_\(pubkey)" }

    private let lock = NSLock()
    /// pubkey → this session's mark (nil value = first visit, read already).
    private var sessionMarks: [String: Int?] = [:]

    init() {}

    /// The previous visit's mark for this session (nil on a first visit).
    func beginVisit(pubkey: String, storage: FreshVisitStorage?) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let mark = sessionMarks[pubkey] { return mark }
        var mark: Int? = nil
        if let raw = try? storage?.freshVisitValue(forKey: Self.key(pubkey: pubkey)),
           let n = Self.positive(raw) {
            mark = n
        }
        sessionMarks[pubkey] = .some(mark)
        return mark
    }

    /// Remember the newest post shown, for the next visit (never moves back).
    /// The read, compare and write happen under the lock, so two concurrent
    /// calls cannot leave the older value stored.
    func recordNewest(_ createdAt: Int, pubkey: String, storage: FreshVisitStorage?) {
        guard let storage, createdAt > 0 else { return }
        let key = Self.key(pubkey: pubkey)
        lock.lock()
        defer { lock.unlock() }
        do {
            if let raw = try storage.freshVisitValue(forKey: key),
               let cur = Self.positive(raw), cur >= createdAt { return }
            try storage.setFreshVisitValue(String(createdAt), forKey: key)
        } catch {
            // A failing store: no divider next time, nothing else.
        }
    }

    /// Forget this session's marks (account wipe, tests).
    func resetSession() {
        lock.lock()
        sessionMarks = [:]
        lock.unlock()
    }

    /// A stored mark as whole seconds; nil for garbage, zero, negatives and
    /// values `Int` cannot hold (`"1e100"`), which would trap in `Int(_:)`.
    private static func positive(_ raw: String) -> Int? {
        guard let n = Double(raw.trimmingCharacters(in: .whitespaces)), n.isFinite, n > 0 else { return nil }
        return Int(exactly: n.rounded(.towardZero))
    }
}

/// A row the divider can be placed among: a post (`createdAt`) or a special
/// card (`isSpecialCard`, e.g. a recipe-row pick), which never places it.
nonisolated protocol FreshDividable {
    var isSpecialCard: Bool { get }
    var dividerCreatedAt: Int { get }
}

nonisolated enum FreshDividedRow<R: FreshDividable> {
    case row(R)
    case divider(newCount: Int)

    var isDivider: Bool {
        if case .divider = self { return true }
        return false
    }
}

nonisolated enum FreshDivider {
    /// Put the "caught up" divider before the first post (not a special card)
    /// the reader already saw, with the number of new posts above it. No
    /// divider on a first visit, when every post shown is new (the reader
    /// hasn't reached the old ones yet), or when none is.
    ///
    /// ≠ web: web checks only the divider's index, so special cards above
    /// the first seen post put a divider with `newCount: 0` there. Here a
    /// zero count means no divider.
    static func withDivider<R: FreshDividable>(_ rows: [R], mark: Int?) -> [FreshDividedRow<R>] {
        let plain = rows.map { FreshDividedRow.row($0) }
        guard let mark else { return plain }
        guard let at = rows.firstIndex(where: { !$0.isSpecialCard && $0.dividerCreatedAt <= mark }),
              at > 0 else { return plain }
        let newCount = rows[..<at].filter { !$0.isSpecialCard }.count
        guard newCount > 0 else { return plain }
        var out = Array(plain[..<at])
        out.append(.divider(newCount: newCount))
        out.append(contentsOf: plain[at...])
        return out
    }
}
