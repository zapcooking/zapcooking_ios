import Foundation
import Observation

/// Drives the full Memories ("On this day") screen. Port of Android
/// `MemoriesViewModel`: cache-first `load`, cache-bypassing `refresh` that
/// keeps the current data and surfaces a notice when a refresh can't be
/// confirmed authoritative. Read-only — all the work lives in
/// `MemoriesRepository`.
@Observable
@MainActor
final class MemoriesViewModel {
    static let refreshFailedNotice = "Couldn't refresh — showing cached memories."

    /// Groups sorted 1 → 2 → 3 years ago.
    private(set) var groups: [MemoryGroup] = []
    private(set) var loading = false
    private(set) var refreshing = false
    /// Set to the cached-on-failure notice; cleared on a successful refresh/load.
    private(set) var refreshNotice: String?
    /// True once a load has completed (so the UI can distinguish "loading" from "empty").
    private(set) var loaded = false

    @ObservationIgnored private let repo: MemoriesRepository
    let pubkey: String

    /// Bumped by every load/refresh; a completion applies its result only if
    /// it is still the newest operation, so an older cache-first load can
    /// never land on top of a newer authoritative refresh (Copilot, PR #87).
    @ObservationIgnored private var generation = 0

    /// `repo` defaults to the shared instance; resolved inside the initializer
    /// because a default-argument expression is evaluated nonisolated.
    init(pubkey: String, repo: MemoriesRepository? = nil) {
        self.pubkey = pubkey
        self.repo = repo ?? .shared
    }

    var allEmpty: Bool { loaded && groups.allSatisfy { $0.events.isEmpty } }

    /// One relay operation at a time: a load while a load or refresh is in
    /// flight is a no-op (the running one will populate `groups`).
    var busy: Bool { loading || refreshing }

    func load() async {
        guard !busy else { return }
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        let result = await repo.getMemoriesCached(pubkey: pubkey)
        guard mine == generation else { return }
        groups = result
        loaded = true
    }

    /// Ignored while the initial load (or another refresh) is in flight —
    /// the toolbar button is disabled in that state too — so the two can
    /// never run concurrently and double the relay round.
    func refresh() async {
        guard !busy else { return }
        generation += 1
        let mine = generation
        refreshing = true
        refreshNotice = nil
        defer { if mine == generation { refreshing = false } }
        let (fresh, refreshed) = await repo.refreshMemories(pubkey: pubkey)
        guard mine == generation else { return }
        if refreshed {
            groups = fresh
            loaded = true
        } else {
            // Timeout-empty refresh: keep the current (cached) data, explain why.
            refreshNotice = Self.refreshFailedNotice
        }
    }
}
