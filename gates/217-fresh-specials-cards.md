# GATE — fresh/specials-cards (PR #217: Fresh specials S3)

Based on main. #216 and #218 are merged; main e791f73 came in as
**1572fec**. The only conflict was `FreshScreenshotFixturesTests.swift`,
where both sides had added tests at the end of the suite; all three were
kept. This branch's code commits are 8f53e4d (cards) and cd8185a
(device-pass fixes). This file replaces gate 501e133 and is the HEAD
commit. A review fix breaks the freeze: push a fresh gate file last.

**What the merge brings:** #218's recipe-row rule (`RecipeParser.isRecipe`
in `loadRecipes`). It merged cleanly next to this branch's box pool. Both
sides had made the same `longForm` test-helper change.

## cd8185a: Seth's device-pass fixes
1. **Mentions rendered raw in spotlight tiles.**
   - `plainText` now uses `ContentParser`, with no second parser.
   - A profile mention reads `@name`, using `RichInlineTextView.mentionName`.
     That rule was extracted from the inline renderer, and the feed still
     uses it.
   - Note, nevent and naddr references, links and media are dropped.
2. **Spotlight authors had no profile.** A readied spotlight now asks for
   its authors' and mentioned people's profiles before it is placed.
3. **The recipe box took a tagged article.** `FreshRecipeBox.isCandidate`
   now uses `RecipeParser.isRecipe`. The finish-line row's half of this fix
   is #218.

`freshSpecialsEnabled` is `false`. No test opens a socket or makes a
network request, publishes an event or sends AUTH. The screenshots come
from the in-app fixture relay with a watch-only account.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), DerivedData `wisp-specials-cards` (cold at
fd98482, then incremental): **TEST BUILD SUCCEEDED** at 1572fec. Zero
warnings in `RichInlineTextView.swift`, `wispTests/FreshSpecialsTests.swift`,
`wispTests/FreshFeedViewModelTests.swift`, `wisp/FreshFeedViewModel.swift`, `wisp/FreshSpecialCards.swift`,
`wisp/FreshRecipeBox.swift`, `wisp/FreshScreenshotFixtures.swift`,
`wisp/FreshScreenshotHarness.swift`, `MainView.swift`,
`wispTests/FreshSpecialsListTests.swift`,
`wispTests/FreshScreenshotFixturesTests.swift` and
`wispUITests/FreshScreenshotsUITests.swift`.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-specials-cards \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath s3e-gate.xcresult
sh ci_scripts/gate.sh --parse s3e-gate.xcresult
```
```
gate: 1955 passed / 3 failed / 23 skipped / 1981 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1981 tests ran
```
First full run at 1572fec. (Earlier: 1945/1971 at 8f53e4d, 1950/1976 at
cd8185a and 1953/1979 at 9cd92ca.) New tests:
- `FreshSpecialsListTests` (18). Four came with cd8185a:
  - tile text with mentions;
  - profiles requested when a spotlight is readied;
  - a tile whose profiles arrive after it is on screen;
  - a tagged article never becomes a box card.
- `FreshScreenshotFixturesTests`: `fixtureSpecials` and
  `fixtureSpotlightMention`.
- `FreshRecipeBoxTests/candidates`: now includes a tagged article.

**Mutation check.** With the loader's `onChange` set back to
`decideSlots()` (no profile request), `spotlightRequestsProfiles` fails.
`lateProfilesReachTheTile` still passes under that mutation, because the
`updates()` path delivered late profiles before this fix too. That test
covers the arrival path, not the request.

Also covered: the unchanged `FreshFeedViewModelTests` (the flag-off
behaviour) and `FreshCopyTests` (which scans `FreshSpecialCards.swift`). No
local patch. No `project.pbxproj` diff.

## Gate 3: screenshots (not part of the hermetic run)
`wispUITests/FreshScreenshotsUITests/testFreshSpecialCards` on the
simulators shots-iphone-18pro (iPhone 18 Pro) and shots-ipad-13 (iPad Pro
13" M5), iOS 27.2. Nine JPEGs are in `docs/screenshots/fresh/`. At
cd8185a, iPhone and iPad (portrait and landscape) each passed once, and the
six spotlight shots were re-taken: the Japanese tile now reads
"@June Okafor".

Earlier runs failed, and each failure was fixed:
- **iPhone, first slot skipped.** Recipes are now asked for along with
  page 1.
- **iPhone, spotlight slot went to a recipe.** The loader race, fixed on
  #216 as 21abb18.
- **iPad portrait, first slot skipped.** Post 7 is already on screen when
  page 1 draws (by design, as on web). With `-FreshScreenshotSpecials`, the
  fixture relay now holds page 1 for 0.4 s.

## Not gated
- No device pass (S5 waits for Seth's), and no live relay.
- Slot distances (decide within 12 posts, strict beyond 4) are index
  stand-ins for web's geometry, not measured on a device.
