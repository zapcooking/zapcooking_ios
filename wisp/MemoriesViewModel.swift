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

    /// `repo` defaults to the shared instance; resolved inside the initializer
    /// because a default-argument expression is evaluated nonisolated.
    init(pubkey: String, repo: MemoriesRepository? = nil) {
        self.pubkey = pubkey
        self.repo = repo ?? .shared
    }

    var allEmpty: Bool { loaded && groups.allSatisfy { $0.events.isEmpty } }

    func load() async {
        loading = true
        defer { loading = false }
        let result = await repo.getMemoriesCached(pubkey: pubkey)
        groups = result
        loaded = true
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        refreshNotice = nil
        defer { refreshing = false }
        let (fresh, refreshed) = await repo.refreshMemories(pubkey: pubkey)
        if refreshed {
            groups = fresh
            loaded = true
        } else {
            // Timeout-empty refresh: keep the current (cached) data, explain why.
            refreshNotice = Self.refreshFailedNotice
        }
    }
}
