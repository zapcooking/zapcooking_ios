import SwiftUI

nonisolated struct ThemePalette: Equatable {
    let primary: Color
    let secondary: Color
    let background: Color
    let surface: Color
    let surfaceVariant: Color
    let onBackground: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let outline: Color
    let zap: Color
    let repost: Color
    let bookmark: Color
    let paid: Color
}

nonisolated struct ResolvedTheme: Equatable {
    let isDark: Bool
    let palette: ThemePalette
    let primary: Color
    /// Resolved zap-surface color — the palette's own `zap` swatch, which
    /// is the brand primary on both sides, so zap icon / count / top-zapper
    /// indicators read as one hue with the rest of the theme. See
    /// LIGHT_MODE_COLOR_PARITY.md (Wisp Android repo) for the
    /// cross-platform contract.
    let zap: Color
    /// Same rationale as `zap`.
    let bookmark: Color
    /// Vivid variant of `zap` reserved for the celebratory in-flight bolt
    /// animation. Plain `zap` reads muddy in light mode because the
    /// primary is darkened for contrast; the burst needs a brighter
    /// floor or the animation looks dim against the near-white surface.
    /// Static UI everywhere else uses `zap`, not this.
    let zapAnimation: Color

    static let `default` = ResolvedTheme(
        isDark: true,
        palette: Themes.dark,
        primary: Color(argb: AppSettings.defaultAccentARGB),
        zap: Color(argb: AppSettings.defaultAccentARGB),
        bookmark: Color(argb: AppSettings.defaultAccentARGB),
        zapAnimation: Color(argb: AppSettings.defaultAccentARGB)
    )
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: ResolvedTheme = .default
}

extension EnvironmentValues {
    var theme: ResolvedTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

@MainActor
extension AppSettings {
    /// Appearance is the only input now: System follows the device, Light
    /// and Dark pin it. There is one theme, so the chosen side of
    /// `Themes` supplies every color — the accent picker and the fifteen
    /// selectable presets are both gone, and with them the accent override
    /// and its light-mode darkening step.
    func resolveTheme(systemColorScheme: ColorScheme?) -> ResolvedTheme {
        let useDark: Bool
        switch colorScheme {
        case .system: useDark = (systemColorScheme ?? .dark) == .dark
        case .light:  useDark = false
        case .dark:   useDark = true
        }
        let palette = Themes.palette(isDark: useDark)
        return ResolvedTheme(
            isDark: useDark,
            palette: palette,
            primary: palette.primary,
            zap: palette.zap,
            bookmark: palette.bookmark,
            zapAnimation: Self.vividZapColor(palette.zap)
        )
    }

    /// Vivid variant of a zap color for the in-flight bolt animation.
    /// Bumps saturation 15% (capped at 1.0) and floors brightness at 0.5
    /// so the celebratory pulse never reads muddy or dark on the light
    /// surface. Mirrors `vividZapColor` in Wisp Android's Theme.kt.
    nonisolated static func vividZapColor(_ color: Color) -> Color {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        let saturation = min(1.0, s * 1.15)
        let brightness = max(0.5, b)
        return Color(UIColor(hue: h, saturation: saturation, brightness: brightness, alpha: a))
    }
}
