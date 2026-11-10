import Testing
import Foundation
@testable import wisp
import Testing
import Foundation

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
}
