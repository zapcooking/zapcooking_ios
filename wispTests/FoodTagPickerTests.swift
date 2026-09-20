import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// The composer row's "+" and the picker behind it: the set it shows
/// (`FoodHashtags`, popular first, then alphabetical), search, selected
/// tags pinned first in the row, and the "+N" when selected tags are past
/// the cut. Renders at 375pt; PNGs via the git-ignored
/// `wispTests/.zc_snapshot_dir`. Hermetic.
@MainActor
struct FoodTagPickerTests {
    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func composer() -> ComposeViewModel {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: "compose_autosave_new_\(kp.pubkey)")
        return ComposeViewModel(keypair: kp, suggestedHashtags: OnlyFoodCompose.suggestedTags)
    }

    // MARK: - The set

    @Test func picker_isTheWholeFilterSet_popularFirst_thenAlphabetical() {
        let popular = OnlyFoodCompose.pickerPopular
        let rest = OnlyFoodCompose.pickerRest
        #expect(popular == OnlyFoodCompose.suggestedTags)
        #expect(rest == rest.sorted())
        #expect(Set(popular).isDisjoint(with: Set(rest)))
        #expect(Set(popular + rest) == FoodHashtags.allSet)
        #expect(popular.count + rest.count == FoodHashtags.allSet.count)
        for tag in rest { #expect(tag == tag.lowercased(), Comment(rawValue: tag)) }
    }

    @Test func search_ignoresHash_andCase_andMatchesSubstrings() {
        let all = OnlyFoodCompose.pickerPopular + OnlyFoodCompose.pickerRest
        #expect(OnlyFoodCompose.pickerMatches(all, query: "") == all)
        #expect(OnlyFoodCompose.pickerMatches(all, query: "   ") == all)
        let soup = OnlyFoodCompose.pickerMatches(all, query: "#SOU")
        #expect(soup.contains("soup") && soup.contains("soupstr"))
        #expect(!soup.contains("sushi"))
        #expect(OnlyFoodCompose.pickerMatches(all, query: "sourdough").isEmpty)
        #expect(OnlyFoodCompose.pickerMatches(OnlyFoodCompose.pickerPopular, query: "str") == ["foodstr", "cookstr"])
    }

    // MARK: - The row: selected first

    @Test func rowOrder_pinsSelectedFoodTagsFirst_inBodyOrder_thenTheRest() {
        let order = OnlyFoodCompose.rowOrder(
            bodyTags: ["zc1", "sushi", "dinner", "notfood"], suggested: OnlyFoodCompose.suggestedTags
        )
        #expect(order.prefix(2) == ["sushi", "dinner"])
        #expect(!order.contains("zc1") && !order.contains("notfood"))
        #expect(Array(order.dropFirst(2)) == OnlyFoodCompose.suggestedTags.filter { $0 != "dinner" })
        #expect(Set(order).count == order.count)
        #expect(OnlyFoodCompose.rowOrder(bodyTags: [], suggested: OnlyFoodCompose.suggestedTags) == OnlyFoodCompose.suggestedTags)
    }

    @Test func aPickedTag_showsFirstInTheRow() {
        let vm = composer()
        #expect(vm.toggleSuggestedHashtag("sushi"))
        let row = HashtagSuggestionRow(viewModel: vm)
        #expect(row.visibleTags.first == "sushi")
        #expect(row.layout.hiddenSelected == 0)
        #expect(vm.isSuggestedHashtagSelected("sushi"))
        #expect(vm.content.contains("#sushi"))
    }

    // MARK: - "+N"

    @Test func rowLayout_countsHiddenSelected_andWidensThePlus() {
        let widths: [CGFloat] = Array(repeating: 70, count: 8)
        let allSelected = Array(repeating: true, count: 8)
        // 300pt: "+" 32 → 3 fit (32 + 3×78 = 266; a 4th needs 344); 5 hidden.
        // "+5" is wider (say 40): still 3 fit (40 + 234 = 274) → stable.
        let r = OnlyFoodCompose.rowLayout(
            widths: widths, selected: allSelected,
            plusWidth: { $0 > 0 ? 40 : 32 }, spacing: 8, available: 300
        )
        #expect(r.count == 3 && r.hiddenSelected == 5)
        // The widened "+" can push one more out; the pair converges.
        let tight = OnlyFoodCompose.rowLayout(
            widths: widths, selected: allSelected,
            plusWidth: { $0 > 0 ? 60 : 32 }, spacing: 8, available: 270
        )
        #expect(tight.count == 2 && tight.hiddenSelected == 6)
        let none = OnlyFoodCompose.rowLayout(
            widths: widths, selected: Array(repeating: false, count: 8),
            plusWidth: { _ in 32 }, spacing: 8, available: 300
        )
        #expect(none.count == 3 && none.hiddenSelected == 0)
    }

    @Test func manySelected_at375_showsPlusN_forTheOnesPastTheCut() {
        let vm = composer()
        for tag in OnlyFoodCompose.suggestedTags.prefix(6) { #expect(vm.toggleSuggestedHashtag(tag)) }
        let row = HashtagSuggestionRow(viewModel: vm)
        let layout = row.layout
        #expect(layout.visible.count >= 2 && layout.visible.count < 6, "\(layout.visible.count) shown")
        #expect(layout.hiddenSelected == 6 - layout.visible.count)
        #expect(layout.visible.allSatisfy { vm.isSuggestedHashtagSelected($0) }, "selected pinned first")
        // Measured: the shown pills and the "+N" fit.
        let font = HashtagPillMetrics.uiFont()
        let total = layout.visible.map { HashtagPillMetrics.pillWidth(label: "#\($0)", font: font) }.reduce(0, +)
            + CGFloat(layout.visible.count) * HashtagPillMetrics.spacing
            + HashtagPillMetrics.plusWidth(hidden: layout.hiddenSelected, font: font)
        #expect(total <= 375 - 2 * 16)
    }

    // MARK: - Renders at 375pt

    @Test func row_render_pickedTagPinned_and_plusN_at375() throws {
        let vm = composer()
        vm.toggleSuggestedHashtag("sushi")
        vm.toggleSuggestedHashtag(OnlyFoodCompose.defaultTag)
        let pinned = try render(HashtagSuggestionRow(viewModel: vm).frame(width: 375).background(Color.wispBackground))
        #expect(pinned.size.width >= 375)
        write(pinned, "compose-pills-pinned-375")

        for tag in ["coffee", "cooking", "breakfast", "dinner"] { vm.toggleSuggestedHashtag(tag) }
        #expect(HashtagSuggestionRow(viewModel: vm).layout.hiddenSelected > 0)
        let overflow = try render(HashtagSuggestionRow(viewModel: vm).frame(width: 375).background(Color.wispBackground))
        write(overflow, "compose-pills-plusN-375")
    }

    /// The picker is a `ScrollView`, so it is hosted in a 375pt window
    /// (ImageRenderer draws scroll content empty).
    @Test func picker_render_at375() throws {
        let vm = composer()
        vm.toggleSuggestedHashtag("sushi")
        let host = Host(FoodTagPickerView(viewModel: vm).environment(\.colorScheme, .dark), height: 640)
        host.pump(0.4)
        let image = try #require(host.snapshot())
        #expect(image.size.width == 375)
        write(image, "compose-tag-picker-375")
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

    @MainActor private final class Host {
        let window: UIWindow

        init<Root: View>(_ root: Root, height: CGFloat) {
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
}
