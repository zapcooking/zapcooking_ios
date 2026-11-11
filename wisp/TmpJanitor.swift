import Foundation

/// Launch janitor for the app's `tmp/` directory.
///
/// `URLSession.shared.download(from:)` stages transfers as
/// `CFNetworkDownload_*.tmp` files inside tmp; a task that is killed,
/// fails, or whose result is never moved leaves the file behind, and iOS
/// only purges tmp under storage pressure. A long-lived install silently
/// accumulated 85 GB / 61k of these. The sweep runs once per launch,
/// before heavy startup work, and only touches download leftovers:
/// files named `CFNetworkDownload_*` untouched for over 24 hours.
///
/// Files younger than the grace window are kept: an in-flight download
/// that is about to be moved into place by its owner must not vanish
/// mid-transfer.
nonisolated enum TmpJanitor {
    /// Name prefix of URLSession download-task staging files.
    private static let downloadFilePrefix = "CFNetworkDownload_"
    /// Files older than this are considered abandoned.
    private static let staleAfter: TimeInterval = 24 * 3600

    /// What one sweep did, and on which thread it ran. `ranOnMainThread`
    /// is how the tests prove the launch path stays off the main thread.
    nonisolated struct Outcome: Sendable, Equatable {
        let removed: Int
        let ranOnMainThread: Bool
    }

    /// The launch entry point. Hops to a detached utility-priority task so
    /// the directory walk and the deletes never run on the main thread,
    /// even though `MainView`'s `.task` (main actor) awaits it. The first
    /// sweep after a long-lived install faces a 40k+ file backlog, which
    /// takes seconds.
    nonisolated static func sweepAtLaunch(now: Date = Date()) async -> Outcome {
        await Task.detached(priority: .utility) {
            sweepStaleDownloadFiles(now: now)
        }.value
    }

    /// Delete abandoned download staging files from tmp. Synchronous and
    /// runs on the caller's thread: from the main actor it would block the
    /// UI for the whole walk, so launch code calls `sweepAtLaunch()`.
    @discardableResult
    nonisolated static func sweepStaleDownloadFiles(now: Date = Date()) -> Outcome {
        let onMain = Thread.isMainThread
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = now.addingTimeInterval(-staleAfter)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return Outcome(removed: 0, ranOnMainThread: onMain) }

        var removed = 0
        // Unbounded on purpose: the first sweep after a long-lived install
        // faces a 40k+ file backlog. Off the main thread (sweepAtLaunch), a
        // multi-second cleanup once per launch is acceptable. Later launches
        // find almost nothing.
        for url in contents where
            url.lastPathComponent.hasPrefix(downloadFilePrefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            guard modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 {
            #if DEBUG
            print("[TmpJanitor] removed \(removed) stale download file(s) from tmp")
            #endif
        }
        return Outcome(removed: removed, ranOnMainThread: onMain)
    }
}
