import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// Brand-color parity: the iOS accent is the same pair web `src/app.css`
/// (`--color-primary`) and Android `Themes.kt` ship — #EC4700 light,
/// #FF5722 dark — routed through the one token set (`AppSettings`
/// default accent → `resolveTheme` → `ResolvedThemeProxy` → `Color.wisp*`).
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

    @Test func defaultAccent_isBrandDark_andLegacyWispMigrates() {
        #expect(AppSettings.defaultAccentARGB == Self.brandDark)
        #expect(AppSettings.legacyWispAccentARGB == Self.wispOrange)
        #expect(AppSettings.loadAccent(nil) == Self.brandDark)
        #expect(AppSettings.loadAccent(Self.wispOrange) == Self.brandDark)
        // A deliberate pick survives.
        #expect(AppSettings.loadAccent(0xFF3366CC) == 0xFF3366CC)
    }

    @Test func customPalette_andFallbackTheme_areTheBrandPair() throws {
        let custom = Themes.get("custom")
        #expect(try Self.argb(custom.dark.primary) == Self.brandDark)
        #expect(try Self.argb(custom.dark.zap) == Self.brandDark)
        #expect(try Self.argb(custom.dark.bookmark) == Self.brandDark)
        #expect(try Self.argb(custom.light.primary) == Self.brandLight)
        #expect(try Self.argb(custom.light.zap) == Self.brandLight)
        #expect(try Self.argb(custom.light.bookmark) == Self.brandLight)
        #expect(try Self.argb(ResolvedTheme.default.primary) == Self.brandDark)
        #expect(try Self.argb(ResolvedTheme.default.zap) == Self.brandDark)
    }

    /// The live resolution path with the default accent: dark uses the raw
    /// accent, light the palette primary — both brand.
    @Test func resolveTheme_customDefaultAccent_yieldsBrandPair() throws {
        let settings = AppSettings.shared
        let saved = (settings.themeName, settings.colorScheme, settings.accentColorARGB)
        defer {
            settings.themeName = saved.0
            settings.colorScheme = saved.1
            settings.accentColorARGB = saved.2
        }
        settings.themeName = "custom"
        settings.accentColorARGB = AppSettings.defaultAccentARGB

        settings.colorScheme = .dark
        let dark = settings.resolveTheme(systemColorScheme: .light)
        #expect(dark.isDark)
        #expect(try Self.argb(dark.primary) == Self.brandDark)
        #expect(try Self.argb(dark.zap) == Self.brandDark)
        #expect(try Self.argb(dark.bookmark) == Self.brandDark)

        settings.colorScheme = .light
        let light = settings.resolveTheme(systemColorScheme: .dark)
        #expect(!light.isDark)
        #expect(try Self.argb(light.primary) == Self.brandLight)
        #expect(try Self.argb(light.zap) == Self.brandLight)
        #expect(try Self.argb(light.bookmark) == Self.brandLight)

        // Nothing in the app resolves Wisp's orange any more.
        settings.colorScheme = .system
        for scheme in [ColorScheme.dark, .light] {
            #expect(try Self.argb(settings.resolveTheme(systemColorScheme: scheme).primary) != Self.wispOrange)
        }
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
        let custom = Themes.get("custom")
        #expect(try Self.argb(custom.dark.repost) == 0xFF4CAF50)
        #expect(try Self.argb(custom.light.repost) == 0xFF2E7D32)
        #expect(try Self.argb(custom.dark.paid) == 0xFFFFD54F)
        #expect(try Self.argb(custom.light.paid) == 0xFFC9A000)
        #expect(try Self.argb(BottomTab.unreadDotColor) == 0xFFFBBF24)
        // The curated presets keep their own primaries; only the brand preset moved.
        #expect(try Self.argb(Themes.get("nord").dark.primary) == 0xFF88C0D0)
        #expect(try Self.argb(Themes.get("dracula").light.primary) == 0xFFD05090)
    }

    // MARK: - Contrast

    /// WCAG 2 contrast of the dark primary — the 100% tier (FAB, selected
    /// glyph, zap amounts) — on each custom dark ground must clear AA for
    /// normal text (4.5). The derived interactive / link tiers that links,
    /// hashtags and mentions now use are measured in `ColorHierarchyTests`.
    @Test func darkPrimary_clearsAA_onEveryCustomDarkGround() throws {
        let dark = Themes.get("custom").dark
        let primary = try Self.argb(dark.primary)
        for (name, ground) in [("background", dark.background), ("surface", dark.surface), ("surfaceVariant", dark.surfaceVariant)] {
            let ratio = Self.contrast(primary, try Self.argb(ground))
            #expect(ratio >= 4.5, "\(name): \(String(format: "%.2f", ratio))")
        }
    }

    // MARK: - Renders (evidence for the by-hand gate)

    @Test func brandCarriers_render_onDarkAndLightGrounds() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        let custom = Themes.get("custom")
        for (name, palette, isDark) in [("dark", custom.dark, true), ("light", custom.light, false)] {
            ResolvedThemeProxy.update(ResolvedTheme(
                presetId: "custom", isDark: isDark, palette: palette,
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
