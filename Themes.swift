import SwiftUI

/// The one Zap Cooking theme, as a light/dark palette pair.
///
/// The app used to ship fifteen selectable presets (Nord, Dracula, Gruvbox,
/// …) behind a picker in Interface settings. Android has no such picker, so
/// the presets and the `themeName` preference that chose between them are
/// gone; Appearance (System / Light / Dark) is the only thing that decides
/// which of these two palettes is in play.
nonisolated enum Themes {
    /// Brand primary, dark side: web `src/app.css` (`--color-primary`) and
    /// Android `Themes.kt` both ship #FF5722 here (`AppSettings.defaultAccentARGB`).
    /// Zap and bookmark repeat primary so every zap surface reads as one hue.
    /// Android's BrandColors.kt amber→orange pair is its FAB gradient, not
    /// the theme primary.
    static let dark = ThemePalette(
        primary: .hex(0xFFFF5722), secondary: .hex(0xFFFF7A3D),
        // Dark blue-grey — web `--color-bg-primary` / Android Themes.kt
        // zapcooking dark (Tailwind gray-800/900 pair), not the neutral
        // near-black Wisp shipped.
        background: .hex(0xFF111827), surface: .hex(0xFF1F2937),
        surfaceVariant: .hex(0xFF374151),
        onBackground: .hex(0xFFF3F4F6), onSurface: .hex(0xFFF3F4F6),
        onSurfaceVariant: .hex(0xFFD1D5DB), outline: .hex(0xFF4B5563),
        zap: .hex(0xFFFF5722), repost: .hex(0xFF4CAF50),
        bookmark: .hex(0xFFFF5722), paid: .hex(0xFFFFD54F)
    )

    /// Light side of the same brand pair — #EC4700, deeper than the dark
    /// primary so it holds contrast against a near-white ground.
    static let light = ThemePalette(
        primary: .hex(0xFFEC4700), secondary: .hex(0xFFFF7A3D),
        background: .hex(0xFFD8D8D8), surface: .hex(0xFFE8E8E8),
        surfaceVariant: .hex(0xFFCDCDCD),
        onBackground: .hex(0xFF1C1B1F), onSurface: .hex(0xFF1C1B1F),
        onSurfaceVariant: .hex(0xFF333333), outline: .hex(0xFF999999),
        zap: .hex(0xFFEC4700), repost: .hex(0xFF2E7D32),
        bookmark: .hex(0xFFEC4700), paid: .hex(0xFFC9A000)
    )

    static func palette(isDark: Bool) -> ThemePalette { isDark ? dark : light }
}
