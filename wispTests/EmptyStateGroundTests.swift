import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// The thread's "No replies yet" dead end after the last Wisp illustration
/// left it: the built app carries no Wisp imageset, the empty state draws
/// Cheffy in the neutral expression, and — the ZcLogo lesson from C-J —
/// every part of Cheffy stays readable on every theme's light and dark
/// ground. Measured from rendered pixels, not assumed.
///
/// To also write PNGs of the empty state (default theme light and dark, plus
/// the softest light ground) put the target directory in the git-ignored
/// file `wispTests/.zc_snapshot_dir` (the `CheffyLiveTests` pattern — hosted
/// runs don't deliver `TEST_RUNNER_` env forwarding) or in `ZC_SNAPSHOT_DIR`.
@MainActor
struct EmptyStateGroundTests {

    // MARK: - No Wisp asset in the built app

    @Test func builtApp_carriesNoWispIllustrationAsset() {
        for name in ["NoReplies", "WispLogo"] {
            #expect(UIImage(named: name, in: Bundle.main, with: nil) == nil, Comment(rawValue: name))
        }
        // The brand mark C-J moved the eight logo sites to is still shipped.
        #expect(UIImage(named: "ZcLogo", in: Bundle.main, with: nil) != nil)
    }

    // MARK: - The empty state is Cheffy, neutral

    @Test func noRepliesEmptyState_drawsNeutralCheffy_onLightAndDarkGround() throws {
        #expect(NoRepliesEmptyState.expression == .neutral)
        #expect(NoRepliesEmptyState.iconSize == 64)

        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        let cases: [(name: String, palette: ThemePalette, isDark: Bool)] = [
            ("dark", Themes.dark, true),
            ("light", Themes.light, false),
        ]
        for c in cases {
            ResolvedThemeProxy.update(Self.theme(palette: c.palette, isDark: c.isDark))
            let raster = try #require(Self.render(
                NoRepliesEmptyState()
                    .frame(width: 320)
                    .background(c.palette.background)
                    .environment(\.colorScheme, c.isDark ? .dark : .light),
                scale: 2, name: c.name
            ))
            // The hat is the theme primary; the eyes/brow/mouth are Cheffy's
            // fixed ink. Both must land on the canvas — at 2× a 64 pt hat is
            // roughly 4 000 px, the ink features a few hundred.
            let hat = raster.count(near: try Self.rgb(ResolvedThemeProxy.current.primary), tolerance: 8)
            let ink = raster.count(near: (0x3A, 0x24, 0x15), tolerance: 8)
            #expect(hat >= 1_200, "\(c.name) hat px \(hat)")
            #expect(ink >= 80, "\(c.name) ink px \(ink)")
        }
    }

    // MARK: - Ground check across every theme

    /// Samples one flat pixel per fill in Cheffy's 64-unit space, away from
    /// any feature: the left cheek (face), the centre toque puff (hat), the
    /// left eye's centre (ink — the highlight sits up-right of it). Face and
    /// hat are judged against the theme ground they sit on; ink against the
    /// face it sits on. Max-channel delta, 0–255.
    @Test func cheffy_readsOnEveryThemeGround_lightAndDark() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        var softestFace = (delta: 255, ground: "")
        do {
            for (isDark, palette) in [(true, Themes.dark), (false, Themes.light)] {
                let label = isDark ? "dark" : "light"
                ResolvedThemeProxy.update(Self.theme(palette: palette, isDark: isDark))
                let raster = try #require(Self.render(
                    ZStack {
                        palette.background
                        CheffyIcon(size: 64, expression: .neutral)
                    }
                    .frame(width: 64, height: 64),
                    scale: 1
                ))
                let ground = raster.rgb(2, 2)
                let face = raster.rgb(17, 42)
                let hat = raster.rgb(32, 10)
                let ink = raster.rgb(25, 39)
                let faceDelta = Self.delta(face, ground)
                if faceDelta < softestFace.delta { softestFace = (faceDelta, label) }
                #expect(faceDelta >= 30, "\(label): face \(face) on ground \(ground)")
                #expect(Self.delta(hat, ground) >= 60, "\(label): hat \(hat) on ground \(ground)")
                #expect(Self.delta(ink, face) >= 90, "\(label): ink \(ink) on face \(face)")
                // The hat really is the theme primary, so the sample hit the toque.
                #expect(Self.delta(hat, try Self.rgb(ResolvedThemeProxy.current.primary)) <= 4, "\(label): hat \(hat)")
            }
        }
        // Documented worst case so a palette change that softens it shows up here.
        #expect(softestFace.delta >= 30, "softest face-vs-ground: \(softestFace)")
    }

    // MARK: - Helpers

    /// What `AppSettings.resolveTheme` yields for a palette: every colour
    /// straight off it, now that the accent override is gone.
    private static func theme(palette: ThemePalette, isDark: Bool) -> ResolvedTheme {
        ResolvedTheme(
            isDark: isDark, palette: palette,
            primary: palette.primary, zap: palette.zap, bookmark: palette.bookmark,
            zapAnimation: palette.zap
        )
    }

    /// sRGB bytes of a theme colour. A colour that cannot be expressed as RGB
    /// fails the test outright rather than reading as black.
    private static func rgb(_ color: Color) throws -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        try #require(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a), "\(color) has no RGB components")
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    nonisolated private static func delta(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    private static func render<V: View>(_ view: V, scale: CGFloat, name: String? = nil) -> Raster? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        if let name, let dir = snapshotDirectory, let data = UIImage(cgImage: cg).pngData() {
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("no-replies-\(name).png"))
            } catch {
                Issue.record("snapshot write to \(dir) failed: \(error)")
            }
        }
        return Raster(cg)
    }

    /// `ZC_SNAPSHOT_DIR` (either spelling), else the trimmed contents of the
    /// git-ignored `wispTests/.zc_snapshot_dir`; nil means no PNGs.
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

    /// sRGB RGBA8 copy of a rendered image with per-pixel access.
    private struct Raster {
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

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }

        func count(near target: (Int, Int, Int), tolerance: Int) -> Int {
            let (tr, tg, tb) = target
            var n = 0
            data.withUnsafeBufferPointer { px in
                var i = 0
                let end = px.count
                while i < end {
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
