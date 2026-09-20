import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// Compose toolbar cleanup: the Proof of Work shield is gone from the row
/// (and note PoW defaults off), the content-warning control is an
/// eye-slash and the schedule control a calendar, Publish says why it is
/// greyed out, and the OnlyFood pills are one outlined row with a "+".
/// Rendered at the narrowest supported width (375pt); PNGs land in the
/// directory named by the git-ignored `wispTests/.zc_snapshot_dir`.
/// Hermetic.
@MainActor
struct ComposeToolbarTests {
    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func composer(mode: ComposeMode = .new, pills: Bool = false) -> ComposeViewModel {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: "compose_autosave_new_\(kp.pubkey)")
        return ComposeViewModel(
            keypair: kp, mode: mode,
            suggestedHashtags: pills ? OnlyFoodCompose.suggestedTags : []
        )
    }

    private func attachment(url: String?) -> ComposeAttachment {
        ComposeAttachment(
            id: UUID(), url: url, mime: "image/jpeg", dim: CGSize(width: 10, height: 10),
            durationSec: nil, sha256Hex: nil, localBytes: nil
        )
    }

    // MARK: - The row: no shield, action glyphs

    @Test func newPostRow_isSixControls_withoutProofOfWork() {
        let controls = ComposeActionsRow.controls(mode: .new, pollEnabled: false, galleryMode: false)
        #expect(controls == [
            "Add photos", "Paste image from clipboard", "Add GIF",
            "Mark as sensitive", "Create poll", "Schedule post",
        ])
        #expect(!controls.contains { $0.localizedCaseInsensitiveContains("proof") })
    }

    @Test func pollRow_keepsSensitiveAndSchedule() {
        let controls = ComposeActionsRow.controls(mode: .new, pollEnabled: true, galleryMode: false)
        #expect(controls == ["Mark as sensitive", "Create poll", "Schedule post"])
    }

    @Test func sensitiveGlyph_isEyeSlash_notAWarningTriangle() {
        #expect(ComposeActionsRow.sensitiveGlyph(marked: false) == "eye.slash")
        #expect(ComposeActionsRow.sensitiveGlyph(marked: true) == "eye.slash.fill")
        #expect(UIImage(systemName: "eye.slash") != nil)
        #expect(UIImage(systemName: "eye.slash.fill") != nil)
    }

    @Test func scheduleGlyph_isACalendar_notAClock() {
        #expect(ComposeActionsRow.scheduleGlyph(scheduled: false) == "calendar")
        #expect(ComposeActionsRow.scheduleGlyph(scheduled: true) == "calendar.badge.checkmark")
        #expect(UIImage(systemName: "calendar.badge.checkmark") != nil)
    }

    /// The feature behind the eye-slash is unchanged: an empty
    /// `content-warning` tag (NIP-36).
    @Test func markingSensitive_stillSetsTheContentWarningFlag() {
        let vm = composer()
        #expect(!vm.explicit)
        vm.toggleNsfw()
        #expect(vm.explicit)
    }

    // MARK: - Proof of Work: off by default for notes, settings untouched otherwise

    @Test func notePow_defaultsOff_reactionsAndDmsKeepTheirDefaults() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: "pow_note_enabled")
        d.removeObject(forKey: "pow_note_enabled")
        defer {
            if let saved { d.set(saved, forKey: "pow_note_enabled") } else { d.removeObject(forKey: "pow_note_enabled") }
        }
        let snapshot = PowPreferences.snapshot()
        #expect(snapshot.noteEnabled == false)
        #expect(snapshot.noteDifficulty == 16, "difficulty default is untouched")
        // A stored choice survives the default change.
        d.set(true, forKey: "pow_note_enabled")
        #expect(PowPreferences.snapshot().noteEnabled == true)
    }

    // MARK: - Publish says why

    @Test func publishBlocker_emptyText_saysSo() {
        let vm = composer()
        #expect(vm.publishBlocker == "Write something or add a photo.")
        #expect(!vm.canPublish)
        vm.updateContent("Soup night")
        #expect(vm.publishBlocker == nil)
        #expect(vm.canPublish)
    }

    @Test func publishBlocker_uploadInFlight_waits() {
        let vm = composer()
        vm.updateContent("Soup night")
        vm.attachments = [attachment(url: nil)]
        #expect(vm.publishBlocker == "Wait for uploads to finish.")
        #expect(!vm.canPublish)
        vm.attachments = [attachment(url: "https://blossom.example/a.jpg")]
        #expect(vm.publishBlocker == nil)
        vm.uploadProgress = "Uploading GIF…"
        #expect(vm.publishBlocker == "Wait for uploads to finish.")
    }

    @Test func publishBlocker_gallery_needsAPhoto() {
        let vm = composer()
        vm.toggleGallery()
        #expect(vm.galleryMode)
        #expect(vm.publishBlocker == "Add a photo.")
        vm.attachments = [attachment(url: nil)]
        #expect(vm.publishBlocker == "Wait for uploads to finish.")
        vm.attachments = [attachment(url: "https://blossom.example/a.jpg")]
        #expect(vm.publishBlocker == nil)
    }

    @Test func publishBlocker_poll_questionThenOptions() {
        let vm = composer()
        vm.togglePoll()
        #expect(vm.pollEnabled)
        #expect(vm.publishBlocker == "Add a question.")
        vm.updateContent("Best breakfast?")
        #expect(vm.publishBlocker == "Add at least 2 options.")
        vm.pollOptions = ["Eggs", "Oats"]
        #expect(vm.publishBlocker == nil)
    }

    // MARK: - Pills: one row, as many as fit, then "+"

    @Test func visiblePillCount_reservesRoomForThePlus() {
        let widths: [CGFloat] = [70, 60, 66, 76, 60, 56, 62, 50]
        // 32 (+) + 8 + 70 + 8 + 60 + 8 + 66 = 252; the next pill needs 336.
        #expect(OnlyFoodCompose.visiblePillCount(widths: widths, plusWidth: 32, spacing: 8, available: 300) == 3)
        #expect(OnlyFoodCompose.visiblePillCount(widths: widths, plusWidth: 32, spacing: 8, available: 1000) == 8)
        #expect(OnlyFoodCompose.visiblePillCount(widths: widths, plusWidth: 32, spacing: 8, available: 40) == 0)
        #expect(OnlyFoodCompose.visiblePillCount(widths: [], plusWidth: 32, spacing: 8, available: 300) == 0)
    }

    /// At 375pt (343 after the gutters) the row shows the head of the list
    /// and the "+", and the pills it shows really fit: measured, plus the
    /// next pill would not.
    @Test func narrowestDevice_showsAFewPillsAndThePlus_andTheyFit() {
        let available: CGFloat = 375 - 2 * 16
        let tags = OnlyFoodCompose.suggestedTags
        let count = HashtagPillMetrics.visibleCount(tags: tags, available: available)
        #expect(count >= 3 && count < tags.count, "\(count) pills at 375pt")
        let font = HashtagPillMetrics.uiFont()
        func total(_ n: Int) -> CGFloat {
            tags.prefix(n).map { HashtagPillMetrics.pillWidth(label: "#\($0)", font: font) }.reduce(0, +)
                + CGFloat(n) * HashtagPillMetrics.spacing + HashtagPillMetrics.plusWidth()
        }
        #expect(total(count) <= available)
        #expect(total(count + 1) > available)
        #expect(Array(tags.prefix(count)).first == OnlyFoodCompose.defaultTag)
    }

    @Test func widerRow_showsAllEight() {
        let count = HashtagPillMetrics.visibleCount(tags: OnlyFoodCompose.suggestedTags, available: 1200)
        #expect(count == OnlyFoodCompose.suggestedTags.count)
    }

    // MARK: - Renders at 375pt

    @Test func pills_render_none_one_cap_at375() throws {
        let vm = composer(pills: true)
        let pills = OnlyFoodCompose.suggestedTags
        let cap = OnlyFoodCompose.maxTags
        let states: [(String, () -> Void)] = [
            ("none", {}),
            ("one", { _ = vm.toggleSuggestedHashtag(pills[0]) }),
            ("cap", {
                vm.updateContent((0..<(cap - 1)).map { "#zc\($0)" }.joined(separator: " "))
                _ = vm.toggleSuggestedHashtag(pills[0])
            }),
        ]
        for (name, arrange) in states {
            arrange()
            let row = HashtagSuggestionRow(viewModel: vm)
            let visible = row.visibleTags
            #expect(visible.count >= 3 && visible.count < pills.count, Comment(rawValue: name))
            let image = try render(row.frame(width: 375).background(Color.wispBackground))
            #expect(image.size.width >= 375, Comment(rawValue: name))
            write(image, "compose-pills-\(name)-375")
        }
        #expect(vm.isSuggestedHashtagSelected(pills[0]))
        #expect(vm.suggestedTagsAtCap)
    }

    /// The toolbar is a horizontal `ScrollView`, which `ImageRenderer` draws
    /// empty, so it is hosted in a 375pt window and snapshotted with
    /// `drawHierarchy` (the `ColorHierarchyRenderTests` pattern). Idle, then
    /// with sensitive and schedule both on; every glyph must sit inside the
    /// row (no shield, so the row fits without scrolling at 375pt).
    @Test func toolbar_render_idle_and_active_at375() throws {
        let vm = composer(pills: true)
        let row = ComposeActionsRow(
            viewModel: vm, onPickPhotos: {}, onPasteImage: {}, onPickGif: {}, onSchedule: {}
        )
        let host = Host(row.background(Color.wispBackground).environment(\.colorScheme, .dark))
        host.pump(0.3)
        let idle = try #require(host.snapshot())
        #expect(idle.size.width == 375)
        #expect(!isBlank(idle), "toolbar drew nothing")
        write(idle, "compose-toolbar-idle-375")

        vm.toggleNsfw()
        vm.setSchedule(Date(timeIntervalSinceNow: 3600))
        #expect(vm.explicit && vm.scheduleEnabled)
        host.pump(0.3)
        let active = try #require(host.snapshot())
        #expect(!isBlank(active))
        write(active, "compose-toolbar-active-375")
    }

    /// The whole composer at 375pt with the OnlyFood pills, as the user
    /// sees it: editor, pill row, toolbar and the greyed Publish carrying
    /// its reason. Screenshot only; the assertions above pin the parts.
    @Test func composer_render_empty_at375() throws {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: "compose_autosave_new_\(kp.pubkey)")
        let view = ComposeView(keypair: kp, initialText: "", suggestedHashtags: OnlyFoodCompose.suggestedTags)
            .environment(AppSettings.shared)
            .environment(PowPreferences.shared)
            .environment(\.colorScheme, .dark)
        let host = Host(view, height: 700)
        host.pump(0.6)
        let image = try #require(host.snapshot())
        #expect(!isBlank(image))
        write(image, "compose-sheet-empty-375")
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
        // Blank = every pixel within a hair of the first one.
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

    /// A 375pt window hosting a SwiftUI root so scroll views and
    /// representables lay out for real; `snapshot` draws the hierarchy.
    @MainActor private final class Host {
        let window: UIWindow

        init<Root: View>(_ root: Root, height: CGFloat = 120) {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: height))
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

    // MARK: - Helpers

    private func render<V: View>(_ view: V) throws -> UIImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        return try #require(renderer.uiImage)
    }

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
}
