import Foundation
import Observation

@Observable
@MainActor
final class SearchViewModel {
    let keypair: Keypair

    enum Mode: String { case people, notes, recipes }
    enum RelayOption: String { case `default`, all, individual }

    // MARK: - Inputs

    var query: String = ""
    var mode: Mode = .people
    var showAdvanced: Bool = false

    var relayOption: RelayOption = .default
    var selectedRelayUrl: String?
    var savedSearchRelays: [String] = []

    var authorFilter: ProfileData?
    var authorQuery: String = ""

    // MARK: - Outputs

    var notes: [NostrEvent] = []
    var noteProfiles: [String: ProfileData] = [:]
    var people: [ProfileData] = []
    var authorResults: [ProfileData] = []
    var recipes: [RecipeResult] = []
    var recipeProfiles: [String: ProfileData] = [:]

    /// Food-hashtag / keyword completions for the current query, from the
    /// static taxonomy (`FoodHashtags.all`) — the iOS counterpart of web's
    /// `recipeTags` suggestion rows. Shown as tappable chips above the
    /// results in every mode; a tap opens the hashtag feed.
    var tagMatches: [String] = []

    var engagement: [String: EngagementCounts] = [:]
    var isSearching = false
    var isAuthorSearching = false
    var hasSearched = false

    /// True when the last search finished with zero of the queried search
    /// relays answering (EOSE). The empty result list then means "nobody
    /// answered" — relays down, network down, an outage or incident — and
    /// must surface as an explicit failure, never as "No results found".
    var searchUnreachable = false

    /// True when only some of the queried search relays answered: the result
    /// set may be incomplete. Never set together with `searchUnreachable`.
    var searchPartialCoverage = false

    // MARK: - Internals

    @ObservationIgnored private let profileRepo = ProfileRepository.shared
    @ObservationIgnored private var hideObserved = false
    @ObservationIgnored private var hideObserver: NSObjectProtocol?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var authorDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var authorSearchTask: Task<Void, Never>?
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var searchCounter: Int = 0
    @ObservationIgnored private var authorCounter: Int = 0

    /// The NIP-50 search-relay pair fanned for every full-text query — the
    /// same two the web app queries (`SEARCH_RELAYS` on zap.cooking's search
    /// page). Querying `search.nostrarchives.com` alone is what blanked
    /// search: when its index went quiet it still answered every REQ with an
    /// immediate empty EOSE, which `RelayPool.query`'s first-EOSE fast path
    /// treated as a definitive "no results". nos.today independently answers
    /// kind-0 / kind-1 / kind-30023 `search` filters (verified live), so the
    /// default is both, and search queries run with `waitForAllRelays: true`
    /// so one relay's empty EOSE can't truncate the other's stream.
    static let defaultSearchRelays = ["wss://search.nos.today", "wss://search.nostrarchives.com"]

    /// Kept for the deliberate single-relay call sites outside search
    /// (`OnlyFoodFeedViewModel.searchRelay` matches Android's hashtag path;
    /// `FoodSeedRepository` seeds its own list).
    static let defaultSearchRelay = "wss://search.nostrarchives.com"

    /// Web's search page gives its relay subscriptions 6s including connect
    /// time; match that — throttled relays answer late, not never (§7.4).
    private let searchTimeout: TimeInterval = 6
    private let engagementTimeout: TimeInterval = 10
    private let authorTimeout: TimeInterval = 4

    // MARK: - Lifecycle

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    func start() {
        loadPreferences()
        observeContentHidden()
        if profileUpdatesTask == nil {
            profileUpdatesTask = Task { @MainActor [weak self] in
                for await pk in MissingProfileWatcher.shared.updates {
                    guard let self else { return }
                    if self.notes.contains(where: { $0.pubkey == pk }),
                       let p = self.profileRepo.get(pk) {
                        self.noteProfiles[pk] = p
                    }
                    if self.recipes.contains(where: { $0.author == pk }),
                       let p = self.profileRepo.get(pk) {
                        self.recipeProfiles[pk] = p
                    }
                }
            }
        }
    }

