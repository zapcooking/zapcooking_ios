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

        let hiddenEventIds = eventIds
        let hiddenPubkeys = pubkeys
        let hiddenCoordinates = coordinates
        NotificationCenter.default.post(
            name: .contentHidden,
            object: nil,
            userInfo: [
                ContentHideKey.eventIds: Array(hiddenEventIds),
                ContentHideKey.pubkeys: Array(hiddenPubkeys),
                ContentHideKey.coordinates: Array(hiddenCoordinates),
            ]
        )
        // Profile-level hide reuses the existing block observers so home /
        // thread / notifications drop the author without a second code path.
        if target.eventId == nil, target.coordinate == nil {
            NotificationCenter.default.post(
                name: .userBlocked,
                object: target.reportedPubkey.lowercased()
            )
        }
        Task { await SafetyFilter.shared.rebuildSnapshot() }
        RecipeRepository.shared.dropHidden()
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

extension Notification.Name {
    /// Posted after `ReportedContent.hide`. `userInfo` carries the current
    /// hidden event-id / pubkey / coordinate sets under `ContentHideKey`.
    static let contentHidden = Notification.Name("WispContentHidden")
}

extension Array where Element == NostrEvent {
    func removingHidden(
        eventIds: Set<String> = [],
        pubkeys: Set<String> = []
    ) -> [NostrEvent] {
        guard !eventIds.isEmpty || !pubkeys.isEmpty else { return self }
        return filter { event in
            !eventIds.contains(event.id) && !pubkeys.contains(event.pubkey.lowercased())
        }
    }
}
