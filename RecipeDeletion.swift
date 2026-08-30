import Foundation

/// Tag builders for deleting a published recipe — a byte-faithful port of the
/// web `Recipe.svelte` `handleDelete`, which publishes **two** events:
///
///  1. a **blanked replacement** at the same address (same kind, same `d`, empty
///     content, `deleted`/`title` tags) — the half that actually removes the
///     recipe, because an addressable event is superseded by a newer one at the
///     same coordinate on every NIP-01 relay whether or not it honors NIP-09;
///  2. a **kind-5 deletion request** (`e` + `a` + `k`) for clients and relays
///     that do honor NIP-09.
///
/// Both are needed: relay support for kind 5 is uneven, and the replacement is
/// what makes the recipe stop resolving.
///
/// **Kind is read off the event, never hardcoded.** Deriving it (or the `d` tag)
/// from anything but the event being deleted is how a tombstone lands at a
/// different address than the recipe it was meant to remove. Android paid for
/// that twice (§7.9): a list fork pushed a cover onto the source event and
/// silently deleted covers, and a separate path built kind-5 tombstones with
/// the wrong `deleteKind`.
///
/// Tag *order* follows this repo's house style (`Nip09.deletionTagsForAddressable`
/// then `e`, as in `GroceryEvents`/`MealPlanEvents` on Android) rather than the
/// web's `e`, `a`, `k` — the tag set is identical and order carries no meaning
/// in NIP-09.
///
/// Port of Android `nostr/RecipeDeletion.kt`.
nonisolated enum RecipeDeletion {

    /// Title tag value on the blanked replacement (web parity).
    static let tombstoneTitle = "[Deleted]"

    /// Content of the kind-5 deletion request (web parity).
    static let deletionRequestContent = "Recipe deleted by author"

    /// Content of the blanked replacement — empty, one of the two halves it
    /// fails `RecipeParser.isRecipe` on (the other is the dropped recipe `#t` tag).
    static let tombstoneContent = ""

    /// The future-date grace `EventStore` / most relays apply: an event stamped
    /// more than this many seconds ahead of the reader's clock is dropped.
    static let futureDateGraceSeconds = 30

    /// Tags for the blanked replacement of `event`. The `d` tag is carried over
    /// verbatim so the replacement lands at the *same* coordinate; it is omitted
    /// when the original has no (or a blank) `d`, in which case both events
    /// already address `kind:pubkey:` — web parity.
    static func blankedReplacementTags(_ event: NostrEvent) -> [[String]] {
        var tags: [[String]] = []
        if let d = dTagOf(event) { tags.append(["d", d]) }
        tags.append(["deleted", "true"])
        tags.append(["title", tombstoneTitle])
        return tags
    }

    /// Tags for the kind-5 deletion request targeting `event` — the addressable
    /// coordinate (`a`) plus its kind (`k`) and the concrete event id (`e`), so
    /// a relay that only indexes one of the two still resolves the target. The
    /// `a` tag is omitted when the original has no `d` (nothing well-formed to
    /// point at); `e` still identifies it.
    ///
    /// `k` is `String(event.kind)`, never a hardcoded 30023.
    static func deletionRequestTags(_ event: NostrEvent) -> [[String]] {
        var tags: [[String]]
        if let d = dTagOf(event) {
            tags = Nip09.deletionTagsForAddressable(kind: event.kind, pubkey: event.pubkey, dTag: d)
        } else {
            tags = [["k", String(event.kind)]]
        }
        tags.append(["e", event.id])
        return tags
    }

    /// The created_at both deletion events must carry: **strictly newer** than
    /// the recipe being deleted. NIP-09 only voids events with
    /// `created_at <= deletion.created_at`, and a replacement only supersedes an
    /// older one — so a device clock behind the recipe's own stamp would
    /// otherwise publish a tombstone that does nothing.
    static func deletionTimestamp(_ event: NostrEvent, now: Int) -> Int {
        max(now, event.createdAt + 1)
    }

    /// False when the tombstone `deletionTimestamp` would produce is itself
    /// beyond the future-date ceiling — i.e. the recipe is dated
    /// `futureDateGraceSeconds` or more ahead of this device.
    ///
    /// That case is not a delete that merely propagates slowly, it is a delete
    /// that *cannot land*: the strictly-newer clamp pushes the tombstone past
    /// the grace, so local persist and relays drop it. It has to be refused up
    /// front — publishing it and reporting success would evict the recipe from
    /// this device's grids while leaving it live everywhere else.
    static func isDeletableNow(_ event: NostrEvent, now: Int) -> Bool {
        deletionTimestamp(event, now: now) <= now + futureDateGraceSeconds
    }

    /// True when `event` is a blanked replacement — an addressable event the
    /// author has emptied to delete it, marked `["deleted","true"]`. It is a
    /// tombstone, not content: cache it (so an addressable lookup resolves to
    /// the tombstone rather than a stale copy) but never render it.
    static func isBlankedReplacement(_ event: NostrEvent) -> Bool {
        event.tags.contains { $0.count >= 2 && $0[0] == "deleted" && $0[1] == "true" }
    }

    /// `event`'s `d` tag value, or nil when absent or blank.
    static func dTagOf(_ event: NostrEvent) -> String? {
        guard let tag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" }) else {
            return nil
        }
        let value = tag[1]
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}