    private func observeContentHidden() {
        guard !hideObserved else { return }
        hideObserved = true
        hideObserver = NotificationCenter.default.addObserver(
            forName: .contentHidden, object: nil, queue: .main
        ) { [weak self] note in
            let eventIds = Set(note.userInfo?[ContentHideKey.eventIds] as? [String] ?? [])
            let pubkeys = Set(note.userInfo?[ContentHideKey.pubkeys] as? [String] ?? [])
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.notes = self.notes.removingHidden(eventIds: eventIds, pubkeys: pubkeys)
                if !pubkeys.isEmpty {
                    self.people.removeAll { pubkeys.contains($0.pubkey) }
                }
            }
        }
    }

    func stop() {
        debounceTask?.cancel()
        searchTask?.cancel()
        authorDebounceTask?.cancel()
        authorSearchTask?.cancel()
        profileUpdatesTask?.cancel()
        profileUpdatesTask = nil
        if let hideObserver { NotificationCenter.default.removeObserver(hideObserver) }
        hideObserver = nil
        hideObserved = false
    }

    deinit {
        if let hideObserver { NotificationCenter.default.removeObserver(hideObserver) }
    }

    // MARK: - Persistence

    private func loadPreferences() {
        let pk = keypair.pubkey
        let opt = UserDefaults.standard.string(forKey: "search_relay_option_\(pk)") ?? "default"
        relayOption = RelayOption(rawValue: opt) ?? .default
        selectedRelayUrl = UserDefaults.standard.string(forKey: "search_relay_url_\(pk)")
        savedSearchRelays = UserDefaults.standard.stringArray(forKey: "search_relays_\(pk)") ?? []
    }

    private func savePreferences() {
        let pk = keypair.pubkey
        UserDefaults.standard.set(relayOption.rawValue, forKey: "search_relay_option_\(pk)")
        if let url = selectedRelayUrl {
            UserDefaults.standard.set(url, forKey: "search_relay_url_\(pk)")
        } else {
            UserDefaults.standard.removeObject(forKey: "search_relay_url_\(pk)")
        }
        UserDefaults.standard.set(savedSearchRelays, forKey: "search_relays_\(pk)")
    }

    // MARK: - Inputs

    func updateQuery(_ text: String) {
        // No-op when the text hasn't actually changed. SwiftUI's
        // `TextField` binding fires `set` again when the field loses
        // focus (e.g. `scrollDismissesKeyboard` during a scroll over the
        // results), passing back the same string. Without this guard,
        // every scroll cancelled the previous debounce + restarted the
        // 500 ms timer, then ran a fresh `runSearch()` that cleared the
        // visible results and re-fetched them.
        guard text != query else { return }
        // A pasted `nostr:` URI scheme is transport syntax, never search
        // terms — strip it from the field itself (the binding's `get`
        // re-reads `query`) when a NIP-19 entity follows. Plain text after
        // `nostr:` is left alone so typing the literal word isn't mangled;
        // `preprocessQuery` still drops the scheme for intent either way.
        let text = strippedNostrScheme(from: text)
        guard text != query else { return }
        query = text
        debounceTask?.cancel()
        let intent = preprocessQuery(text)
        // An explicit NIP-19 entity implies its search mode — an event
        // reference can only resolve as a note, a profile reference only
        // as a person. Re-aim the mode chip so the result actually shows.
        if let implied = impliedMode(for: text), mode != implied {
            mode = implied
        }
        // Keyword/hashtag completions track the text as typed (before the
        // 500 ms debounce), like web's autocomplete rows. Identity intents
        // (npub / hex / NIP-05 / note refs) never get tag rows.
        if case .text = intent {
            tagMatches = Self.matchingTags(for: text)
        } else {
            tagMatches = []
        }
        guard isQueryActionable(intent) else {
            if case .text(let s) = intent, s.isEmpty {
                notes = []
                people = []
                noteProfiles = [:]
                engagement = [:]
                recipes = []
                recipeProfiles = [:]
                searchUnreachable = false
                searchPartialCoverage = false
                hasSearched = false
            }
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.runSearch()
        }
    }

    func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        if isQueryActionable(preprocessQuery(query)) { runSearch() }
    }

    func setRelayOption(_ option: RelayOption, url: String? = nil) {
        relayOption = option
        if option == .individual {
            selectedRelayUrl = url ?? selectedRelayUrl
        }
        savePreferences()
        if isQueryActionable(preprocessQuery(query)) { runSearch() }
    }

    func addCustomRelay(_ url: String) {
        let normalized = normalizeRelayUrl(url)
        guard !normalized.isEmpty else { return }
        if !savedSearchRelays.contains(normalized) {
            savedSearchRelays.append(normalized)
        }
        selectedRelayUrl = normalized
        relayOption = .individual
        savePreferences()
    }

    func removeCustomRelay(_ url: String) {
        savedSearchRelays.removeAll { $0 == url }
        if selectedRelayUrl == url {
            selectedRelayUrl = nil
            if relayOption == .individual { relayOption = .default }
        }
        savePreferences()
    }

    func setAuthorFilter(_ profile: ProfileData?) {
        authorFilter = profile
        authorResults = []
        authorQuery = ""
        if mode == .notes, isQueryActionable(preprocessQuery(query)) {
            runSearch()
        }
    }

    func updateAuthorQuery(_ text: String) {
        authorQuery = text
        authorDebounceTask?.cancel()
        guard case .text(let trimmed) = preprocessQuery(text), trimmed.count >= 2 else {
            authorResults = []
            return
        }
        authorDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.runAuthorSearch(trimmed)
        }
    }

    // MARK: - Search

    func runSearch() {
        let intent = preprocessQuery(query)
        guard isQueryActionable(intent) else { return }

        // A pasted event reference is only ever a direct note lookup —
        // re-align the mode in case the user toggled People with the
        // reference still in the field.
        if case .eventRef = intent, mode != .notes { mode = .notes }

        searchCounter += 1
        let myCounter = searchCounter
        let mode = self.mode

        searchTask?.cancel()
        isSearching = true
        hasSearched = true
        searchUnreachable = false
        searchPartialCoverage = false
        if mode == .notes {
            notes = []
            engagement = [:]
            noteProfiles = [:]
        } else if mode == .recipes {
            recipes = []
            recipeProfiles = [:]
        } else {
            people = []
        }

        let timeout = searchTimeout
        searchTask = Task { [weak self] in
            guard let self else { return }

            if mode == .people, case .nip05(let identifier) = intent {
                let pubkey = await Nip05Verifier.lookup(identifier: identifier)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard myCounter == self.searchCounter else { return }
                    if let pubkey {
                        self.runPubkeyFetch(pubkey: pubkey, counter: myCounter, timeout: timeout)
                    } else {
                        // NIP-05 lookup failed — nothing to show
                        self.people = []
                        self.isSearching = false
                    }
                }
                return
            }

            // Direct id lookup for a pasted note1/nevent1 — queries the
            // nevent's relay hints plus discovery relays, and verifies the
            // result against the requested id (see runEventLookup).
            if case .eventRef(let id, let hints) = intent {
                await self.runEventLookup(id: id, relayHints: hints, counter: myCounter)
                return
            }

            let relays = self.relaysToQuery()
            guard !relays.isEmpty else {
                await MainActor.run { self.isSearching = false }
                return
            }

            let filter: NostrFilter
            let queryRelays: [String]
            switch mode {
            case .people:
                switch intent {
                case .pubkey(let pubkey):
                    filter = NostrFilter(kinds: [0], authors: [pubkey], limit: 1)
                    let combined = (Self.defaultSearchRelays + Array(RelayDefaults.indexers))
                        .reduce(into: [String]()) { acc, url in if !acc.contains(url) { acc.append(url) } }
                    queryRelays = combined
                case .text(let trimmed):
                    filter = NostrFilter(kinds: [0], limit: 20, search: trimmed)
                    queryRelays = relays
                case .nip05, .eventRef:
                    // Handled above via the early-return paths
                    return
                }
            case .notes:
                let authorPubkey = self.authorFilter?.pubkey
                guard case .text(let trimmed) = intent else {
                    // Identity intents (pubkey / NIP-05) have no notes-mode
                    // form — end the search instead of stranding the spinner.
                    await MainActor.run {
                        guard myCounter == self.searchCounter else { return }
                        self.isSearching = false
                    }
                    return
                }
                filter = NostrFilter(
                    kinds: [1],
                    authors: authorPubkey.map { [$0] },
                    limit: 50,
                    search: trimmed
                )
                queryRelays = relays
            case .recipes:
                // Web's recipe filter: kind-30023 long-form events carrying a
                // zapcooking/nostrcooking `t` tag. (Web also queries kind
                // 35000, its legacy premium-recipe kind; iOS's format seam and
                // RecipeRoute are 30023-only, so those hits could not open.)
                guard case .text(let trimmed) = intent else {
                    await MainActor.run {
                        guard myCounter == self.searchCounter else { return }
                        self.isSearching = false
                    }
                    return
                }
                filter = NostrFilter(
                    kinds: [RecipeParser.recipeKind],
                    tTags: RecipeParser.recipeHashtags,
                    limit: 25,
                    search: trimmed
                )
                queryRelays = relays
            }

            // `waitForAllRelays`: the point of the two-relay fan-out is that
            // either search relay can be the only one answering today — the
            // first-EOSE fast path would let one relay's instant empty EOSE
            // truncate the other's stream and look like zero results.
            // queryDetailed (not query): "no relay answered at all" must be
            // distinguishable from "answered, nothing matched" — when the
            // search relays are down or under attack, an empty result list
            // would tell the user the content doesn't exist.
            let outcome = await RelayPool.queryDetailed(
                relays: queryRelays, filter: filter, timeout: timeout, waitForAllRelays: true
            )
            guard !Task.isCancelled else { return }
            let events = outcome.events
            let coverage = Self.coverageFlags(
                responded: outcome.relaysResponded, queried: queryRelays.count
            )

            if mode == .people, case .text(let trimmed) = intent {
                // Username index alongside the relay kind-0s (web queries
                // Primal + nostrarchives the same way). Either source answering
                // alone is a usable result set; a 3s ceiling keeps a hung index
                // from stretching the search past the relay timeout.
                let suggestions = await Self.withTimeout(seconds: 3) {
                    (try? await NostrArchivesClient.suggest(query: trimmed, limit: 20)) ?? []
                } ?? []
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard myCounter == self.searchCounter else { return }
                    self.searchUnreachable = coverage.unreachable
                    self.searchPartialCoverage = coverage.partial
                    self.handlePeopleResults(events, suggestions: suggestions, query: trimmed)
                    self.isSearching = false
                }
            } else {
                await MainActor.run {
                    guard myCounter == self.searchCounter else { return }
                    self.searchUnreachable = coverage.unreachable
                    self.searchPartialCoverage = coverage.partial
                    switch mode {
                    case .people: self.handlePeopleResults(events)
                    case .notes:  self.handleNoteResults(events)
                    case .recipes: self.handleRecipeResults(events)
                    }
                    self.isSearching = false
                }
            }
        }
    }

    /// How to present an empty (or thin) result set: zero of the queried
    /// relays answered means the search never really ran — relays down,
    /// network down, or an incident like nostrarchives' — and must surface
    /// as an explicit failure, never as "No results found". Some-but-not-all
    /// answering means the set may be incomplete.
    static func coverageFlags(responded: Int, queried: Int) -> (unreachable: Bool, partial: Bool) {
        guard queried > 0 else { return (false, false) }
        return (responded == 0, responded > 0 && responded < queried)
    }

    private static func withTimeout<T>(seconds: TimeInterval, _ op: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Fetch a single kind-0 by pubkey after a NIP-05 lookup resolved the pubkey.
    /// Runs a new sub-task so the NIP-05 path can return early from its task.
    private func runPubkeyFetch(pubkey: String, counter: Int, timeout: TimeInterval) {
        let filter = NostrFilter(kinds: [0], authors: [pubkey], limit: 1)
        let combined = (Self.defaultSearchRelays + Array(RelayDefaults.indexers))
            .reduce(into: [String]()) { acc, url in if !acc.contains(url) { acc.append(url) } }
        searchTask = Task { [weak self] in
            let events = await RelayPool.query(relays: combined, filter: filter, timeout: timeout)
            guard let self else { return }
            await MainActor.run {
                guard counter == self.searchCounter else { return }
                self.handlePeopleResults(events)
                self.isSearching = false
            }
        }
    }

    /// Direct event-id lookup for a pasted `note1` / `nevent1` reference.
    /// Queries the nevent's relay hints plus the search + indexer relays,
    /// and only accepts an event whose *recomputed* id matches the request:
    /// a misbehaving relay can answer an `ids:` filter with a different
    /// note (or forge the requested id onto different content), and
    /// first-event-wins would render the wrong note.
    private func runEventLookup(id: String, relayHints: [String], counter: Int) async {
        var seen = Set<String>()
        var relays: [String] = []
        for raw in relayHints {
            let url = normalizeRelayUrl(raw)
            if !url.isEmpty, seen.insert(url).inserted { relays.append(url) }
        }
        for url in relaysToQuery() where seen.insert(url).inserted { relays.append(url) }
        for url in RelayDefaults.indexers where seen.insert(url).inserted { relays.append(url) }

        var filter = NostrFilter()
        filter.ids = [id]
        filter.limit = 1
        let events = await RelayPool.query(relays: relays, filter: filter, timeout: searchTimeout)
        guard !Task.isCancelled, counter == searchCounter else { return }

        let match = events.first { event in
            event.id == id && NostrEvent.computeId(
                pubkey: event.pubkey,
                createdAt: event.createdAt,
                kind: event.kind,
                tags: event.tags,
                content: event.content
            ) == id
        }
        handleNoteResults(match.map { [$0] } ?? [])
        // Fire the kind-5 check in the background so it doesn't delay the
        // search result. If a deletion is found the tracker updates and
        // `shouldDrop` hides the note on the next render cycle — the user
        // may see it flash briefly before it disappears, but the search
        // itself isn't slowed by a second serial query.
        if let match {
            let lookupRelays = relays
            let matchId = match.id
            let matchAuthor = match.pubkey
            Task { [weak self] in
                let deletionFilter = NostrFilter(
                    kinds: [Nip09.kindDeletion], authors: [matchAuthor],
                    eTags: [matchId], limit: 50
                )
                let deletions = await RelayPool.query(
                    relays: lookupRelays, filter: deletionFilter, timeout: 4
                )
                if !deletions.isEmpty {
                    DeletionTracker.shared.ingestBatch(deletions)
                    // Re-run the same results through the filter so the note
                    // disappears without waiting for the next user action.
                    guard let self, !Task.isCancelled else { return }
                    await MainActor.run {
                        self.notes = self.notes.filter {
                            !DeletionTracker.shared.isDeleted($0.id)
                        }
                    }
                }
            }
        }
        isSearching = false
    }

    private func handlePeopleResults(
        _ events: [NostrEvent],
        suggestions: [NostrArchivesClient.Suggestion] = [],
        query: String? = nil
    ) {
        var seen = Set<String>()
        var results: [ProfileData] = []
        // Blocked users still surface here (unlike note search) — it's the
        // only way to find someone again to unblock them, since their notes
        // and profile no longer appear anywhere else. Kind-0 is WoT-exempt
        // by design (profiles stay resolvable), so people search keeps
        // working with the WoT filter on.
        for event in events where event.kind == 0 {
            guard seen.insert(canonicalPubkey(event.pubkey)).inserted else { continue }
            if let profile = profileRepo.updateFromEvent(event) {
                results.append(profile)
            } else {
                results.append(ProfileData(pubkey: event.pubkey))
            }
        }

        if let query {
            // Username-index rows paint straight from the API payload (name,
            // picture, nip05 — web's suggestion rows do the same), with the
            // profile cache preferred where a kind-0 already landed.
            for suggestion in suggestions {
                let key = canonicalPubkey(suggestion.pubkey)
                guard key.count == 64, seen.insert(key).inserted else { continue }
                if let cached = profileRepo.get(key) {
                    results.append(cached)
                    continue
                }
                var json: [String: Any] = [:]
                if let name = suggestion.name { json["name"] = name }
                if let display = suggestion.display_name { json["display_name"] = display }
                if let nip05 = suggestion.nip05 { json["nip05"] = nip05 }
                if let about = suggestion.about { json["about"] = about }
                if let picture = suggestion.picture { json["picture"] = picture }
                results.append(ProfileData(pubkey: key, json: json))
            }
            let follows = FollowsCache.shared.followsSet(for: keypair.pubkey)
            people = Self.rankedPeople(results, query: query, follows: follows)
            let missing = Set(people.map(\.pubkey)).filter { profileRepo.get($0) == nil }
            if !missing.isEmpty {
                MissingProfileWatcher.shared.observePubkeys(missing)
            }
            return
        }

        let follows = FollowsCache.shared.followsSet(for: keypair.pubkey)
        results.sort { lhs, rhs in
            let lf = follows.contains(lhs.pubkey)
            let rf = follows.contains(rhs.pubkey)
            if lf != rf { return lf && !rf }
            return false
        }
        people = results
    }

    private func handleNoteResults(_ events: [NostrEvent]) {
        var seen = Set<String>()
        var ordered: [NostrEvent] = []
        // Kind 1111 admitted alongside kind 1: `runEventLookup` resolves a
        // pasted note1/nevent1 by id, so a NIP-22 comment reaches here intact
        // and would otherwise be dropped as "No results found".
        for event in events where event.kind == 1 || event.kind == Nip22.kindComment {
            // Search was the one surface with no safety gate at all — relay
            // text search (and pasted note1/nevent1 lookups) returned
            // arbitrary-author events straight into the result list. Same
            // rule as the feed: blocked / muted-word / non-WoT content never
            // renders, even when the user explicitly went looking.
            if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
            if seen.insert(event.id).inserted {
                ordered.append(event)
            }
        }
        notes = ordered

        // Seed profiles from cache so names/avatars render immediately.
        var seedProfiles: [String: ProfileData] = [:]
        for pubkey in Set(ordered.map(\.pubkey)) {
            if let p = profileRepo.get(pubkey) {
                seedProfiles[pubkey] = p
            }
        }
        noteProfiles = seedProfiles

        let ids = ordered.map(\.id)
        let missingPubkeys = Set(ordered.map(\.pubkey)).filter { noteProfiles[$0] == nil }
        Task { [weak self] in
            await self?.loadEngagement(for: ids)
        }
        if !missingPubkeys.isEmpty {
            MissingProfileWatcher.shared.observePubkeys(missingPubkeys)
        }
    }

    private func handleRecipeResults(_ events: [NostrEvent]) {
        var seen = Set<String>()
        var results: [RecipeResult] = []
        for event in events {
            guard let result = Self.recipeResult(from: event) else { continue }
            guard seen.insert(result.id).inserted else { continue }
            results.append(result)
        }
        recipes = results

        // Seed author names/avatars from cache; the rest resolve through the
        // same missing-profile watcher the note results use.
        var seed: [String: ProfileData] = [:]
        for pubkey in Set(results.map(\.author)) {
            if let p = profileRepo.get(pubkey) {
                seed[pubkey] = p
            }
        }
        recipeProfiles = seed
        let missing = Set(results.map(\.author)).filter { recipeProfiles[$0] == nil }
        if !missing.isEmpty {
            MissingProfileWatcher.shared.observePubkeys(missing)
        }
    }

    // MARK: - Engagement

    private func loadEngagement(for ids: [String]) async {
        guard !ids.isEmpty else { return }
        let relays = engagementRelays()
        let kinds = [1, 6, 7, 9735]
        let chunks = ids.chunked(into: 200)
        let timeout = engagementTimeout
        await withTaskGroup(of: [NostrEvent].self) { group in
            for chunk in chunks {
                group.addTask {
                    await RelayPool.query(
                        relays: relays,
                        filter: NostrFilter(kinds: kinds, eTags: chunk, limit: 500),
                        timeout: timeout
                    )
                }
            }
            for await batch in group {
                ingestEngagement(batch)
            }
        }
    }

    private func ingestEngagement(_ events: [NostrEvent]) {
        for event in events {
            guard let target = event.tags.first(where: { $0.first == "e" && $0.count >= 2 })?[1] else { continue }
            var current = engagement[target] ?? EngagementCounts()
            switch event.kind {
            case 1:
                current.replies += 1
            case 6:
                current.reposts += 1
            case 7:
                current.reactions += 1
                let reactor = Reactor(
                    pubkey: event.pubkey,
                    emoji: event.content,
                    customEmojiUrl: EngagementRepository.customEmojiUrl(for: event.content, in: event.tags)
                )
                if !current.reactors.contains(where: { $0.pubkey == reactor.pubkey && $0.emoji == reactor.emoji }) {
                    current.reactors.append(reactor)
                }
            case 9735:
                if let bolt = event.tags.first(where: { $0.first == "bolt11" && $0.count >= 2 })?[1],
                   let decoded = Bolt11.decode(bolt),
                   let sats = decoded.amountSats {
                    current.zapSats += sats
                    current.zapCount += 1
                } else {
                    current.zapCount += 1
                }
            default: break
            }
            engagement[target] = current
        }
    }

    // MARK: - Author autocomplete

    private func runAuthorSearch(_ trimmed: String) {
        authorCounter += 1
        let myCounter = authorCounter
        let relays = relaysToQuery()
        guard !relays.isEmpty else { return }
        isAuthorSearching = true
        authorSearchTask?.cancel()
        let timeout = authorTimeout
        authorSearchTask = Task { [weak self] in
            let events = await RelayPool.query(
                relays: relays,
                filter: NostrFilter(kinds: [0], limit: 10, search: trimmed),
                timeout: timeout,
                waitForAllRelays: true
            )
            guard let self else { return }
            await MainActor.run {
                guard myCounter == self.authorCounter else { return }
                var seen = Set<String>()
                var results: [ProfileData] = []
                let blocked = SafetyFilter.shared.snapshot.blockedPubkeys
                for event in events where event.kind == 0 {
                    // Same rule as `handlePeopleResults`: blocked users never
                    // surface, here in the author-filter autocomplete.
                    if blocked.contains(event.pubkey) { continue }
                    guard seen.insert(self.canonicalPubkey(event.pubkey)).inserted else { continue }
                    if let profile = self.profileRepo.updateFromEvent(event) {
                        results.append(profile)
                    } else {
                        results.append(ProfileData(pubkey: event.pubkey))
                    }
                }
                self.authorResults = Array(results.prefix(10))
                self.isAuthorSearching = false
            }
        }
    }

    // MARK: - Search intent

    enum SearchIntent {
        case text(String)     // full-text search via NIP-50
        case pubkey(String)   // resolved hex pubkey → authors: filter
        case nip05(String)    // name@domain → async HTTP lookup → authors: filter
        case eventRef(id: String, relays: [String])  // note1/nevent1 → ids: lookup
    }

    /// One recipe row: the addressable coordinate plus the display title.
    /// The detail page re-loads the event itself, so the event needn't be kept.
    struct RecipeResult: Identifiable, Equatable {
        let author: String
        let dTag: String
        let title: String

        var id: String {
            RecipeRepository.coordinate(kind: RecipeParser.recipeKind, author: author, dTag: dTag)
        }
    }

    // MARK: - Helpers

    /// Keyword / hashtag completions from the static food taxonomy — iOS's
    /// counterpart of web's `recipeTags` suggestion rows. Prefix matches come
    /// first, then substring matches, capped at `limit`.
    static func matchingTags(for query: String, limit: Int = 8) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        var prefix: [String] = []
        var contains: [String] = []
        for tag in FoodHashtags.all {
            let t = tag.lowercased()
            if t.hasPrefix(q) { prefix.append(tag) }
            else if t.contains(q) { contains.append(tag) }
        }
        return Array((prefix + contains).prefix(limit))
    }

    /// Client-side recheck of a relay's answer to the recipe filter — search
    /// relays sometimes ignore `#t`/kind constraints, and web's
    /// `recipeSearchResult` guards the same way. Web additionally accepts
    /// kind 35000 (its legacy premium-recipe kind); iOS's format seam and
    /// `RecipeRoute` are kind-30023 only, so a 35000 hit would route to a
    /// detail page that can never load it — those stay out of results.
    static func recipeResult(from event: NostrEvent) -> RecipeResult? {
        guard event.kind == RecipeParser.recipeKind else { return nil }
        let tagged = event.tags.contains {
            $0.count >= 2 && $0[0] == "t"
                && RecipeParser.recipeHashtags.contains($0[1].lowercased())
        }
        guard tagged else { return nil }

        let d = RecipeParser.dTag(event)
        guard !d.isEmpty else { return nil }
        let pubkey = event.pubkey.lowercased()
        guard pubkey.count == 64, pubkey.allSatisfy({ $0.isHexDigit }) else { return nil }

        guard !HiddenRecipes.isHidden(kind: RecipeParser.recipeKind, pubkey: pubkey, dTag: d)
        else { return nil }
        let coordinate = RecipeRepository.coordinate(
            kind: RecipeParser.recipeKind, author: pubkey, dTag: d
        )
        guard !ReportedContent.shared.isHidden(coordinate: coordinate) else { return nil }

        let title = event.tags
            .first(where: { $0.count >= 2 && $0[0] == "title" })?
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RecipeResult(author: pubkey, dTag: d, title: (title?.isEmpty == false) ? title! : d)
    }

    /// Port of web `rankProfiles`: exact name, name prefix, NIP-05 local-part
    /// exact, NIP-05 prefix, then the rest. Within a tier, followed accounts
    /// surface first (the old iOS ordering), then input order — relay kind-0
    /// rows are passed in ahead of index-only rows.
    static func rankedPeople(
        _ profiles: [ProfileData], query: String, follows: Set<String>
    ) -> [ProfileData] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func tier(_ p: ProfileData) -> Int {
            let names = [p.displayName, p.name].compactMap { $0?.lowercased() }
            if names.contains(q) { return 0 }
            if names.contains(where: { $0.hasPrefix(q) }) { return 1 }
            let local = p.nip05?.split(separator: "@").first.map { String($0).lowercased() }
            if local == q { return 2 }
            if local?.hasPrefix(q) == true { return 3 }
            return 4
        }
        return profiles.enumerated()
            .sorted { a, b in
                let (ta, tb) = (tier(a.element), tier(b.element))
                if ta != tb { return ta < tb }
                let (fa, fb) = (follows.contains(a.element.pubkey), follows.contains(b.element.pubkey))
                if fa != fb { return fa && !fb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// Collapse the different string forms the same identity can arrive in
    /// from a search relay — mixed-case or whitespace-padded hex, or an
    /// `npub` / `nprofile` in place of raw hex — down to one canonical
    /// lowercase-hex key. Without this, two index entries for one account
    /// slip past the `Set`-based dedup and render as duplicate rows.
    private func canonicalPubkey(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1"),
           case .profileRef(let hex, _)? = Nip19.decodeNostrUri(lower) {
            return hex
        }
        return lower
    }

    func relaysToQuery() -> [String] {
        switch relayOption {
        case .default:
            return Self.defaultSearchRelays
        case .all:
            let combined = (Self.defaultSearchRelays + savedSearchRelays).reduce(into: [String]()) { acc, url in
                if !acc.contains(url) { acc.append(url) }
            }
            return combined.isEmpty ? Self.defaultSearchRelays : combined
        case .individual:
            if let url = selectedRelayUrl, !url.isEmpty { return [url] }
            return Self.defaultSearchRelays
        }
    }

    private func engagementRelays() -> [String] {
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            let top = board.scoredRelays.prefix(20).map(\.url)
            if !top.isEmpty { return top }
        }
        return RelayDefaults.fallbacks
    }

    private func preprocessQuery(_ text: String) -> SearchIntent {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a sole leading `@` so a user who reflexively types
        // `@scrubby` (the composer-mention syntax) gets matched against
        // the same content the bare-handle form would. NIP-05 lookups
        // like `_@domain.com` still parse because the `_` precedes the
        // `@` — we only drop the very first `@` if it's at position 0.
        if s.hasPrefix("@") { s = String(s.dropFirst()) }
        if s.lowercased().hasPrefix("nostr:") { s = String(s.dropFirst("nostr:".count)) }

        let lower = s.lowercased()

        // npub / nprofile → decode to hex pubkey
        if lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1") {
            if let data = Nip19.decodeNostrUri(s), case .profileRef(let pubkey, _) = data {
                return .pubkey(pubkey)
            }
        }

        // note / nevent → decode to a direct event-id lookup
        if lower.hasPrefix("note1") || lower.hasPrefix("nevent1") {
            if let data = Nip19.decodeNostrUri(s),
               case .noteRef(let eventId, let relays, _) = data, !eventId.isEmpty {
                return .eventRef(id: eventId, relays: relays)
            }
        }

        // Bare 64-char hex pubkey
        if s.count == 64, s.allSatisfy({ $0.isHexDigit }) {
            return .pubkey(s.lowercased())
        }

        // NIP-05 identifier: name@domain or _@domain
        if s.contains("@") {
            let parts = s.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") {
                return .nip05(s)
            }
        }

        return .text(s)
    }

    private func isQueryActionable(_ intent: SearchIntent) -> Bool {
        switch intent {
        case .text(let s): return s.count >= 2
        case .pubkey, .nip05, .eventRef: return true
        }
    }

    /// Visible-field form of the `nostr:` strip: drop the scheme only when a
    /// NIP-19 entity actually follows, so a paste shows the bare entity but
    /// someone typing the literal text "nostr:..." keeps their input.
    private func strippedNostrScheme(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("nostr:") else { return text }
        let rest = String(trimmed.dropFirst("nostr:".count))
        let restLower = rest.lowercased()
        let entityPrefixes = ["npub1", "nprofile1", "note1", "nevent1", "naddr1"]
        guard entityPrefixes.contains(where: { restLower.hasPrefix($0) }) else { return text }
        return rest
    }

    /// Mode implied by an explicit NIP-19 entity at the head of the query,
    /// or nil when the text doesn't pin one down.
    private func impliedMode(for text: String) -> Mode? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("@") { s = String(s.dropFirst()) }
        if s.hasPrefix("nostr:") { s = String(s.dropFirst("nostr:".count)) }
        if s.hasPrefix("note1") || s.hasPrefix("nevent1") { return .notes }
        if s.hasPrefix("npub1") || s.hasPrefix("nprofile1") { return .people }
        return nil
    }

    private func normalizeRelayUrl(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") { return trimmed }
        return "wss://" + trimmed
    }
}
