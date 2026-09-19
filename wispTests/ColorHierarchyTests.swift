import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// The Zap Cooking colour hierarchy (`wisp/ZapColors.swift`): one brand
/// orange resolved into four intensities by `ResolvedTheme`, consumed by
/// views as `Color.zapPrimary` / `.zapInteractive` / `.zapLink` /
/// `.zapSubtle` / `.zapSubtleFill`. Pins the tier ladder, the increased-
/// contrast collapse, the composer/rich-text colours that ride on it, and
/// the measured WCAG contrast of each text tier on the custom dark grounds.
@MainActor
struct ColorHierarchyTests {

    static let brandDark = 0xFFFF5722

    // MARK: - The ladder

    @Test func tiers_deriveFromPrimary_withTheDocumentedOpacities() throws {
        let theme = ResolvedTheme.default
        #expect(try Self.rgb(theme.interactive) == Self.rgb(theme.primary))
        #expect(try Self.rgb(theme.link) == Self.rgb(theme.primary))
        #expect(try Self.rgb(theme.subtle) == Self.rgb(theme.primary))
        #expect(try Self.rgb(theme.subtleFill) == Self.rgb(theme.primary))

        #expect(try Self.alpha(theme.primary) == 1.0)
        #expect(try Self.near(Self.alpha(theme.interactive), ResolvedTheme.interactiveOpacity))
        #expect(try Self.near(Self.alpha(theme.link), ResolvedTheme.linkOpacity))
        #expect(try Self.near(Self.alpha(theme.subtle), ResolvedTheme.subtleOpacity))
        #expect(try Self.near(Self.alpha(theme.subtleFill), ResolvedTheme.subtleFillOpacity))

        // The ladder is strictly ordered: primary > interactive > link > subtle > fill.
        #expect(ResolvedTheme.interactiveOpacity < 1.0)
        #expect(ResolvedTheme.linkOpacity < ResolvedTheme.interactiveOpacity)
        #expect(ResolvedTheme.subtleOpacity < ResolvedTheme.linkOpacity)
        #expect(ResolvedTheme.subtleFillOpacity < ResolvedTheme.subtleOpacity)
        // Within the ranges the design brief asked for.
        #expect((0.85...0.90).contains(ResolvedTheme.interactiveOpacity))
        #expect((0.75...0.80).contains(ResolvedTheme.linkOpacity))
        #expect((0.25...0.35).contains(ResolvedTheme.subtleOpacity))
    }

