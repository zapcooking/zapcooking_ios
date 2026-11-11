# GATE — fix/fresh-recipe-row-recipes-only (PR #218)

Branched from main at 45842df. One code commit, **7513ec4 (code frozen)**.
This file is the only commit after it, and it is the HEAD commit. A review
fix breaks the freeze: push a fresh gate file last.

## Gate 0: red on main, green here
`FreshFeedViewModelTests/recipeRowSkipsTaggedArticles`, run with main's
`FreshFeedViewModel.swift` and this branch's tests:
```
✘ … FreshFeedViewModelTests.swift:282:9: Expectation failed: await eventually { rig.vm.recipePicks.map(\.id) == [recipe.id] }
✘ … FreshFeedViewModelTests.swift:283:9: Expectation failed: !rig.vm.recipePool.contains { $0.id == article.id }
```
At 7513ec4 it passes, inside the full run below.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), DerivedData `wisp-pr195` (incremental;
every touched file recompiled): **TEST BUILD SUCCEEDED**. Zero warnings in
`wisp/FreshFeedViewModel.swift`, `wispTests/FreshFeedViewModelTests.swift`
and `wispTests/FreshScreenshotFixturesTests.swift`.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-pr195 \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath a-gate.xcresult
sh ci_scripts/gate.sh --parse a-gate.xcresult
```
```
gate: 1901 passed / 3 failed / 23 skipped / 1927 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1927 tests ran
```
First full run at 7513ec4. No local patch. No `project.pbxproj` diff.

## Not gated
- No device pass, and no live relay. The real Branta event was not
  fetched; the test builds an article of the same shape.
