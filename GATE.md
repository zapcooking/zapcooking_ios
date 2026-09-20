# GATE — concern/color-hierarchy (one brand orange, four intensities)
Visual-system refactor only: no new event kind, nothing published, no
network change, so §7.13's live-write protocol does not apply. Off main at
e53d346 (#89), rebased there after #90's Copilot review (the only conflict
was #89's GATE.md, replaced by this one). Local build + serial suites on
Seth's MacBook Air (the Air is the gate machine until the Mac Studio lands);
the box block below is the standard form for the Studio.

**Frozen at this commit.** App code is frozen at **ea500a6** (95954f5, the
rebased refactor, plus ea500a6, the Copilot review fixes: MusicTrackCardView
retry arrow and the "+N more" zap badge → `zapInteractive`, the
RichInlineTextView comment, the gray-message assertion in the pill render
test). The previous GATE.md (31d4bfa, at fac5921) is superseded. This
GATE.md is the only commit after ea500a6 and is the HEAD commit — `gate.sh`
refuses to run otherwise. A review fix re-opens the freeze: push a fresh
GATE.md last.

## What landed
- `Theme.swift` — `ResolvedTheme` derives `interactive` (0.90), `link`
  (0.80), `subtle` (0.30) and `subtleFill` (0.14) from `primary` in one
  explicit init; `resolveTheme(systemColorScheme:contrast:)` collapses the
  text tiers to full primary under Increase Contrast (`RootContainer` reads
  `\.colorSchemeContrast`).
- `wisp/ZapColors.swift` — the documented ladder and the accessors
  `Color.zapPrimary` / `zapInteractive` / `zapLink` / `zapSubtle` /
  `zapSubtleFill` / `textPrimary` / `textSecondary` / `borderSubtle`.
- Migrated: `RichInlineTextView` (#hashtag / @mention → interactive, URL →
  link), `ComposerTextStyling`, `ArticleView` markdown links,
  `LinkPreviewView` (raw URL → link tier; card = site gray / title white /
  domain gray + "Open ↗" link tier), `TopZapperPill` (bolt + amount value
  tier, message gray, capsule `zapSubtle`; now internal), `PostCardView`
  in-content actions and the "Private" pill, `QuotedNoteView`, `ThreadView`,
  `NotificationRowView` poll labels / badges / washes, the ARTICLE / MUSIC /
  PoW badges and both card retry arrows.
- Not moved (semantic or primary-tier): compose FABs, selected bottom-bar
  glyph, new-posts pill, zap action tint, bookmark active, repost green,
  paid amber, unread dot, `.orange` warning glyphs, avatars, curated
  presets, wallet / onboarding / settings accents.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2, shared DerivedData,
  `-skipPackagePluginValidation`): **green** at fac5921 and again at
  ea500a6. Warnings in touched files: **zero** (the only "ThreadView*" hits
  are `ThreadViewModel.swift`, untouched). Total warning lines 701 —
  pre-existing Swift 6 diagnostics, none from this branch.
- Serial runs on the Air (`-parallel-testing-enabled NO`): at fac5921,
  `ColorHierarchyTests` + `BrandColorParityTests` + `EmptyStateGroundTests`
  **16/16** in 76 s and `ColorHierarchyRenderTests` **4/4** in 51 s (after
  two test-only fixes: the nested window host needed `@MainActor`, and the
  ImageRenderer roots needed `.environment(AppSettings.shared)` for the
  pill's avatar). At ea500a6, `ColorHierarchyTests` +
  `ColorHierarchyRenderTests` **10/10** serial. Renders written to
  `wispTests/.zc_snapshot_dir`: `hierarchy-ladder-dark`,
  `hierarchy-ladder-dark-ax2`, `zap-pill-dark`, `zap-pill-dark-no-message`,
  `rich-text-tiers-dark`.
- pbxproj: no diff (three-dot). New files are under `wisp/` and `wispTests/`.
- Gate 4 (by hand) is Seth's device pass: OnlyFood + Follows feeds, a post
  with #hashtags / @mentions / a long raw URL / a link card, the zap pill,
  the zap action once zapped, bottom bar, FAB, colourful avatars, dark
  mode, an accessibility text size, and Settings → Accessibility → Increase
  Contrast (tiers should snap to full orange).

## Gate 1 — hermetic, serial (Mac Studio / box form)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests
```
Pass = main's failure set on that machine and nothing else; judge the
`.xcresult` via `xcresulttool get test-results summary`
(`sh ci_scripts/gate.sh --parse <bundle>`). Expect +10 tests over main
(`ColorHierarchyTests` 6, `ColorHierarchyRenderTests` 4).

## Gate 2 — the colour suites alone
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/ColorHierarchyTests \
  -only-testing:wispTests/ColorHierarchyRenderTests \
  -only-testing:wispTests/BrandColorParityTests
```
Put a directory in `wispTests/.zc_snapshot_dir` first to keep the PNGs.

## Gate 6 — project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Must print nothing.
