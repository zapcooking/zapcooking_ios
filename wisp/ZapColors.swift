import SwiftUI

// Zap Cooking colour hierarchy.
//
// The app is black/dark with one brand orange (#FF5722 dark / #EC4700
// light, `AppSettings.defaultAccentARGB` → `resolveTheme` → the active
// `ResolvedTheme`). Orange means interaction, action, an active state, or
// value; white is content; gray is supporting interface; green and the
// other palette semantics (`wispRepostColor`, `wispPaidColor`, the amber
// unread dot) keep their state-specific meaning. Food photography and user
// content — avatars included, which are never recoloured — provide most of
// a screen's colour.
//
// One hue, four intensities, resolved once in `ResolvedTheme` so views
// never hand-roll `.opacity(...)` on the accent:
//
//   tier            accessor            use
//   ─────────────── ─────────────────── ───────────────────────────────────
//   100%            `zapPrimary`        compose FAB, selected bottom-bar
//                   (= `wispPrimary`)   glyph, primary buttons, active
//                                       bookmark, "new posts" pill
//   100% (value)    `wispZapColor`      the bolt glyph and a sat amount that
//                                       represents value transferred (zap
//                                       action once you zapped, zap pill,
//                                       zap notifications, receipts)
//   ~90%            `zapInteractive`    @mentions, #hashtags, in-content
//                                       secondary actions ("Show more",
//                                       "Retry", "+3 more"), badge labels
//   ~80%            `zapLink`           URLs, link cards' action line,
//                                       article markdown links, composer
//                                       link runs
//   ~30%            `zapSubtle`         hairline accent strokes (zap pill
//                                       capsule)
//   ~14%            `zapSubtleFill`     tinted washes behind an accent label
//                                       (ARTICLE / MUSIC / PoW badges, the
//                                       "Private" pill, thread highlight)
//
//   neutral         `textPrimary`       post body, usernames, titles
//   neutral         `textSecondary`     timestamps, counts, inactive
//                                       engagement glyphs, metadata, the
//                                       zap pill's message text
//   neutral         `borderSubtle`      neutral hairlines (palette outline)
//
// On the custom (brand) theme `zapPrimary` and `wispZapColor` are the same
// colour; curated presets keep their own zap swatch, so a sat amount stays
// on `wispZapColor` and never on `zapPrimary`. With the system "Increase
// Contrast" setting on, the ~90% / ~80% tiers resolve to the full primary
// and the washes deepen (`ResolvedTheme.increasedContrast`).
//
// `nonisolated` for the same reason as the `wisp*` accessors: these are
// read from `UIViewRepresentable` coordinators and attributed-string
// builders off the main actor. `ResolvedThemeProxy` is lock-protected.
nonisolated extension Color {
    /// 100% brand orange — the primary action tier. Same value as
    /// `wispPrimary`; this name states the tier where the call site is
    /// deciding between tiers.
    static var zapPrimary: Color { ResolvedThemeProxy.current.primary }
    /// ~90% — short interactive entities inside content.
    static var zapInteractive: Color { ResolvedThemeProxy.current.interactive }
    /// ~80% — URLs and link text.
    static var zapLink: Color { ResolvedThemeProxy.current.link }
    /// ~30% — accent hairlines and inactive accent marks.
    static var zapSubtle: Color { ResolvedThemeProxy.current.subtle }
    /// ~14% — accent washes behind an accent-coloured label.
    static var zapSubtleFill: Color { ResolvedThemeProxy.current.subtleFill }

    /// High-emphasis system text: white on the dark theme.
    static var textPrimary: Color { .primary }
    /// Supporting gray: timestamps, counts, metadata, inactive glyphs.
    static var textSecondary: Color { .secondary }
    /// Neutral hairline, the palette outline.
    static var borderSubtle: Color { ResolvedThemeProxy.current.palette.outline }
}
