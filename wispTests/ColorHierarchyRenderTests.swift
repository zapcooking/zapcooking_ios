import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// Rendered evidence for the colour hierarchy (`wisp/ZapColors.swift`), the
/// hermetic stand-in for the by-hand device pass: the ladder of real feed
/// components on the custom dark ground (bottom-bar glyphs, the compose FAB,
/// the action row, the top-zap pill, tiered content text, gray metadata) and
/// a hosted `RichContentView` with a #hashtag, an @mention and a long raw
/// URL painted by `RichInlineTextView`'s attributed string. Each test counts
/// pixels of the expected composited colour; with a directory in the
/// git-ignored `wispTests/.zc_snapshot_dir` it also writes the PNGs.
@MainActor
struct ColorHierarchyRenderTests {

    // MARK: - Ladder

    /// One picture of the whole hierarchy: full-strength primary on the FAB
    /// and the selected glyph, the value tier on the zap amount and the
    /// pill's bolt, the interactive tier on #hashtag / @mention, the link
    /// tier on the URL, and gray for the pill's message and the metadata.
    @Test func ladder_rendersEveryTier_onTheDarkGround() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        let palette = Themes.dark
        ResolvedThemeProxy.update(Self.theme(palette))

        let ground = try Self.argb(palette.background)
        let primary = try Self.argb(palette.primary)
        let raster = try #require(Self.render(
            Ladder().padding(20).frame(width: 390).background(palette.background)
                .environment(AppSettings.shared)
                .environment(\.colorScheme, .dark),
            name: "hierarchy-ladder-dark"
        ))
        let full = raster.count(argb: primary, tolerance: 6)
        let interactive = raster.count(argb: Self.composite(primary, over: ground, alpha: ResolvedTheme.interactiveOpacity), tolerance: 6)
        let link = raster.count(argb: Self.composite(primary, over: ground, alpha: ResolvedTheme.linkOpacity), tolerance: 6)
        #expect(full > 400, "primary px: \(full)")
        #expect(interactive > 40, "interactive px: \(interactive)")
        #expect(link > 40, "link px: \(link)")
    }

    /// The same ladder at an accessibility text size still lays out and
    /// still carries every tier (colours are independent of Dynamic Type).
    @Test func ladder_rendersAtAccessibilityTextSize() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        let palette = Themes.dark
        ResolvedThemeProxy.update(Self.theme(palette))

        let ground = try Self.argb(palette.background)
        let primary = try Self.argb(palette.primary)
        let raster = try #require(Self.render(
            Ladder().padding(20).frame(width: 390).background(palette.background)
                .environment(AppSettings.shared)
                .environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, .accessibility2),
            name: "hierarchy-ladder-dark-ax2"
        ))
        #expect(raster.count(argb: primary, tolerance: 6) > 400)
        #expect(raster.count(argb: Self.composite(primary, over: ground, alpha: ResolvedTheme.interactiveOpacity), tolerance: 6) > 40)
        #expect(raster.count(argb: Self.composite(primary, over: ground, alpha: ResolvedTheme.linkOpacity), tolerance: 6) > 40)
    }

    /// The zap pill on its own: bolt + amount at the value tier, the message
    /// gray, and NO full-strength orange text outside the bolt and amount.
    @Test func zapPill_amountIsOrange_messageIsGray() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        let palette = Themes.dark
        ResolvedThemeProxy.update(Self.theme(palette))

        let ground = try Self.argb(palette.background)
        let zap = try Self.argb(palette.zap)
        let pill = TopZapperPill(
            zapper: Zapper(pubkey: String(repeating: "1", count: 64), sats: 77, message: "Gratitude from Zap Cooking"),
            profile: nil, profiles: [:], onTap: {}
        )
        let withMessage = try #require(Self.render(
            pill.padding(16).background(palette.background)
                .environment(AppSettings.shared).environment(\.colorScheme, .dark),
            name: "zap-pill-dark"
        ))
        let amountOnly = try #require(Self.render(
            TopZapperPill(zapper: Zapper(pubkey: String(repeating: "1", count: 64), sats: 77, message: ""), profile: nil, profiles: [:], onTap: {})
                .padding(16).background(palette.background)
                .environment(AppSettings.shared).environment(\.colorScheme, .dark),
            name: "zap-pill-dark-no-message"
        ))
        let orangeWithMessage = withMessage.count(argb: zap, tolerance: 6)
        let orangeAmountOnly = amountOnly.count(argb: zap, tolerance: 6)
        #expect(orangeAmountOnly > 30, "bolt + amount px: \(orangeAmountOnly)")
        // Adding the message adds no full-strength orange: it is gray now.
        #expect(orangeWithMessage <= orangeAmountOnly + 8, "with message \(orangeWithMessage) vs amount-only \(orangeAmountOnly)")
        // The message is `textSecondary`: the dark-mode secondary label
        // colour composited over the ground shows up only when the message
        // is present.
        let secondary = UIColor.secondaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        try #require(secondary.getRed(&r, green: &g, blue: &b, alpha: &a))
        let grayArgb = (0xFF << 24) | (Int((r * 255).rounded()) << 16) | (Int((g * 255).rounded()) << 8) | Int((b * 255).rounded())
        let gray = Self.composite(grayArgb, over: ground, alpha: Double(a))
        let grayWithMessage = withMessage.count(argb: gray, tolerance: 10)
        let grayAmountOnly = amountOnly.count(argb: gray, tolerance: 10)
        #expect(grayWithMessage > grayAmountOnly + 40, "message gray px: \(grayWithMessage) vs \(grayAmountOnly) without a message")
        // The capsule stroke is the subtle tier, not the value tier.
        let subtle = Self.composite(zap, over: ground, alpha: ResolvedTheme.subtleOpacity)
        #expect(withMessage.count(argb: subtle, tolerance: 10) > 20)
    }

    // MARK: - Hosted rich text

    /// `RichInlineTextView` is a `UIViewRepresentable`, so it is hosted in a
    /// window and snapshotted through UIKit: a #hashtag and an @mention paint
    /// at the interactive tier, a long raw URL at the link tier, body text
    /// stays the label colour.
    @Test func richText_paintsHashtagMentionAndUrl_atTheirTiers() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        let palette = Themes.dark
        ResolvedThemeProxy.update(Self.theme(palette))

        let npub = try #require(Nip19.npubEncode(pubkey: [UInt8](repeating: 0x11, count: 32)))
        let content = "Sunday #sourdough with nostr:\(npub) — recipe notes at https://example.com/recipes/2026/09/19/a-very-long-path-that-keeps-going-and-going?ref=zapcooking"
        let host = Host(
            RichContentView(content: content, tags: [], profiles: [:], showLinkPreviews: false, linksEnabled: true)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(palette.background)
                .environment(AppSettings.shared)
                .environment(\.colorScheme, .dark)
        )
        host.pump(0.6)
        let raster = try #require(host.snapshot(name: "rich-text-tiers-dark"))
        let ground = try Self.argb(palette.background)
        let primary = try Self.argb(palette.primary)
        let interactive = raster.count(argb: Self.composite(primary, over: ground, alpha: ResolvedTheme.interactiveOpacity), tolerance: 8)
        let link = raster.count(argb: Self.composite(primary, over: ground, alpha: ResolvedTheme.linkOpacity), tolerance: 8)
        let full = raster.count(argb: primary, tolerance: 4)
        #expect(interactive > 40, "interactive px: \(interactive)")
        #expect(link > 40, "link px: \(link)")
        // Nothing in a post body is full-strength orange any more.
        #expect(full < 20, "full-strength px in body text: \(full)")
    }

    // MARK: - The ladder view

    private struct Ladder: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 28) {
                    Image(systemName: "flame.fill").font(.system(size: 26)).foregroundStyle(Color.zapPrimary)
                    Image(systemName: "book").font(.system(size: 24)).foregroundStyle(Color.textSecondary)
                    Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(Color.textSecondary)
                    Image(systemName: "bell").font(.system(size: 24)).foregroundStyle(Color.textSecondary)
                    Spacer()
                    ComposeFAB {}
                }
                Text("Chef Alice").font(.subheadline.weight(.semibold)).foregroundStyle(Color.textPrimary)
                    + Text("  2h").font(.caption).foregroundStyle(Color.textSecondary)
                Text(Self.body)
                    .font(.callout)
                    .foregroundStyle(Color.textPrimary)
                HStack(spacing: 4) {
                    ActionRowItem(glyph: .symbol("bubble.right"), label: "3")
                    ActionRowItem(glyph: .symbol("arrow.2.squarepath"), label: "2", tint: Color.wispRepostColor)
                    ActionRowItem(glyph: .symbol("heart"), label: "12")
                    ActionRowItem(glyph: .symbol("bolt.fill"), label: "77", tint: Color.wispZapColor)
                    ActionRowItem(glyph: .symbol("bolt"), label: "1.2k")
                    ActionRowItem(glyph: .symbol("bookmark"))
                }
                TopZapperPill(
                    zapper: Zapper(pubkey: String(repeating: "1", count: 64), sats: 77, message: "Gratitude from Zap Cooking"),
                    profile: nil, profiles: [:], onTap: {}
                )
            }
        }

        static var body: AttributedString {
            var s = AttributedString("Sunday ")
            var tag = AttributedString("#sourdough"); tag.foregroundColor = .zapInteractive
            var mention = AttributedString("@alice"); mention.foregroundColor = .zapInteractive
            var link = AttributedString("example.com/recipes/2026/09/19/long-path…"); link.foregroundColor = .zapLink
            s += tag; s += AttributedString(" with "); s += mention; s += AttributedString(" — notes at "); s += link
            return s
        }
    }

    // MARK: - Helpers

    private static func theme(_ palette: ThemePalette) -> ResolvedTheme {
        ResolvedTheme(
            isDark: true, palette: palette,
            primary: palette.primary, zap: palette.zap, bookmark: palette.bookmark, zapAnimation: palette.zap
        )
    }

    private static func argb(_ color: Color) throws -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        try #require(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a), "\(color) has no RGB components")
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return (0xFF << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }

    private static func composite(_ fg: Int, over bg: Int, alpha: Double) -> Int {
        func ch(_ shift: Int) -> Int {
            let f = Double((fg >> shift) & 0xFF), b = Double((bg >> shift) & 0xFF)
            return Int((alpha * f + (1 - alpha) * b).rounded())
        }
        return (0xFF << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0)
    }

    private static func render<V: View>(_ view: V, name: String) -> Raster? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        write(cg, name: name)
        return Raster(cg)
    }

    fileprivate static func write(_ cg: CGImage, name: String) {
        guard let dir = snapshotDirectory, let data = UIImage(cgImage: cg).pngData() else { return }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        } catch {
            Issue.record("snapshot write to \(dir) failed: \(error)")
        }
    }

    nonisolated private static var snapshotDirectory: String? {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["ZC_SNAPSHOT_DIR"] ?? env["TEST_RUNNER_ZC_SNAPSHOT_DIR"], !dir.isEmpty { return dir }
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".zc_snapshot_dir")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A window hosting a SwiftUI root so `UIViewRepresentable` content
    /// (the rich text) lays out for real; `snapshot` draws the hierarchy.
    @MainActor private final class Host {
        let window: UIWindow

        init<Root: View>(_ root: Root) {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
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

        func snapshot(name: String) -> Raster? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            guard let cg = image.cgImage else { return nil }
            ColorHierarchyRenderTests.write(cg, name: name)
            return Raster(cg)
        }
    }

    fileprivate struct Raster {
        let width: Int
        let height: Int
        private let data: [UInt8]

        init?(_ cg: CGImage) {
            width = cg.width
            height = cg.height
            var buf = [UInt8](repeating: 0, count: width * height * 4)
            let ok: Bool = buf.withUnsafeMutableBytes { raw in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(
                          data: raw.baseAddress, width: cg.width, height: cg.height,
                          bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                return true
            }
            guard ok else { return nil }
            data = buf
        }

        func count(argb: Int, tolerance: Int) -> Int {
            let (tr, tg, tb) = ((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF)
            var n = 0
            data.withUnsafeBufferPointer { px in
                var i = 0
                while i < px.count {
                    if abs(Int(px[i]) - tr) <= tolerance,
                       abs(Int(px[i + 1]) - tg) <= tolerance,
                       abs(Int(px[i + 2]) - tb) <= tolerance {
                        n += 1
                    }
                    i += 4
                }
            }
            return n
        }
    }
}
