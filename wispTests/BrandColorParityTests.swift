import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// Brand-color parity: the iOS primary is the same pair web `src/app.css`
/// (`--color-primary`) and Android `Themes.kt` ship — #EC4700 light,
/// #FF5722 dark — routed through the one token set (`Themes.light` /
/// `Themes.dark` → `resolveTheme` → `ResolvedThemeProxy` → `Color.wisp*`).
/// Also pins what must not move (repost green, paid amber, the unread
/// dot) and measures the dark primary's WCAG contrast on every custom
/// dark ground, since links, hashtags and small labels are set in it.
///
/// Put a directory in the git-ignored `wispTests/.zc_snapshot_dir` to also
/// write PNGs of the compose FAB, the new-posts pill and hashtag-coloured
/// text on the custom dark and light grounds.
@MainActor
struct BrandColorParityTests {

    static let brandDark = 0xFFFF5722
    static let brandLight = 0xFFEC4700
    static let wispOrange = 0xFFFF9800

    // MARK: - The token

    @Test func defaultAccent_isBrandDark() {
        #expect(AppSettings.defaultAccentARGB == Self.brandDark)
    }

    /// Appearance is the only theme control left: System, Light, Dark.
    /// The accent picker and the fifteen selectable presets are gone, so
    /// there is exactly one palette pair to choose a side of.
    @Test func appearance_isTheOnlyThemeControl() {
        #expect(AppSettings.ColorSchemePreference.allCases == [.system, .light, .dark])
    }

    @Test func palettes_andFallbackTheme_areTheBrandPair() throws {
        #expect(try Self.argb(Themes.dark.primary) == Self.brandDark)
        #expect(try Self.argb(Themes.dark.zap) == Self.brandDark)
        #expect(try Self.argb(Themes.dark.bookmark) == Self.brandDark)
        #expect(try Self.argb(Themes.light.primary) == Self.brandLight)
        #expect(try Self.argb(Themes.light.zap) == Self.brandLight)
        #expect(try Self.argb(Themes.light.bookmark) == Self.brandLight)
        #expect(try Self.argb(ResolvedTheme.default.primary) == Self.brandDark)
        #expect(try Self.argb(ResolvedTheme.default.zap) == Self.brandDark)
    }

    /// The live resolution path. Light and Dark pin the side and ignore the
    /// device; System follows it. The window's interface style comes from
    /// the same preference, so the palette and the system chrome (home
    /// indicator, status bar) can never disagree.
    @Test func resolveTheme_yieldsBrandPair_onEveryAppearance() throws {
        let settings = AppSettings.shared
        let saved = settings.colorScheme
        defer { settings.colorScheme = saved }

        settings.colorScheme = .dark
        let dark = settings.resolveTheme(systemColorScheme: .light)
        #expect(dark.isDark)
        #expect(settings.preferredColorScheme == .dark)
        #expect(try Self.argb(dark.primary) == Self.brandDark)
        #expect(try Self.argb(dark.zap) == Self.brandDark)
        #expect(try Self.argb(dark.bookmark) == Self.brandDark)

        settings.colorScheme = .light
        let light = settings.resolveTheme(systemColorScheme: .dark)
        #expect(!light.isDark)
        #expect(settings.preferredColorScheme == .light)
        #expect(try Self.argb(light.primary) == Self.brandLight)
        #expect(try Self.argb(light.zap) == Self.brandLight)
        #expect(try Self.argb(light.bookmark) == Self.brandLight)

        // System hands the choice to the device, and the window follows.
        settings.colorScheme = .system
        #expect(settings.preferredColorScheme == nil)
        #expect(settings.resolveTheme(systemColorScheme: .dark).isDark)
        #expect(!settings.resolveTheme(systemColorScheme: .light).isDark)
        // No device answer yet (the very first resolve) falls to dark.
        #expect(settings.resolveTheme(systemColorScheme: nil).isDark)

        // Nothing in the app resolves Wisp's orange any more.
        #expect(try Self.argb(dark.primary) != Self.wispOrange)
        #expect(try Self.argb(light.primary) != Self.wispOrange)
    }

    /// `Color.accentColor` / UIKit's tint (the emoji reaction picker's
    /// highlight, system alerts) — the asset was empty, i.e. system blue.
    @Test func accentColorAsset_isTheBrandPair() throws {
        let asset = try #require(UIColor(named: "AccentColor", in: Bundle.main, compatibleWith: nil))
        let dark = asset.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let light = asset.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        #expect(try Self.argb(dark) == Self.brandDark)
        #expect(try Self.argb(light) == Self.brandLight)
    }

    // MARK: - What must not move

