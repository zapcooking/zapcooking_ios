import Foundation
import Observation

/// A14 recipe-bookmark interop. Reads and writes the **same canonical lists
/// the Zap Cooking web app uses** so recipe collections round-trip
/// cross-client.
///
/// Web contract: every recipe list is a NIP-51 generic list of **kind 30001**,
/// with each saved recipe referenced by its **a-tag coordinate**
/// (`kind:pubkey:dTag`). Two flavours:
///  - the **default Saved list**: `d`-tag ``defaultListDTag``, **no `t` tag**
///    (the web reads it by `#d`); and
///  - **named collections**: a slug `d`-tag plus a recipe `t` tag
///    (``collectionTag``) so the web enumerates them by `#t`.
///
/// Deliberately not the kind-10003/30003 note-bookmark path (`NoteListRepository`)
/// and not the kind-30003 `zapcooking-saved-packs` list. Android
/// `RecipeBookmarkRepository.LIST_KIND` is **30001** — verified in the Kotlin
/// source, not assumed from NIP-51's "bookmark set" name (that is 30003).
/// Recipe coordinates are built through `RecipeFormats` so there is no
/// hardcoded 30023.
///
/// **Cold-session guard (Android 1.3.5):** a first save on a cold cache must
/// not publish a fresh replaceable kind-30001 over an unfetched copy. If
/// memory and the on-device cache have no list, a bounded relay check runs:
/// found → that event is the carry-forward base; confirmed absent (EOSE, no
/// event) → create; inconclusive (no EOSE) → reject, sign nothing, surface
/// ``writeUnconfirmedMessage``. `RelayPool.queryDetailed` already exists for
/// this exact hazard.
///
/// Scope (3.1 / Android PR 3a): read the user's recipe lists, single-tap
/// toggle of the default list, multi-membership add/remove, create-by-name.
/// 3.2 (My Kitchen) added named-collection management: rename (only the
/// `title` tag — the `d` tag is the stable identity and is never changed),
/// description (`summary` tag), cover (`cover` tag, a member recipe's
/// a-coordinate, guarded to members), and delete (a real NIP-09 kind-5
/// tombstone, not a list rewrite). All go through the same cold-session
/// guard: metadata edits never create, and an unconfirmed relay check signs
/// nothing. The default Saved list is never renameable or deletable.
///
/// Port of Android `repo/RecipeBookmarkRepository.kt`.
@Observable
@MainActor
final class RecipeBookmarkRepository {

    nonisolated static let listKind = 30001
    nonisolated static let defaultListDTag = "nostrcooking-bookmarks"
    nonisolated static let defaultListTitle = "Saved"
    nonisolated static let collectionTag = "zapcooking"
    nonisolated static let recipeTTags: Set<String> = ["zapcooking", "nostrcooking"]
    static let writeUnconfirmedMessage =
        "Couldn't reach your relays to check your saved list — nothing was saved. Try again in a moment."

    static let confirmTimeout: TimeInterval = 8
    static let confirmRetryCooldown: TimeInterval = 15

    // MARK: - Types

    enum RelayListCheck: Equatable {
        case found(NostrEvent)
        case confirmedAbsent
        case unconfirmed

        static func == (lhs: RelayListCheck, rhs: RelayListCheck) -> Bool {
            switch (lhs, rhs) {
            case (.found(let a), .found(let b)): return a.id == b.id && a.createdAt == b.createdAt
            case (.confirmedAbsent, .confirmedAbsent), (.unconfirmed, .unconfirmed): return true
            default: return false
            }
        }
    }

    enum MutationPlan: Equatable {
        case publish(tags: [[String]], content: String, membership: Bool)
        case noOp(membership: Bool)
        case rejectedUnconfirmed
    }

    struct CookbookList {
        var dTag: String
        var title: String
        var summary: String?
        var image: String?
        var coverCoord: String?
        var coordinates: [String]
        var isDefault: Bool
        var event: NostrEvent
    }

