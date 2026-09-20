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
        let dark = Themes.dark
        ResolvedThemeProxy.update(ResolvedTheme(
            isDark: true, palette: dark,
            primary: dark.primary, zap: dark.zap, bookmark: dark.bookmark,
            zapAnimation: dark.zap
        ))
        #expect(try Self.argb(Color.zapPrimary) == Self.brandDark)
        #expect(try Self.argb(Color.zapPrimary) == Self.argb(Color.wispPrimary))
        #expect(try Self.rgb(Color.zapInteractive) == Self.rgb(Color.zapPrimary))
        #expect(try Self.near(Self.alpha(Color.zapInteractive), ResolvedTheme.interactiveOpacity))
        #expect(try Self.near(Self.alpha(Color.zapLink), ResolvedTheme.linkOpacity))
        #expect(try Self.near(Self.alpha(Color.zapSubtle), ResolvedTheme.subtleOpacity))
        #expect(try Self.near(Self.alpha(Color.zapSubtleFill), ResolvedTheme.subtleFillOpacity))
        #expect(try Self.argb(Color.borderSubtle) == Self.argb(dark.outline))
    }

    /// On the brand theme the value tier (`wispZapColor`) and the primary
    /// tier are one colour, so a zap amount and the compose FAB match.
    @Test func brandTheme_zapValueTier_equalsPrimary() throws {
        let settings = AppSettings.shared
        let saved = settings.colorScheme
        defer { settings.colorScheme = saved }
        settings.colorScheme = .dark
        let theme = settings.resolveTheme(systemColorScheme: .dark)
        #expect(try Self.argb(theme.zap) == Self.argb(theme.primary))
        #expect(try Self.rgb(theme.interactive) == Self.rgb(theme.zap))
    }

    // MARK: - Increased contrast

    @Test func increasedContrast_collapsesTextTiersToPrimary_andDeepensWashes() throws {
        let settings = AppSettings.shared
        let saved = settings.colorScheme
        defer { settings.colorScheme = saved }
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

    // MARK: - Contrast (measured on the grounds that actually render)

    /// The dark grounds orange tier text is really painted on. `surfaceVariant`
    /// is almost never a text ground at full strength: quoted notes, link
    /// previews and the rich-content embeds fill with it at 30% over the feed
    /// background and stroke with it; the reply / quote banners use 40%; the
    /// "Show more" pill, hashtag chips and reaction chips use 60%; only the
    /// group-chat bubble (`GroupRoomView`) hosts rich content on the raw token.
    /// Measuring the raw token alone (the pre-#117 version of this test) both
    /// missed the 60% chips and failed a ground that renders once.
    static let interactiveFloorOnBackground = 4.5
    static let interactiveFloorOnSurfaces = 3.8
    static let linkFloor = 3.0

    /// Composited dark ground: `wash` of `surfaceVariant` over `base`
    /// (`wash == 1` is the raw token).
    private static func ground(_ palette: ThemePalette, wash: Double, over base: Color) throws -> Int {
        let sv = try argb(palette.surfaceVariant), b = try argb(base)
        return wash >= 1 ? sv : composite(sv, over: b, alpha: wash)
    }

    private static func measure(_ name: String, _ ground: Int, primary: Int,
                                interactiveFloor: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let full = contrast(primary, ground)
        let interactive = contrast(composite(primary, over: ground, alpha: ResolvedTheme.interactiveOpacity), ground)
        let link = contrast(composite(primary, over: ground, alpha: ResolvedTheme.linkOpacity), ground)
        #expect(full > interactive && interactive > link, "\(name): \(full) / \(interactive) / \(link)", sourceLocation: sourceLocation)
        #expect(interactive >= interactiveFloor, "\(name) interactive: \(String(format: "%.2f", interactive)) (floor \(interactiveFloor))", sourceLocation: sourceLocation)
        #expect(link >= linkFloor, "\(name) link: \(String(format: "%.2f", link)) (floor \(linkFloor))", sourceLocation: sourceLocation)
    }

    /// WCAG 2 contrast of each text tier, composited with its alpha over the
    /// rendered dark grounds: the feed background, the surface, and the 25%,
    /// 30% and 40% `surfaceVariant` washes over the background (thread and
    /// notification rows, quoted notes, link previews, embeds, the reply and
    /// quote banners — post cards have no fill of their own, so these washes
    /// sit on the feed background), plus the deepest nesting the feed
    /// produces: a quoted note (30%) inside an expanded notification row
    /// (25%). The interactive tier holds AA on the feed background and stays
    /// within a tenth of it on the washes; the link tier clears the AA
    /// large-text / UI-component floor everywhere. Increased Contrast
    /// restores the 100% figures.
    @Test func textTiers_keepTheirContrastFloors_onTheRenderedDarkGrounds() throws {
        let dark = Themes.dark
        let primary = try Self.argb(dark.primary)
        Self.measure("background", try Self.argb(dark.background), primary: primary, interactiveFloor: Self.interactiveFloorOnBackground)
        Self.measure("surface", try Self.argb(dark.surface), primary: primary, interactiveFloor: Self.interactiveFloorOnSurfaces)
        for wash in [0.25, 0.3, 0.4] {
            Self.measure("surfaceVariant@\(wash) over background", try Self.ground(dark, wash: wash, over: dark.background),
                         primary: primary, interactiveFloor: Self.interactiveFloorOnSurfaces)
        }
        let row = try Self.ground(dark, wash: 0.25, over: dark.background)
        let nested = Self.composite(try Self.argb(dark.surfaceVariant), over: row, alpha: 0.3)
        Self.measure("surfaceVariant@0.3 inside a @0.25 notification row", nested,
                     primary: primary, interactiveFloor: Self.interactiveFloorOnSurfaces)
    }

    /// The 60% wash is the chip recipe (`PostCardView` "Show more" pill,
    /// `HashtagChipsView`, `ArticleView` topic chip, reaction chips), where the
    /// interactive tier is used as text. Over the feed background it measures
    /// 3.59 against the 3.8 floor; over a surface card 3.31 / 2.88. KNOWN
    /// FAILURE, issue #134 — listed in `ci_scripts/gate.sh` `KNOWN_FAILURES`
    /// until the chip recipe changes. Do not lower the floors to pass it.
    @Test func textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes() throws {
        let dark = Themes.dark
        let primary = try Self.argb(dark.primary)
        Self.measure("surfaceVariant@0.6 over background", try Self.ground(dark, wash: 0.6, over: dark.background),
                     primary: primary, interactiveFloor: Self.interactiveFloorOnSurfaces)
        Self.measure("surfaceVariant@0.6 over surface", try Self.ground(dark, wash: 0.6, over: dark.surface),
                     primary: primary, interactiveFloor: Self.interactiveFloorOnSurfaces)
    }

    /// The raw token (#374151, Android/web parity, pinned in
    /// `BrandColorParityTests`) as a text ground. It renders as one exactly once:
    /// the group-chat bubble for other people's messages
    /// (`wisp/GroupRoomView.swift`, `RichContentView` on `wispSurfaceVariant`),
    /// where hashtags and mentions sit at the interactive tier (2.88 against
    /// 3.8) and URLs at the link tier (2.53 against 3.0). KNOWN FAILURE, issue
    /// #117 — the fix is on the bubble, not the token, and only if group chat
    /// ships. Listed in `ci_scripts/gate.sh` `KNOWN_FAILURES`.
    @Test func textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble() throws {
        let dark = Themes.dark
        let primary = try Self.argb(dark.primary)
        Self.measure("surfaceVariant (group-chat bubble)", try Self.ground(dark, wash: 1, over: dark.background),
                     primary: primary, interactiveFloor: Self.interactiveFloorOnSurfaces)
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