    @Test func semanticColors_unchanged() throws {
        #expect(try Self.argb(Themes.dark.repost) == 0xFF4CAF50)
        #expect(try Self.argb(Themes.light.repost) == 0xFF2E7D32)
        #expect(try Self.argb(Themes.dark.paid) == 0xFFFFD54F)
        #expect(try Self.argb(Themes.light.paid) == 0xFFC9A000)
        #expect(try Self.argb(BottomTab.unreadDotColor(isDark: true)) == 0xFFFBBF24)
    }

    // MARK: - Contrast

    /// WCAG 2 contrast of the dark primary — link, hashtag and small-label
    /// text — on the custom dark grounds. Background and surface clear AA
    /// for normal text (4.5). SurfaceVariant is Android/web's exact chip
    /// token (#374151, Themes.kt) where the same orange measures 3.26 —
    /// parity wins there, so it's held to the AA large-text floor (3.0)
    /// instead of quietly drifting the shared token.
    @Test func darkPrimary_clearsAA_onEveryDarkGround() throws {
        let dark = Themes.dark
        let primary = try Self.argb(dark.primary)
        for (name, ground) in [("background", dark.background), ("surface", dark.surface)] {
            let ratio = Self.contrast(primary, try Self.argb(ground))
            #expect(ratio >= 4.5, "\(name): \(String(format: "%.2f", ratio))")
        }
        let surfaceVariant = try Self.argb(dark.surfaceVariant)
        #expect(surfaceVariant == 0xFF374151, "surfaceVariant must stay the Android/web token")
        let ratio = Self.contrast(primary, surfaceVariant)
        #expect(ratio >= 3.0, "surfaceVariant: \(String(format: "%.2f", ratio))")
    }

    /// The bottom-bar unread dot has to read as an alert on whatever ground
    /// it lands on. Amber-400 measures 1.17:1 on the light ground —
    /// invisible — so light mode uses amber-700, and both sides are held to
    /// the 3:1 WCAG non-text floor.
    @Test func unreadDot_clears3to1_onBothGrounds() throws {
        for (name, palette, isDark) in [("dark", Themes.dark, true), ("light", Themes.light, false)] {
            let dot = try Self.argb(BottomTab.unreadDotColor(isDark: isDark))
            let ratio = Self.contrast(dot, try Self.argb(palette.background))
            #expect(ratio >= 3.0, "\(name): \(String(format: "%.2f", ratio))")
        }
    }

    // MARK: - Renders (evidence for the by-hand gate)

    @Test func brandCarriers_render_onDarkAndLightGrounds() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        for (name, palette, isDark) in [("dark", Themes.dark, true), ("light", Themes.light, false)] {
            ResolvedThemeProxy.update(ResolvedTheme(
                isDark: isDark, palette: palette,
                primary: palette.primary, zap: palette.zap, bookmark: palette.bookmark, zapAnimation: palette.zap
            ))
            let expected = try Self.argb(palette.primary)
            let carriers: [(String, AnyView)] = [
                ("fab", AnyView(ComposeFAB {})),
                ("pill", AnyView(NewPostsPill(count: 1, onTap: {}, onDismiss: {}))),
                ("hashtag", AnyView(Text("#sourdough").font(.body).foregroundStyle(Color.wispPrimary))),
            ]
            for (carrier, view) in carriers {
                let raster = try #require(Self.render(
                    view.padding(24).background(palette.background)
                        .environment(\.colorScheme, isDark ? .dark : .light),
                    name: "brand-\(carrier)-\(name)"
                ))
                let hits = raster.count(argb: expected, tolerance: 6)
                #expect(hits > 40, "\(carrier) \(name): \(hits) px of \(String(expected, radix: 16))")
            }
        }
    }

    // MARK: - Helpers

    private static func argb(_ color: Color) throws -> Int { try argb(UIColor(color)) }

    private static func argb(_ color: UIColor) throws -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        try #require(color.getRed(&r, green: &g, blue: &b, alpha: &a), "\(color) has no RGB components")
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return (0xFF << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }

    private static func contrast(_ a: Int, _ b: Int) -> Double {
        func lum(_ argb: Int) -> Double {
            func lin(_ c: Int) -> Double {
                let v = Double(c) / 255
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin((argb >> 16) & 0xFF) + 0.7152 * lin((argb >> 8) & 0xFF) + 0.0722 * lin(argb & 0xFF)
        }
        let (la, lb) = (lum(a), lum(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func render<V: View>(_ view: V, name: String) -> Raster? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        if let dir = snapshotDirectory, let data = UIImage(cgImage: cg).pngData() {
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            } catch {
                Issue.record("snapshot write to \(dir) failed: \(error)")
            }
        }
        return Raster(cg)
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