    struct Environment {
        var confirmList: (String, String) async -> RelayListCheck
        var cachedList: (String, String) -> NostrEvent?
        var cachedLists: (String) -> [NostrEvent]
        var persist: (NostrEvent) -> Void
        var sign: (Int, [[String]], String) async throws -> NostrEvent
        var publish: (NostrEvent) async -> Void
        var readRelays: () async -> [String]
        var nowMs: () -> Int64
        /// Evict one list from the on-device cache (3.2 delete). Defaulted so
        /// pre-3.2 `Environment` constructions stay source-compatible.
        var removeCached: (String, String) -> Void = { _, _ in }
    }

    static let shared = RecipeBookmarkRepository(env: .production)

    private(set) var lists: [CookbookList] = []
    private(set) var bookmarkedCoordinates: Set<String> = []
    private(set) var isLoading = false

    /// True once ``load(pubkey:)`` has completed, whatever the list count —
    /// so a tab re-entry (`.task` re-run) does not re-issue an identical
    /// filter (§7.4). ``load(pubkey:)`` itself stays re-runnable; it is the
    /// pull-to-refresh path.
    private(set) var hasLoaded = false
    private(set) var lastWriteError: String?

    private let env: Environment
    private var listsByDTag: [String: NostrEvent] = [:]
    private var lastUnconfirmedCheckMs: [String: Int64] = [:]

    /// d-tags deleted this session, mapped to the kind-5's `created_at`, so a
    /// laggard relay (or the cache) cannot resurrect a deleted collection.
    /// A strictly newer republish of the address revives it — Android
    /// `applyEvent`'s unmark path.
    private var deletedListStamps: [String: Int] = [:]

    /// True while a list mutation is in flight (confirm + sign + publish).
    /// The save button shows pending from this; it must not flip filled state
    /// until ``bookmarkedCoordinates`` / ``lists`` update after a successful
    /// write. Observation publishes the change.
    private(set) var isWriting = false

    init(env: Environment) {
        self.env = env
    }

    // MARK: - Pure planners (Android companion; the hermetic gate)

    /// NIP-01 replaceable newest-wins: higher `createdAt` wins; equal
    /// `createdAt`, lower event id wins. Same-second rapid toggles must not
    /// drop the event relays will serve.
    nonisolated static func isNewerReplaceable(_ incoming: NostrEvent, than current: NostrEvent) -> Bool {
        if incoming.createdAt != current.createdAt {
            return incoming.createdAt > current.createdAt
        }
        return incoming.id < current.id
    }

    /// A streamed event wins regardless of EOSE. Absence is only confirmed
    /// when at least one targeted relay EOSE'd. No event and no EOSE is
    /// unconfirmed — a replaceable create must not proceed on that.
    nonisolated static func classifyRelayListCheck(newest: NostrEvent?, eoseCount: Int) -> RelayListCheck {
        if let newest { return .found(newest) }
        if eoseCount > 0 { return .confirmedAbsent }
        return .unconfirmed
    }

    /// The testable core of `mutateList`. `base == nil && !absenceConfirmed`
    /// is the cold-cache overwrite hazard — reject, sign nothing.
    nonisolated static func planMutation(
        base: NostrEvent?,
        absenceConfirmed: Bool,
        dTag: String,
        coord: String,
        desired: Bool?,
        seedTitleIfNew: String?
    ) -> MutationPlan {
        if base == nil && !absenceConfirmed { return .rejectedUnconfirmed }
        var nextCoords = base.map { parseCoordinates($0) } ?? []
        let contained = nextCoords.contains(coord)
        let add = desired ?? !contained
        let changed: Bool
        if add {
            if contained { changed = false }
            else { nextCoords.append(coord); changed = true }
        } else {
            let before = nextCoords.count
            nextCoords.removeAll { $0 == coord }
            changed = nextCoords.count != before
        }
        if !changed { return .noOp(membership: add) }
        let isDefault = dTag == defaultListDTag
        let tags = buildListTags(
            existing: base,
            dTag: dTag,
            isDefault: isDefault,
            seedTitleIfNew: seedTitleIfNew,
            nextCoords: nextCoords
        )
        return .publish(tags: tags, content: base?.content ?? "", membership: add)
    }

