# GATE — fresh/specials-cards (PR #217: Fresh specials S3)

Stacked on #216 (`fresh/specials-loader` at edd182d, its gate HEAD). One
code commit on top, **8f53e4d (code frozen)**. This file is the only commit
after it, and it is the HEAD commit. A review fix breaks the freeze: push a
fresh gate file last. If #216 changes, this branch merges it and is
re-gated.

`freshSpecialsEnabled` is `false`. No test opens a socket or makes a
network request, publishes an event or sends AUTH. The screenshots come
from the in-app fixture relay with a watch-only account.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), DerivedData `wisp-specials-cards` (cold at
fd98482, then incremental): **TEST BUILD SUCCEEDED** at 8f53e4d. Zero
warnings in `wisp/FreshFeedViewModel.swift`, `wisp/FreshSpecialCards.swift`,
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
  -collect-test-diagnostics never -resultBundlePath s3-gate.xcresult
sh ci_scripts/gate.sh --parse s3-gate.xcresult
```
```
gate: 1945 passed / 3 failed / 23 skipped / 1971 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1971 tests ran
```
First full run at 8f53e4d. New tests:
- `FreshSpecialsListTests` (14)
- `FreshScreenshotFixturesTests/fixtureSpecials`

Also covered: the unchanged `FreshFeedViewModelTests` (the flag-off
behaviour) and `FreshCopyTests` (which scans `FreshSpecialCards.swift`). No
local patch. No `project.pbxproj` diff.

## Gate 3: screenshots (not part of the hermetic run)
`wispUITests/FreshScreenshotsUITests/testFreshSpecialCards` on the
simulators shots-iphone-18pro (iPhone 18 Pro) and shots-ipad-13 (iPad Pro
13" M5), iOS 27.2. Final runs: iPhone passed twice, iPad (portrait and
landscape) passed once. Nine JPEGs are in `docs/screenshots/fresh/`.

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
