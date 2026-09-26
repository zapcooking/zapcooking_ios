import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// Renders the Data Recovery screen and its review in the states that carry
/// the spec's UI contract (a recommendation after a clobber, folded groups,
/// relay outcomes and an unconfirmed current, the profile field diff, the
/// intent question, the override after a failed retry) and checks each draws
/// something. With `wispTests/.zc_snapshot_dir` naming a directory, the PNGs
/// land there for review. Hermetic: relays are a scripted `LazarusRelayIO`.
@MainActor
struct LazarusRenderTests {

    private static let writeRelay = "wss://w1.example"
    private static let historyRelay = "wss://hist.example"
    private static let sets = LazarusRelaySets(
        defaults: ["wss://default.example"],
        standIns: ["wss://default.example"],
        archival: [historyRelay, "wss://slow.example"]
    )

    private func model(_ keypair: Keypair, io: ScriptedRelayIO, kind: Int) -> LazarusRecoveryViewModel {
        let pubkey = keypair.pubkey
        return LazarusRecoveryViewModel(keypair: keypair, initialKind: kind, io: io, sets: Self.sets) { env in
            env.activePubkey = { pubkey }
            env.localCopy = { _, _ in nil }
            env.adopt = { _, _ in }
        }
    }

    private func serve(_ io: ScriptedRelayIO, _ relay: String, _ events: [NostrEvent],
                       outcome: LazarusRelayOutcome = .answered) {
        let history = ScriptedRelayIO.history(events)
        io.script(relay) { filter in LazarusRelayAnswer(events: history(filter).events, outcome: outcome) }
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func pubkeys(_ n: Int, offset: Int = 0) -> [[String]] {
        (0..<n).map { i in
            let hex = String(i + offset, radix: 16)
            return ["p", String(repeating: "0", count: 64 - hex.count) + hex]
        }
    }

    /// A follow list that was curated, clobbered, and edited since.
    private func followHistory(_ keypair: Keypair, writeRelayAnswers: Bool) throws -> ScriptedRelayIO {
        let io = ScriptedRelayIO()
        let relayList = try LazarusFixture.signed(keypair, kind: 10002, createdAt: 500, tags: [["r", Self.writeRelay]])
        serve(io, "wss://default.example", [relayList])
        let base = 1_790_000_000
        let counts = [1210, 1205, 1201, 1198, 1195, 312, 315, 318]
        let versions = try counts.enumerated().map { index, count in
            try LazarusFixture.signed(keypair, kind: 3, createdAt: base + index * 3600, tags: pubkeys(count))
        }
        serve(io, Self.historyRelay, versions)
        serve(io, Self.writeRelay, [versions.last!], outcome: writeRelayAnswers ? .answered : .failed)
        serve(io, "wss://slow.example", [], outcome: .timedOut)
        return io
    }

    private func render<V: View>(_ view: V, _ name: String, height: CGFloat = 1500) throws {
        let host = Host(NavigationStack { view }.environment(\.colorScheme, .dark), height: height)
        host.pump(0.8)
        let image = try #require(host.snapshot())
        write(image, name)
        #expect(!isBlank(image), "\(name) rendered blank")
    }

    // MARK: - Screens

    @Test func rendersTheResultsWithARecommendationAndFoldedHistory() async throws {
        let keypair = try LazarusFixture.keypair()
        let model = model(keypair, io: try followHistory(keypair, writeRelayAnswers: true), kind: 3)
        model.startScan()
        try #require(await settle { model.phase == .done })
        #expect(model.scan?.recommended != nil)
        model.showRelayOutcomes = true
        try render(LazarusRecoveryView(model: model), "lazarus-results")
    }

    @Test func rendersAnUnconfirmedCurrentAndTheRelayOutcomes() async throws {
        let keypair = try LazarusFixture.keypair()
        let model = model(keypair, io: try followHistory(keypair, writeRelayAnswers: false), kind: 3)
        model.startScan()
        try #require(await settle { model.phase == .done })
        #expect(model.scan?.currentConfirmed == false)
        model.showRelayOutcomes = true
        try render(LazarusRecoveryView(model: model), "lazarus-unconfirmed")
    }

    @Test func rendersTheReviewOfARestoreThatGrowsTheList() async throws {
        let keypair = try LazarusFixture.keypair()
        let model = model(keypair, io: try followHistory(keypair, writeRelayAnswers: true), kind: 3)
        model.startScan()
        try #require(await settle { model.phase == .done })
        model.openReview(try #require(model.scan?.recommended))
        try render(LazarusReviewView(model: model), "lazarus-review-grow", height: 1100)
    }

    @Test func rendersTheOverrideAfterARetryOfTheReReadFailed() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = try followHistory(keypair, writeRelayAnswers: true)
        let model = model(keypair, io: io, kind: 3)
        model.startScan()
        try #require(await settle { model.phase == .done })
        serve(io, Self.writeRelay, [], outcome: .timedOut)
        model.openReview(try #require(model.scan?.recommended))
        model.restore()
        try #require(await settle { model.review?.status == .unconfirmed })
        model.restore()
        try #require(await settle { model.review?.unconfirmedAttempts == 2 && model.review?.status == .unconfirmed })
        try render(LazarusReviewView(model: model), "lazarus-review-override", height: 1300)
    }

    @Test func rendersAShrinkingRestoreAwaitingItsSeparateConfirmation() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = try followHistory(keypair, writeRelayAnswers: true)
        let model = model(keypair, io: io, kind: 3)
        model.startScan()
        try #require(await settle { model.phase == .done })
        // An older, smaller version than current: restoring it shrinks the list.
        let current = try #require(model.scan?.current)
        let older = try #require(model.scan?.candidates.first { !$0.isCurrent && $0.itemCount.range.max < current.itemCount.range.max })
        model.openReview(older)
        model.armShrinkConfirmation(true)
        try render(LazarusReviewView(model: model), "lazarus-review-shrink", height: 1100)
    }

    @Test func rendersTheProfileFieldDiff() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let relayList = try LazarusFixture.signed(keypair, kind: 10002, createdAt: 500, tags: [["r", Self.writeRelay]])
        serve(io, "wss://default.example", [relayList])
        let healthy = try LazarusFixture.signed(keypair, kind: 0, createdAt: 1_790_000_000,
            tags: [["emoji", "pan", "https://example.com/pan.png"]],
            content: "{\"name\":\"daniel\",\"display_name\":\"Daniel\",\"about\":\"Cooking with fire.\",\"picture\":\"https://example.com/me.jpg\",\"lud16\":\"daniel@example.com\",\"pronouns\":\"he/him\"}")
        let clobbered = try LazarusFixture.signed(keypair, kind: 0, createdAt: 1_790_100_000,
            content: "{\"name\":\"daniel\",\"bot\":false}")
        serve(io, Self.historyRelay, [healthy, clobbered])
        serve(io, Self.writeRelay, [clobbered])
        let model = model(keypair, io: io, kind: 0)
        model.startScan()
        try #require(await settle { model.phase == .done })
        model.openReview(try #require(model.scan?.candidates.first { $0.id == healthy.id }))
        #expect((model.review?.profileChanges?.count ?? 0) >= 5)
        try render(LazarusReviewView(model: model), "lazarus-review-profile", height: 1100)
    }

    @Test func rendersTheIntentQuestionForAnEncryptionKeyList() async throws {
        let keypair = try LazarusFixture.keypair()
        let io = ScriptedRelayIO()
        let relayList = try LazarusFixture.signed(keypair, kind: 10002, createdAt: 500, tags: [["r", Self.writeRelay]])
        serve(io, "wss://default.example", [relayList])
        let keys = try LazarusFixture.signed(keypair, kind: 10044, createdAt: 1_790_000_000,
                                             tags: [["n", String(repeating: "ab", count: 32)]])
        let emptied = try LazarusFixture.signed(keypair, kind: 10044, createdAt: 1_790_100_000)
        serve(io, Self.historyRelay, [keys, emptied])
        serve(io, Self.writeRelay, [emptied])
        let model = model(keypair, io: io, kind: 10044)
        model.startScan()
        try #require(await settle { model.phase == .done })
        try render(LazarusRecoveryView(model: model), "lazarus-keys-results", height: 1000)
        model.openReview(try #require(model.scan?.candidates.first { $0.id == keys.id }))
        try render(LazarusReviewView(model: model), "lazarus-review-intent", height: 1000)
    }

    // MARK: - Harness (AttachmentStripRenderTests pattern)

    private func write(_ image: UIImage, _ name: String) {
        guard let dir = Self.snapshotDirectory, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    nonisolated private static var snapshotDirectory: String? {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".zc_snapshot_dir")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = buf.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                      data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return true }
        let r0 = Int(buf[0]), g0 = Int(buf[1]), b0 = Int(buf[2])
        var i = 0
        while i < buf.count {
            if abs(Int(buf[i]) - r0) > 24 || abs(Int(buf[i + 1]) - g0) > 24 || abs(Int(buf[i + 2]) - b0) > 24 {
                return false
            }
            i += 4 * 7
        }
        return true
    }

    @MainActor private final class Host {
        let window: UIWindow

        init<Root: View>(_ root: Root, height: CGFloat) {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: height))
            window.windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            window.backgroundColor = .black
            window.rootViewController = UIHostingController(rootView: root)
            window.isHidden = false
        }

        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            window.layoutIfNeeded()
        }

        func snapshot() -> UIImage? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
    }
}
