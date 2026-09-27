import Foundation
import Observation

/// Per-account hide list for content the user has successfully reported.
///
/// Separate from `HiddenRecipes` (that list is the cross-platform leftover
/// net for live-gate events whose keys are gone) and from `MuteRepository`
/// (block / mute-word / mute-thread, synced as kind-10000). A report that
/// appears to do nothing gets reported again; reviewers test exactly this.
///
/// Hide is local to the reporter. It is applied immediately on
/// `ReportOutcome.sent` and persisted so a relaunch does not resurface the
/// same card.
@Observable
@MainActor
final class ReportedContent {
    static let shared = ReportedContent()

    private(set) var activePubkey: String?
    private(set) var eventIds: Set<String> = []
    private(set) var coordinates: Set<String> = []
    private(set) var pubkeys: Set<String> = []

    private init() {}

    func bind(activePubkey pk: String) {
        activePubkey = pk
        let d = UserDefaults.standard
        eventIds = Set(d.stringArray(forKey: Self.eventIdsKey(pk)) ?? [])
        coordinates = Set(d.stringArray(forKey: Self.coordinatesKey(pk)) ?? [])
        pubkeys = Set((d.stringArray(forKey: Self.pubkeysKey(pk)) ?? []).map { $0.lowercased() })
    }

    func unbind() {
        activePubkey = nil
        eventIds = []
        coordinates = []
        pubkeys = []
    }

    func isHidden(_ event: NostrEvent) -> Bool {
        if eventIds.contains(event.id) { return true }
        if pubkeys.contains(event.pubkey.lowercased()) { return true }
        if !coordinates.isEmpty {
            let coord = RecipeRepository.coordinate(event)
            if coordinates.contains(coord) { return true }
        }
        return false
    }

    func isHidden(eventId: String) -> Bool { eventIds.contains(eventId) }

    func isHidden(pubkey: String) -> Bool { pubkeys.contains(pubkey.lowercased()) }

    func isHidden(coordinate: String) -> Bool { coordinates.contains(coordinate) }

    /// Record a successful report and broadcast so already-rendered surfaces
    /// drop the content without waiting for a refresh.
    func hide(_ target: ReportTarget) {
        var changed = false
        if let eventId = target.eventId, !eventId.isEmpty {
            changed = eventIds.insert(eventId).inserted || changed
        }
        if let coordinate = target.coordinate, !coordinate.isEmpty {
            changed = coordinates.insert(coordinate).inserted || changed
        }
        // A profile report has no event id — hide the author so their posts
        // and recipes leave the reporter's view immediately. A post/recipe
        // report hides only that item; Block remains a separate action.
        if target.eventId == nil, target.coordinate == nil {
            let pk = target.reportedPubkey.lowercased()
            if !pk.isEmpty {
                changed = pubkeys.insert(pk).inserted || changed
            }
        }
        guard changed else { return }
        persist()

        // A profile report also reaches the `.userBlocked` observers so
        // home / thread / notifications drop the author the same way a block
        // does.
        let isProfileReport = target.eventId == nil && target.coordinate == nil
        ContentHide.broadcast(
            eventIds: eventIds,
            pubkeys: pubkeys,
            coordinates: coordinates,
            hiddenAuthors: isProfileReport ? [target.reportedPubkey.lowercased()] : []
        )
        Task { await SafetyFilter.shared.rebuildSnapshot() }
    }

    // MARK: - Storage

    static func eventIdsKey(_ pubkey: String) -> String { "reported_event_ids_\(pubkey)" }
    static func coordinatesKey(_ pubkey: String) -> String { "reported_coordinates_\(pubkey)" }
    static func pubkeysKey(_ pubkey: String) -> String { "reported_pubkeys_\(pubkey)" }

    private func persist() {
        guard let pk = activePubkey else { return }
        let d = UserDefaults.standard
        d.set(Array(eventIds), forKey: Self.eventIdsKey(pk))
        d.set(Array(coordinates), forKey: Self.coordinatesKey(pk))
        d.set(Array(pubkeys), forKey: Self.pubkeysKey(pk))
    }
}

enum ContentHideKey {
    static let eventIds = "eventIds"
    static let pubkeys = "pubkeys"
    static let coordinates = "coordinates"
}

/// The one path by which "this is hidden now" reaches every surface already
/// holding content. Report (`ReportedContent.hide`) and block
/// (`MuteRepository.blockUser`, and blocks arriving by relay sync) both come
/// through here, so a surface that drops reported content drops blocked
/// content too — Guideline 1.2 asks for both to vanish instantly, and two
/// paths had drifted (block never posted `.contentHidden`, so OnlyFood,
/// search, hashtag, trending, profile and the recipe grids kept a blocked
/// author's posts until a refresh).
@MainActor
enum ContentHide {
    /// Callers update their own store (`ReportedContent` / `MuteRepository`)
    /// first. Then, in order: the filter snapshot is installed synchronously so
    /// a live subscription can't deliver the author again in the gap before
    /// the async rebuild; `.contentHidden` reaches the list observers;
    /// `.userBlocked` (one per `hiddenAuthors` entry) reaches the thread and
    /// notifications, which render a placeholder / regroup rather than just
    /// filter; the recipe grids re-apply their visibility gate.
    static func broadcast(
        eventIds: Set<String> = [],
        pubkeys: Set<String> = [],
        coordinates: Set<String> = [],
        hiddenAuthors: Set<String> = []
    ) {
        SafetyFilter.shared.installLocalState()
        NotificationCenter.default.post(
            name: .contentHidden,
            object: nil,
            userInfo: [
                ContentHideKey.eventIds: Array(eventIds),
                ContentHideKey.pubkeys: Array(pubkeys),
                ContentHideKey.coordinates: Array(coordinates),
            ]
        )
        for pk in hiddenAuthors {
            NotificationCenter.default.post(name: .userBlocked, object: pk)
        }
        RecipeRepository.shared.dropHidden()
    }
}

extension Notification.Name {
    /// Posted by `ContentHide.broadcast`. `userInfo` carries hidden event-id /
    /// pubkey / coordinate sets under `ContentHideKey` — the full reported sets
    /// after a report, the newly-blocked pubkeys after a block. Observers drop
    /// matches; the sets are never "everything that is hidden".
    static let contentHidden = Notification.Name("WispContentHidden")
}

extension Array where Element == NostrEvent {
    func removingHidden(
        eventIds: Set<String> = [],
        pubkeys: Set<String> = []
    ) -> [NostrEvent] {
        guard !eventIds.isEmpty || !pubkeys.isEmpty else { return self }
        return filter { event in
            if eventIds.contains(event.id) || pubkeys.contains(event.pubkey.lowercased()) {
                return false
            }
            // A repost wrapping a hidden author's note hides with them, as in
            // `SafetyFilter.shouldDrop` and the home feed's observer.
            if event.kind == 6, !pubkeys.isEmpty,
               let inner = SafetyFilter.repostInnerPubkey(event),
               pubkeys.contains(inner.lowercased()) {
                return false
            }
            return true
        }
    }
}
