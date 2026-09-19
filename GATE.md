# GATE — concern/brand-color-parity
The iOS accent — bottom-bar flame, compose FABs, new-posts pill, link/hashtag/
mention text, reply pencil — was still Wisp's #FF9800 on the dark side. Web
(`src/app.css` `--color-primary`) and Android (`Themes.kt`) ship #EC4700 light /
#FF5722 dark; iOS light already resolved to #EC4700. Token values change, not call
sites: `AppSettings.defaultAccentARGB` (with a legacy #FF9800 → default migration),
`ResolvedTheme.default`, the custom preset's dark primary/zap/bookmark, and the
empty `AccentColor` catalog entry. Own branch off main at d4eee13 (the #81 merge).
Local build only on Seth's MacBook Air; gates run on the MacinCloud box by hand.

**Frozen at this commit.** App code is frozen at **6026fd6**. This GATE.md is the only
commit after it and is the HEAD commit — `gate.sh` refuses to run otherwise. A
review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- Build (iPhone 17 / OS 26.2, incremental behind `xcodebuild test`): **green** at
  6026fd6. Two builds this session (2026-09-19): the first introduced ten Swift 6
  isolation warnings in `AppSettings.swift`/`Theme.swift` (the two new constants on
  the MainActor class read from nonisolated code) — fixed with `nonisolated`; the
  second is the green one. Free disk 17 GB before, 13 GB after (the usual transient
  simulator dip; 16 GB between runs); no local Time Machine snapshots.
- Warnings in touched files (`AppSettings.swift`, `Theme.swift`, `Themes.swift`,
  `wispTests/BrandColorParityTests.swift`): **zero**.
- Serial run on the Air (the C-G exception form): `BrandColorParityTests` 7/7,
  `EmptyStateGroundTests` 3/3, `FeedTopBarPolishTests` 9/9 (the suites that read the
  theme). PNGs of the FAB, the pill and hashtag text on the custom dark and light
  grounds examined: deep orange #FF5722 on dark, #EC4700 on light, one hue each.
- pbxproj: no diff (three-dot). `wispTests/BrandColorParityTests.swift` is
  self-registering; the colorset edit is inside the `Assets.xcassets` folder reference.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout concern/brand-color-parity && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh concern/brand-color-parity
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on concern/brand-color-parity @ <this commit>`, with the four known
failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the three
`SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **849** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 842; the delta is **+7**
(`BrandColorParityTests` 7). If the parsed total is 842 the run was on a stale tree.

**Shared settings on the box.** `resolveTheme_customDefaultAccent_yieldsBrandPair`
mutates `AppSettings.shared` (theme, scheme, accent) and restores it in a `defer`;
serial only, as every run here is.

## Gate 2 — the brief's hermetic gates (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'BrandColorParityTests|EmptyStateGroundTests|FeedTopBarPolishTests'
```
- default accent is #FF5722, legacy #FF9800 migrates, a real pick survives:
  `defaultAccent_isBrandDark_andLegacyWispMigrates`
- custom palette and the pre-resolution fallback are the brand pair:
  `customPalette_andFallbackTheme_areTheBrandPair`
- the live path resolves #FF5722 dark / #EC4700 light and never #FF9800:
  `resolveTheme_customDefaultAccent_yieldsBrandPair`
- `AccentColor` asset is the pair in both traits: `accentColorAsset_isTheBrandPair`
- repost, paid, unread dot and the curated presets unchanged: `semanticColors_unchanged`
- #FF5722 ≥ 4.5:1 on background / surface / surfaceVariant (5.90 / 5.24 / 4.51):
  `darkPrimary_clearsAA_onEveryCustomDarkGround`
- FAB, pill and hashtag text carry the primary on both grounds (pixels):
  `brandCarriers_render_onDarkAndLightGrounds`
- everything that reads the theme still passes: `EmptyStateGroundTests` (3),
  `FeedTopBarPolishTests` (9).

## Gate 3 — BY HAND on device: the carriers, light AND dark
Interface → colour scheme, once each. Every orange below is one colour per
scheme: #FF5722 (dark) / #EC4700 (light). Screenshot each.
1. **Tab bar**: selected glyph and the Feed flame in the brand orange; unselected
   grey unchanged; the unread dot stays amber (#FBBF24), visibly lighter than the bar.
2. **A feed post**: hashtag, link and @mention text in the brand orange and readable
   at body and caption size on the card; the repost arrow stays green; a zap count
   or bolt matches the hashtag hue (zap tracks primary on the custom theme).
3. **Compose FAB** (Feed) and the recipe **+** FAB: brand-orange disc, white glyph.
4. **A recipe card**: any tinted element (bookmark, zap) in the brand orange; the
   placeholder art palette unchanged.
5. **A thread**: the reply pencil / reply bar tint and "Mark not spam" in the brand
   orange; the new-posts pill on the feed (post from another account, or wait) in
   the brand orange with white text.
6. **Semantics**: repost green (post → repost), danger red (delete a draft), Nourish
   green scale (Recipes → Nourish) unchanged. Emoji reaction picker: the reacted
   highlight is orange, no longer system blue.
7. **Migration**: an install that had never opened the accent picker lands on the
   brand orange after update. Interface → Accent color → pick any other colour →
   survives relaunch; pick again lands wherever the picker's HSV puts it.

## Gate 4 — semantic colours unchanged (grep against main)
```sh
for p in 4CAF50 2E7D32 FFD54F C9A000 '0xFB / 255, green: 0xBF' '0x22 / 255, green: 0xC5' '0x4A / 255, green: 0xDE' '0x86 / 255, green: 0xEF'; do
  printf '%-32s main=%s branch=%s\n' "$p" "$(git grep -c "$p" origin/main -- '*.swift' | awk -F: '{s+=$NF} END{print s+0}')" "$(git grep -c "$p" -- '*.swift' | awk -F: '{s+=$NF} END{print s+0}')"
done
git grep -nE 'FF9800|F97316' -- '*.swift' ':!wispTests'
```
Every count equal (1/1, 1/1, 2/2, 1/1, 1/1, 2/2, 1/1, 1/1 on the Air). The second
grep returns only the `legacyWispAccentARGB` declaration and its doc comment in
`AppSettings.swift`; no other #FF9800 or #F97316 in app code.

## Gate 5 — pbxproj
`git diff origin/main...HEAD --stat -- wisp.xcodeproj` → empty.

## Results
Pending — recorded in the PR description after Seth's run.
