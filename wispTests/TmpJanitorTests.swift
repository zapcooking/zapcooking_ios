import Testing
import Foundation
@testable import wisp

/// The launch janitor that keeps CFNetworkDownload leftovers from stacking
/// up (85 GB / 61k files on a long-lived test install).
final class TmpJanitorTests {
    private func makeFile(named name: String, modified: Date) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path
        )
        return url
    }

    @Test func sweep_removesStaleDownloadFiles() throws {
        let stale = try makeFile(
            named: "CFNetworkDownload_stale.tmp",
            modified: Date().addingTimeInterval(-25 * 3600)
        )
        TmpJanitor.sweepStaleDownloadFiles()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func sweep_sparesFreshDownloads() throws {
        let fresh = try makeFile(named: "CFNetworkDownload_fresh.tmp", modified: Date())
        TmpJanitor.sweepStaleDownloadFiles()
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        try? FileManager.default.removeItem(at: fresh)
    }

    @Test func sweep_leavesNonDownloadFilesAlone() throws {
        let keep = try makeFile(
            named: "tmpjanitor-unrelated.json",
            modified: Date().addingTimeInterval(-25 * 3600)
        )
        TmpJanitor.sweepStaleDownloadFiles()
        #expect(FileManager.default.fileExists(atPath: keep.path))
        try? FileManager.default.removeItem(at: keep)
    }

    // MARK: - Which thread the sweep runs on

    /// Control: called synchronously from the main actor, the sweep runs on
    /// the main thread and says so. This is what MainView's `.task` did
    /// before `sweepAtLaunch`, and it proves the probe below can read true.
    @MainActor @Test func directSweep_fromTheMainActor_runsOnTheMainThread() {
        let outcome = TmpJanitor.sweepStaleDownloadFiles()
        #expect(outcome.ranOnMainThread)
    }

    /// The launch path: awaited from the main actor (as MainView does), the
    /// walk and the deletes still run off the main thread, and the stale
    /// file is gone when the await returns.
    @MainActor @Test func launchSweep_fromTheMainActor_runsOffTheMainThread() async throws {
        let stale = try makeFile(
            named: "CFNetworkDownload_launch-\(UUID().uuidString).tmp",
            modified: Date().addingTimeInterval(-25 * 3600)
        )
        let outcome = await TmpJanitor.sweepAtLaunch()
        #expect(!outcome.ranOnMainThread)
        #expect(outcome.removed >= 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    /// Tripwire: MainView's launch task calls the off-main entry point, not
    /// the synchronous sweep.
    @Test func mainView_launchesTheSweepOffTheMainThread() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("MainView.swift"), encoding: .utf8
        )
        let code = source.components(separatedBy: "\n").map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
        #expect(code.contains("await TmpJanitor.sweepAtLaunch()"))
        #expect(!code.contains("TmpJanitor.sweepStaleDownloadFiles("))
    }
}