    /// Rebuild list tags from `existing`, preserving everything except `a`
    /// (rewritten to `nextCoords`) and a misattributing `client` tag.
    /// Named collections get ``collectionTag`` when they lack a recipe `t`;
    /// the default list is never given a `t` tag.
    ///
    /// The 3.2 metadata substitutions ride the same carry-forward (one
    /// builder — a second one would clobber; Android's `buildListTags` is
    /// likewise the single writer):
    /// - `newTitle` non-nil replaces the `title` tag in place;
    /// - `newSummary` / `newCover` use a double optional: `.none` carries the
    ///   existing tag through untouched, `.some(nil)` (or blank) clears it,
    ///   `.some(value)` replaces it. `cover` is a member recipe's
    ///   a-coordinate, not an image URL — membership is the caller's guard.
    nonisolated static func buildListTags(
        existing: NostrEvent?,
        dTag: String,
        isDefault: Bool,
        seedTitleIfNew: String?,
        nextCoords: [String],
        newTitle: String? = nil,
        newSummary: String?? = .none,
        newCover: String?? = .none
    ) -> [[String]] {
        var tags: [[String]] = []
        var hasD = false
        var hasTitle = false
        var hasRecipeT = false
        if let existing {
            for tag in existing.tags {
                guard let name = tag.first else { continue }
                switch name {
                case "a", "client":
                    continue
                case "d":
                    if !hasD {
                        tags.append(["d", dTag])
                        hasD = true
                    }
                case "title":
                    if !hasTitle {
                        tags.append(newTitle.map { ["title", $0] } ?? tag)
                        hasTitle = true
                    }
                case "summary":
                    if case .some = newSummary { continue }
                    tags.append(tag)
                case "cover":
                    if case .some = newCover { continue }
                    tags.append(tag)
                case "t":
                    if !isDefault {
                        tags.append(tag)
                        if tag.count >= 2, recipeTTags.contains(tag[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                            hasRecipeT = true
                        }
                    }
                default:
                    tags.append(tag)
                }
            }
        }
        if !hasD { tags.insert(["d", dTag], at: 0) }
        if !hasTitle {
            let title = newTitle ?? seedTitleIfNew ?? (isDefault ? defaultListTitle : dTag)
            tags.append(["title", title])
        }
        if case .some(let value?) = newSummary,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tags.append(["summary", value])
        }
        if case .some(let value?) = newCover,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tags.append(["cover", value])
        }
        if !isDefault && !hasRecipeT {
            tags.append(["t", collectionTag])
        }
        for coord in nextCoords {
            tags.append(["a", coord])
        }
        return tags
    }

    /// Tag order preserved (Android `LinkedHashSet`) so a republish does not
    /// shuffle `a` tags.
    nonisolated static func parseCoordinates(_ event: NostrEvent) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for tag in event.tags where tag.count >= 2 && tag[0] == "a" {
            let coord = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !coord.isEmpty, seen.insert(coord).inserted else { continue }
            out.append(coord)
        }
        return out
    }

    nonisolated static func isRecipeList(_ event: NostrEvent) -> Bool {
        guard event.kind == listKind else { return false }
        if hasDTag(event, defaultListDTag) { return true }
        return event.tags.contains { tag in
            tag.count >= 2 && tag[0] == "t"
                && recipeTTags.contains(tag[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    nonisolated static func dTagOf(_ event: NostrEvent) -> String? {
        if hasDTag(event, defaultListDTag) { return defaultListDTag }
        guard let tag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" }) else {
            return nil
        }
        let value = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    nonisolated static func hasDTag(_ event: NostrEvent, _ dTag: String) -> Bool {
        let needle = dTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return event.tags.contains { $0.count >= 2 && $0[0] == "d" && $0[1].trimmingCharacters(in: .whitespacesAndNewlines) == needle }
    }

    /// Web-compatible slug (`cookbookStore.createList`): lower, spaces→`-`,
    /// strip non `[a-z0-9-]`.
    nonisolated static func slugify(_ title: String) -> String {
        let lowered = title.lowercased().replacingOccurrences(of: " ", with: "-")
        return lowered.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Format-agnostic addressable coordinate, matching Android: first `d`
    /// tag via `RecipeParser.dTag`, not ``dTagOf`` (that helper prefers the
    /// default-list d-tag and is for list events only).
    ///
    /// MainActor-isolated (unlike the other pure helpers): it consults the
    /// `RecipeFormats` registry, whose statics are isolated under this
    /// module's default isolation, and every caller is already on the main
    /// actor.
    static func coordinateForEvent(_ event: NostrEvent) -> String? {
        guard let format = RecipeFormats.forEvent(event) else { return nil }
        let dTag = RecipeParser.dTag(event).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dTag.isEmpty else { return nil }
        return "\(format.kind):\(event.pubkey):\(dTag)"
    }

    /// `kind:pubkey:d-tag` — d-tag may itself contain colons, so only the
    /// first two separators are structural (same rule as `HiddenRecipes`).
    nonisolated static func parseCoordinate(_ raw: String) -> (kind: Int, pubkey: String, dTag: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: ":") else { return nil }
        let kindRaw = String(trimmed[..<first])
        guard let kind = Int(kindRaw) else { return nil }
        let afterKind = trimmed.index(after: first)
        guard let second = trimmed[afterKind...].firstIndex(of: ":") else { return nil }
        let pubkey = String(trimmed[afterKind..<second])
        let dTag = String(trimmed[trimmed.index(after: second)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pubkey.isEmpty, !dTag.isEmpty else { return nil }
        return (kind, pubkey, dTag)
    }

    /// Resolve saved coordinates through ``RecipeRepository``. Hidden
    /// coordinates return nil from `cached` / `requestRecipe`, so they do
    /// not render — this method does not re-filter. Order follows the
    /// bookmark list (tag order), not `Set` iteration.
    func resolvedRecipes(
        coordinates: [String]? = nil,
        using recipes: RecipeRepository
    ) async -> [NostrEvent] {
        let coords = coordinates
            ?? lists.first(where: { $0.isDefault })?.coordinates
            ?? []
        var out: [NostrEvent] = []
        for coord in coords {
            guard let parsed = Self.parseCoordinate(coord) else { continue }
            if let cached = recipes.cached(author: parsed.pubkey, dTag: parsed.dTag) {
                out.append(cached)
                continue
            }
            if let fetched = await recipes.requestRecipe(author: parsed.pubkey, dTag: parsed.dTag) {
                out.append(fetched)
            }
        }
        return out
    }

    // MARK: - Read

    func paintFromCache(pubkey: String) {
        let author = pubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else {
            reset()
            return
        }
        for event in env.cachedLists(author) {
            applyEvent(event)
        }
    }

    func load(pubkey: String) async {
        let author = pubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else {
            reset()
            return
        }
        isLoading = true
        defer { isLoading = false }
        paintFromCache(pubkey: author)
        let relays = await env.readRelays()
        let result = await RelayPool.queryDetailed(
            relays: relays,
            filter: NostrFilter(kinds: [Self.listKind], authors: [author], limit: 256),
            timeout: Self.confirmTimeout,
            waitForAllRelays: true
        )
        for event in result.events {
            applyEvent(event)
        }
        hasLoaded = true
    }

    func applyEvent(_ event: NostrEvent) {
        guard event.kind == Self.listKind, Self.isRecipeList(event) else { return }
        guard let dTag = Self.dTagOf(event) else { return }
        if let stamp = deletedListStamps[dTag] {
            // The address was deleted this session: copies at or before the
            // kind-5's stamp are the deleted version; a strictly newer
            // republish revives the address (Android's unmark path).
            guard event.createdAt > stamp else { return }
            deletedListStamps.removeValue(forKey: dTag)
        }
        if let current = listsByDTag[dTag], !Self.isNewerReplaceable(event, than: current) { return }
        listsByDTag[dTag] = event
        env.persist(event)
        publishListsState()
    }

    func isRecipeBookmarked(_ event: NostrEvent) -> Bool {
        guard let coord = Self.coordinateForEvent(event) else { return false }
        return bookmarkedCoordinates.contains(coord)
    }

    func isCoordInList(_ dTag: String, _ coord: String) -> Bool {
        if let event = listsByDTag[dTag] {
            return Self.parseCoordinates(event).contains(coord)
        }
        if dTag == Self.defaultListDTag { return bookmarkedCoordinates.contains(coord) }
        return lists.first(where: { $0.dTag == dTag })?.coordinates.contains(coord) ?? false
    }

    func reset() {
        listsByDTag.removeAll()
        lastUnconfirmedCheckMs.removeAll()
        deletedListStamps.removeAll()
        isLoading = false
        hasLoaded = false
        lists = []
        bookmarkedCoordinates = []
        lastWriteError = nil
        isWriting = false
    }

    // MARK: - Write

    /// Single-tap toggle of `event` in the **default** Saved list.
    func toggle(event: NostrEvent, keypair: Keypair?) async -> Bool {
        guard let coord = Self.coordinateForEvent(event) else {
            return isRecipeBookmarked(event)
        }
        guard keypair != nil else { return bookmarkedCoordinates.contains(coord) }
        return await mutateList(
            dTag: Self.defaultListDTag,
            coord: coord,
            desired: nil,
            seedTitleIfNew: Self.defaultListTitle,
            keypair: keypair
        )
    }

    func toggleRecipeInList(dTag: String, event: NostrEvent, keypair: Keypair?) async -> Bool {
        guard let coord = Self.coordinateForEvent(event) else { return false }
        let seed = dTag == Self.defaultListDTag ? Self.defaultListTitle : nil
        return await mutateList(dTag: dTag, coord: coord, desired: nil, seedTitleIfNew: seed, keypair: keypair)
    }

    func setRecipeInList(dTag: String, event: NostrEvent, add: Bool, keypair: Keypair?) async -> Bool {
        guard let coord = Self.coordinateForEvent(event) else { return false }
        let seed = dTag == Self.defaultListDTag ? Self.defaultListTitle : nil
        return await mutateList(dTag: dTag, coord: coord, desired: add, seedTitleIfNew: seed, keypair: keypair)
    }

    /// Create a named collection (slug `d`-tag + recipe `t` tag). Colliding
    /// slugs add to the existing list. Never creates the default Saved list.
    /// Cold-cache: same relay check as ``mutateList`` so a colliding slug
    /// cannot publish a one-item replaceable over an unfetched copy.
    func createList(title: String, seedEvent: NostrEvent?, keypair: Keypair?) async -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let keypair else { return nil }
        let dTag = Self.slugify(trimmed)
        guard !dTag.isEmpty, dTag != Self.defaultListDTag else { return nil }
        guard !isWriting else { return nil }
        isWriting = true
        defer { isWriting = false }
        let author = keypair.pubkey
        let (base, absenceConfirmed) = await resolveCarryForward(author: author, dTag: dTag)
        if base == nil && !absenceConfirmed {
            lastWriteError = Self.writeUnconfirmedMessage
            return nil
        }
        var nextCoords = base.map { Self.parseCoordinates($0) } ?? []
        if let seedEvent, let coord = Self.coordinateForEvent(seedEvent),
           !HiddenRecipes.isHidden(coordinate: coord),
           !nextCoords.contains(coord) {
            nextCoords.append(coord)
        }
        let tags = Self.buildListTags(
            existing: base,
            dTag: dTag,
            isDefault: false,
            seedTitleIfNew: trimmed,
            nextCoords: nextCoords
        )
        do {
            let signed = try await env.sign(Self.listKind, tags, base?.content ?? "")
            applyEvent(signed)
            await env.publish(signed)
            return dTag
        } catch {
            lastWriteError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Collection management (Concern 3.2)

    /// Rename a named collection — changes **only** the `title` tag. The
    /// `d` tag is the stable identity and is never changed (a new `d` = a
    /// different list = orphaned data). The default Saved list is never
    /// renameable. Port of Android `renameList`.
    func renameList(dTag: String, newTitle: String, keypair: Keypair?) async -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, dTag != Self.defaultListDTag, let keypair else { return false }
        guard !isWriting else { return false }
        isWriting = true
        defer { isWriting = false }
        guard let base = await resolveExistingList(author: keypair.pubkey, dTag: dTag) else {
            return false
        }
        let tags = Self.buildListTags(
            existing: base,
            dTag: dTag,
            isDefault: false,
            seedTitleIfNew: nil,
            nextCoords: Self.parseCoordinates(base),
            newTitle: trimmed
        )
        return await signAndPublishList(tags: tags, content: base.content)
    }

    /// Set or clear (`nil` / blank) the `summary` tag. Allowed on the
    /// default Saved list — the web only locks the default's title.
    func setListDescription(dTag: String, summary: String?, keypair: Keypair?) async -> Bool {
        guard let keypair else { return false }
        guard !isWriting else { return false }
        isWriting = true
        defer { isWriting = false }
        guard let base = await resolveExistingList(author: keypair.pubkey, dTag: dTag) else {
            return false
        }
        let tags = Self.buildListTags(
            existing: base,
            dTag: dTag,
            isDefault: dTag == Self.defaultListDTag,
            seedTitleIfNew: nil,
            nextCoords: Self.parseCoordinates(base),
            newSummary: .some(summary)
        )
        return await signAndPublishList(tags: tags, content: base.content)
    }

    /// Set or clear (`nil` / blank) the `cover` tag — a member recipe's
    /// **a-coordinate**, not an image URL; the display side resolves the URL
    /// from the referenced recipe's own `image` tag. Web guard: a cover can
    /// only be a recipe already in the collection — a non-member coordinate
    /// aborts with nothing signed. Allowed on the default Saved list.
    func setListCover(dTag: String, coverCoord: String?, keypair: Keypair?) async -> Bool {
        guard let keypair else { return false }
        guard !isWriting else { return false }
        isWriting = true
        defer { isWriting = false }
        guard let base = await resolveExistingList(author: keypair.pubkey, dTag: dTag) else {
            return false
        }
        let coords = Self.parseCoordinates(base)
        let trimmed = coverCoord?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty, !coords.contains(trimmed) { return false }
        let tags = Self.buildListTags(
            existing: base,
            dTag: dTag,
            isDefault: dTag == Self.defaultListDTag,
            seedTitleIfNew: nil,
            nextCoords: coords,
            newCover: .some(trimmed?.isEmpty == true ? nil : trimmed)
        )
        return await signAndPublishList(tags: tags, content: base.content)
    }

    /// Delete a named collection — a real NIP-09 **kind-5 tombstone**, not a
    /// list rewrite: `e` (list event id) + `a` (list address), per Android
    /// `deleteList`, plus a `k` tag for consistency with `RecipeDeletion`
    /// (a deliberate, documented divergence — Android omits `k` here).
    /// The default Saved list is never deletable. The list is removed
    /// locally (memory + on-device cache) so the Saved grid updates
    /// immediately, and the address is stamped so cache paints and laggard
    /// relays cannot resurrect it; a strictly newer republish revives it.
    func deleteList(dTag: String, keypair: Keypair?) async -> Bool {
        guard dTag != Self.defaultListDTag, let keypair else { return false }
        guard !isWriting else { return false }
        isWriting = true
        defer { isWriting = false }
        let author = keypair.pubkey
        guard let base = await resolveExistingList(author: author, dTag: dTag) else {
            return false
        }
        let tags: [[String]] = [
            ["e", base.id],
            ["a", "\(Self.listKind):\(author):\(dTag)"],
            ["k", String(Self.listKind)],
        ]
        do {
            let signed = try await env.sign(Nip09.kindDeletion, tags, "")
            deletedListStamps[dTag] = signed.createdAt
            listsByDTag.removeValue(forKey: dTag)
            env.removeCached(author, dTag)
            publishListsState()
            await env.publish(signed)
            lastWriteError = nil
            return true
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }
    }

    /// Shared guard for the metadata edits and delete: they operate on an
    /// existing list and **never create**. Confirmed absent → nothing to
    /// edit, return nil quietly. Unconfirmed → the cold-cache overwrite
    /// hazard: surface ``writeUnconfirmedMessage``, sign nothing — the same
    /// first-save guard ``mutateList`` runs.
    private func resolveExistingList(author: String, dTag: String) async -> NostrEvent? {
        let (base, absenceConfirmed) = await resolveCarryForward(author: author, dTag: dTag)
        if let base { return base }
        if !absenceConfirmed { lastWriteError = Self.writeUnconfirmedMessage }
        return nil
    }

    private func signAndPublishList(tags: [[String]], content: String) async -> Bool {
        do {
            let signed = try await env.sign(Self.listKind, tags, content)
            applyEvent(signed)
            await env.publish(signed)
            lastWriteError = nil
            return true
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }
    }

    /// True when a write would *add* a HiddenRecipes coordinate. Unsave of a
    /// coordinate another client already stored is still allowed — hide-list
    /// drop is render-side; this only refuses creating a new membership.
    /// Android does not refuse at write time; iOS does (Concern 3.1b).
    nonisolated static func shouldRefuseHiddenAdd(
        coordinate: String,
        currentlySaved: Bool,
        desired: Bool?
    ) -> Bool {
        guard HiddenRecipes.isHidden(coordinate: coordinate) else { return false }
        let adding = desired ?? !currentlySaved
        return adding
    }

    /// Cold-cache first-write guard lives here. See the type comment.
    func mutateList(
        dTag: String,
        coord: String,
        desired: Bool?,
        seedTitleIfNew: String?,
        keypair: Keypair?
    ) async -> Bool {
        guard keypair != nil else { return isCoordInList(dTag, coord) }
        if Self.shouldRefuseHiddenAdd(
            coordinate: coord,
            currentlySaved: isCoordInList(dTag, coord),
            desired: desired
        ) {
            return isCoordInList(dTag, coord)
        }
        guard !isWriting else { return isCoordInList(dTag, coord) }
        isWriting = true
        defer { isWriting = false }
        let author = keypair!.pubkey
        let (base, absenceConfirmed) = await resolveCarryForward(author: author, dTag: dTag)
        switch Self.planMutation(
            base: base,
            absenceConfirmed: absenceConfirmed,
            dTag: dTag,
            coord: coord,
            desired: desired,
            seedTitleIfNew: seedTitleIfNew
        ) {
        case .noOp(let membership):
            return membership
        case .rejectedUnconfirmed:
            lastWriteError = Self.writeUnconfirmedMessage
            return isCoordInList(dTag, coord)
        case .publish(let tags, let content, let membership):
            do {
                let signed = try await env.sign(Self.listKind, tags, content)
                applyEvent(signed)
                await env.publish(signed)
                lastWriteError = nil
                return membership
            } catch {
                lastWriteError = error.localizedDescription
                return isCoordInList(dTag, coord)
            }
        }
    }

    // MARK: - Internals

    /// Memory, then on-device cache, then the bounded relay check. A nil
    /// base with `absenceConfirmed == false` is the overwrite hazard —
    /// callers must not sign.
    private func resolveCarryForward(author: String, dTag: String) async -> (NostrEvent?, Bool) {
        if let local = listsByDTag[dTag] ?? env.cachedList(author, dTag) {
            return (local, false)
        }
        switch await confirmList(author: author, dTag: dTag) {
        case .found(let event):
            return (event, false)
        case .confirmedAbsent:
            return (nil, true)
        case .unconfirmed:
            return (nil, false)
        }
    }

    private func confirmList(author: String, dTag: String) async -> RelayListCheck {
        if let last = lastUnconfirmedCheckMs[dTag],
           env.nowMs() - last < Int64(Self.confirmRetryCooldown * 1000) {
            return .unconfirmed
        }
        let check = await env.confirmList(author, dTag)
        if case .found(let event) = check {
            applyEvent(event)
        }
        if case .unconfirmed = check {
            lastUnconfirmedCheckMs[dTag] = env.nowMs()
        } else {
            lastUnconfirmedCheckMs.removeValue(forKey: dTag)
        }
        return check
    }

    private func publishListsState() {
        let models = listsByDTag.values
            .map(Self.toModel)
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
                return lhs.event.createdAt > rhs.event.createdAt
            }
        lists = models
        bookmarkedCoordinates = Set(models.first(where: { $0.isDefault })?.coordinates ?? [])
    }

    nonisolated static func toModel(_ event: NostrEvent) -> CookbookList {
        let dTag = dTagOf(event) ?? ""
        let isDefault = dTag == defaultListDTag
        func tagValue(_ name: String) -> String? {
            event.tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
        let title = isDefault ? defaultListTitle : (tagValue("title") ?? dTag)
        return CookbookList(
            dTag: dTag,
            title: title,
            summary: tagValue("summary"),
            image: tagValue("image"),
            coverCoord: tagValue("cover"),
            coordinates: parseCoordinates(event),
            isDefault: isDefault,
            event: event
        )
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension RecipeBookmarkRepository.Environment {
    static var production: RecipeBookmarkRepository.Environment {
        RecipeBookmarkRepository.Environment(
            confirmList: { author, dTag in
                let relays = await RecipeBookmarkRepository.productionReadRelays(for: author)
                let result = await RelayPool.queryDetailed(
                    relays: relays,
                    filter: NostrFilter(
                        kinds: [RecipeBookmarkRepository.listKind],
                        authors: [author],
                        dTags: [dTag],
                        limit: 8
                    ),
                    timeout: RecipeBookmarkRepository.confirmTimeout,
                    waitForAllRelays: true
                )
                let newest = result.events
                    .filter { RecipeBookmarkRepository.hasDTag($0, dTag) && $0.pubkey == author }
                    .max(by: { $0.createdAt < $1.createdAt })
                return RecipeBookmarkRepository.classifyRelayListCheck(
                    newest: newest,
                    eoseCount: result.relaysResponded
                )
            },
            cachedList: { author, dTag in
                RecipeBookmarkCache.load(author: author)
                    .filter { RecipeBookmarkRepository.hasDTag($0, dTag) }
                    .max(by: { $0.createdAt < $1.createdAt })
            },
            cachedLists: { author in
                RecipeBookmarkCache.load(author: author)
            },
            persist: { event in
                RecipeBookmarkCache.upsert(event)
            },
            sign: { kind, tags, content in
                guard let keypair = NostrKey.load() else {
                    throw Signer.SignerError.localKeyMissing
                }
                return try await Signer.sign(keypair: keypair, kind: kind, tags: tags, content: content)
            },
            publish: { event in
                let writes = await RelayListRepository.shared.getWriteRelays(event.pubkey)
                _ = await RelayPool.publish(event: event, to: writes, timeout: 8)
            },
            readRelays: {
                await RecipeBookmarkRepository.productionReadRelays(for: NostrKey.load()?.pubkey ?? "")
            },
            nowMs: {
                Int64(Date().timeIntervalSince1970 * 1000)
            },
            removeCached: { author, dTag in
                RecipeBookmarkCache.remove(author: author, dTag: dTag)
            }
        )
    }
}

extension RecipeBookmarkRepository {
    static func productionReadRelays(for pubkey: String) async -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ url: String) {
            let key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            out.append(url)
        }
        for url in RelayDefaults.indexers { add(url) }
        if !pubkey.isEmpty {
            for url in await RelayListRepository.shared.getWriteRelays(pubkey) { add(url) }
        }
        return out
    }
}

/// On-device cache of the user's kind-30001 recipe lists. Kind 30001 is not
/// in ObjectBox `persistedKinds`; UserDefaults is the same layer
/// `NoteListRepository` uses for NIP-51 lists.
enum RecipeBookmarkCache {
    private static func key(_ author: String) -> String { "recipe_bookmarks_\(author)" }

    static func load(author: String) -> [NostrEvent] {
        guard let raw = UserDefaults.standard.stringArray(forKey: key(author)) else { return [] }
        return raw.compactMap(NostrEvent.fromJSON).filter { RecipeBookmarkRepository.isRecipeList($0) }
    }

    static func upsert(_ event: NostrEvent) {
        guard let dTag = RecipeBookmarkRepository.dTagOf(event) else { return }
        var byD: [String: NostrEvent] = [:]
        for existing in load(author: event.pubkey) {
            if let d = RecipeBookmarkRepository.dTagOf(existing) { byD[d] = existing }
        }
        if let current = byD[dTag], !RecipeBookmarkRepository.isNewerReplaceable(event, than: current) { return }
        byD[dTag] = event
        UserDefaults.standard.set(byD.values.map { $0.toJSON() }, forKey: key(event.pubkey))
    }

    /// Evict one list (3.2 delete) so a cache paint cannot resurrect a
    /// deleted collection.
    static func remove(author: String, dTag: String) {
        var byD: [String: NostrEvent] = [:]
        for existing in load(author: author) {
            if let d = RecipeBookmarkRepository.dTagOf(existing) { byD[d] = existing }
        }
        guard byD.removeValue(forKey: dTag) != nil else { return }
        UserDefaults.standard.set(byD.values.map { $0.toJSON() }, forKey: key(author))
    }
}
