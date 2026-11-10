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

    /// Delete abandoned download staging files from tmp. Runs on the
    /// caller's executor; called once from `MainView` before startup work.
    nonisolated static func sweepStaleDownloadFiles(now: Date = Date()) {
        let tmp = FileManager.default.temporaryDirectory
        let cutoff = now.addingTimeInterval(-staleAfter)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var removed = 0
        // Unbounded on purpose: the first sweep after a long-lived install
        // faces a 40k+ file backlog, and it runs off the main actor (from
        // MainView's .task), so a multi-second cleanup once per launch is
        // acceptable. Later launches find almost nothing.
        for url in contents where
            url.lastPathComponent.hasPrefix(downloadFilePrefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            guard modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            #if DEBUG
            print("[TmpJanitor] removed \(removed) stale download file(s) from tmp")
            #endif
        }
    }
}
