import Foundation

/// Seam for the Note Review disclosure preference so the view model's
/// seed/persist logic is unit-testable without `UserDefaults`.
/// Production is `NoteReviewPreferences`.
protocol NoteReviewDisclosurePreferences {
    func isDisclosureEnabled(_ mode: NoteReview.Mode) -> Bool
    func setDisclosureEnabled(_ mode: NoteReview.Mode, _ enabled: Bool)
}

/// Cheffy Note Review preferences — the house **per-account** UserDefaults
/// pattern (`<key>_<pubkey>`), so the disclosure toggles cannot leak across
/// an account switch. Replaces the web's `zapcooking_note_review_disclosure_*`
/// localStorage keys. Booleans default per `NoteReview.defaultDisclosure`
/// (comment OFF — the member's own voice; recipe ON — Cheffy's structured
/// work product).
///
/// This is the whole store: with no credit purchase on iOS there is no
/// pending invoice to persist.
struct NoteReviewPreferences: NoteReviewDisclosurePreferences {
    let defaults: UserDefaults
    let pubkey: String

    init(pubkey: String, defaults: UserDefaults = .standard) {
        self.pubkey = pubkey
        self.defaults = defaults
    }

    static func disclosureKey(_ mode: NoteReview.Mode, pubkey: String) -> String {
        "note_review_disclosure_\(mode.rawValue)_\(pubkey)"
    }

    func isDisclosureEnabled(_ mode: NoteReview.Mode) -> Bool {
        let key = Self.disclosureKey(mode, pubkey: pubkey)
        if defaults.object(forKey: key) == nil { return NoteReview.defaultDisclosure(mode) }
        return defaults.bool(forKey: key)
    }

    func setDisclosureEnabled(_ mode: NoteReview.Mode, _ enabled: Bool) {
        defaults.set(enabled, forKey: Self.disclosureKey(mode, pubkey: pubkey))
    }
}