    /// The accessors read the same resolved theme the environment carries.
    @Test func colorAccessors_readTheActiveTheme() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        let custom = Themes.get("custom")
        ResolvedThemeProxy.update(ResolvedTheme(
            presetId: "custom", isDark: true, palette: custom.dark,
            primary: custom.dark.primary, zap: custom.dark.zap, bookmark: custom.dark.bookmark,
            zapAnimation: custom.dark.zap
        ))
        #expect(try Self.argb(Color.zapPrimary) == Self.brandDark)
        #expect(try Self.argb(Color.zapPrimary) == Self.argb(Color.wispPrimary))
        #expect(try Self.rgb(Color.zapInteractive) == Self.rgb(Color.zapPrimary))
        #expect(try Self.near(Self.alpha(Color.zapInteractive), ResolvedTheme.interactiveOpacity))
        #expect(try Self.near(Self.alpha(Color.zapLink), ResolvedTheme.linkOpacity))
        #expect(try Self.near(Self.alpha(Color.zapSubtle), ResolvedTheme.subtleOpacity))
        #expect(try Self.near(Self.alpha(Color.zapSubtleFill), ResolvedTheme.subtleFillOpacity))
        #expect(try Self.argb(Color.borderSubtle) == Self.argb(custom.dark.outline))
    }

    /// On the brand theme the value tier (`wispZapColor`) and the primary
    /// tier are one colour, so a zap amount and the compose FAB match.
    @Test func brandTheme_zapValueTier_equalsPrimary() throws {
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
        let theme = settings.resolveTheme(systemColorScheme: .dark)
        #expect(try Self.argb(theme.zap) == Self.argb(theme.primary))
        #expect(try Self.rgb(theme.interactive) == Self.rgb(theme.zap))
    }

    // MARK: - Increased contrast

    @Test func increasedContrast_collapsesTextTiersToPrimary_andDeepensWashes() throws {
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

        let standard = settings.resolveTheme(systemColorScheme: .dark, contrast: .standard)
        #expect(!standard.increasedContrast)
        #expect(try Self.near(Self.alpha(standard.interactive), ResolvedTheme.interactiveOpacity))

        let increased = settings.resolveTheme(systemColorScheme: .dark, contrast: .increased)
        #expect(increased.increasedContrast)
        #expect(try Self.argb(increased.interactive) == Self.argb(increased.primary))
        #expect(try Self.alpha(increased.interactive) == 1.0)
        #expect(try Self.alpha(increased.link) == 1.0)
        #expect(try Self.alpha(increased.subtle) > Self.alpha(standard.subtle))
        #expect(try Self.alpha(increased.subtleFill) > Self.alpha(standard.subtleFill))
        // Primary, zap and the palette are untouched by the contrast setting.
        #expect(try Self.argb(increased.primary) == Self.argb(standard.primary))
        #expect(try Self.argb(increased.zap) == Self.argb(standard.zap))
        #expect(increased.palette == standard.palette)
        // The default parameter is the standard resolution.
        #expect(settings.resolveTheme(systemColorScheme: .dark) == standard)
    }

    // MARK: - Consumers

    /// The composer paints mention pills at the interactive tier and URL
    /// runs at the link tier — the same treatment the rendered post gets.
    @Test func composerStyling_ridesTheTiers() throws {
        let saved = ResolvedThemeProxy.current
        defer { ResolvedThemeProxy.update(saved) }
        ResolvedThemeProxy.update(.default)
        #expect(try Self.rgb(ComposerTextStyling.pillTextColor) == Self.rgb(UIColor(Color.zapPrimary)))
        #expect(try Self.near(Self.alpha(ComposerTextStyling.pillTextColor), ResolvedTheme.interactiveOpacity))
        #expect(try Self.near(Self.alpha(ComposerTextStyling.linkColor), ResolvedTheme.linkOpacity))
        #expect(try Self.near(Self.alpha(ComposerTextStyling.pillFillColor), ResolvedTheme.subtleFillOpacity))
    }

    // MARK: - Contrast (measured, composited over the custom dark grounds)

    /// WCAG 2 contrast of each text tier, composited with its alpha over
    /// every custom dark ground. Primary is pinned at AA normal text
    /// elsewhere (`BrandColorParityTests`); the interactive tier holds AA on
    /// the feed background and stays within a tenth of it on the surfaces;
    /// the link tier clears the AA large-text / UI-component floor (3.0)
    /// everywhere. Increased Contrast restores the 100% figures.
    @Test func textTiers_keepTheirContrastFloors_onEveryCustomDarkGround() throws {
        let dark = Themes.get("custom").dark
        let primary = try Self.argb(dark.primary)
        let grounds = [("background", dark.background), ("surface", dark.surface), ("surfaceVariant", dark.surfaceVariant)]
        for (name, ground) in grounds {
            let g = try Self.argb(ground)
            let full = Self.contrast(primary, g)
            let interactive = Self.contrast(Self.composite(primary, over: g, alpha: ResolvedTheme.interactiveOpacity), g)
            let link = Self.contrast(Self.composite(primary, over: g, alpha: ResolvedTheme.linkOpacity), g)
            #expect(full > interactive && interactive > link, "\(name): \(full) / \(interactive) / \(link)")
            #expect(interactive >= (name == "background" ? 4.5 : 3.8), "\(name) interactive: \(String(format: "%.2f", interactive))")
            #expect(link >= 3.0, "\(name) link: \(String(format: "%.2f", link))")
        }
    }

    // MARK: - Helpers

    private static func near(_ a: CGFloat, _ b: Double, tolerance: Double = 0.005) -> Bool {
        abs(Double(a) - b) <= tolerance
    }

    private static func alpha(_ color: Color) throws -> CGFloat { try alpha(UIColor(color)) }

    private static func alpha(_ color: UIColor) throws -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        try #require(color.getRed(&r, green: &g, blue: &b, alpha: &a), "\(color) has no RGB components")
        return a
    }

    private static func rgb(_ color: Color) throws -> Int { try rgb(UIColor(color)) }

    private static func rgb(_ color: UIColor) throws -> Int { try argb(color) & 0x00FFFFFF }

    private static func argb(_ color: Color) throws -> Int { try argb(UIColor(color)) }

    private static func argb(_ color: UIColor) throws -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        try #require(color.getRed(&r, green: &g, blue: &b, alpha: &a), "\(color) has no RGB components")
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
}
