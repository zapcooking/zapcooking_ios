# GATE — fresh/specials-logic (PR #215: Fresh specials S1)

Branched from main at 4631b6a. Two commits: e44d46e (the paging test, red
on main) and **ecea1b9 (code frozen)**. This file is the only commit after them,
and it is the HEAD commit. A review fix breaks the freeze: push a fresh
gate file last.

Pure logic and stores only. Nothing calls them, `freshSpecialsEnabled` is
`false`, and no test opens a socket, publishes an event or sends AUTH.

## Gate 0: the paging off-by-one, red then green
`FreshFeedViewModelTests/pagingThresholdCountsPostsNotRows` at e44d46e (main's
view model):
```
✘ … recorded an issue at FreshFeedViewModelTests.swift:482:9: Expectation failed: reqs(rig.transport.latest).count == sent
```
With the divider above, the seventh post from the end paged. At ecea1b9 it
passes, inside the full run below.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), DerivedData `wisp-specials` (cold at
e44d46e, then incremental; every touched file recompiled): **TEST BUILD
SUCCEEDED**. Zero warnings in `wisp/FreshSpecials.swift`,
`wisp/FreshRecipeBox.swift`, `wisp/FreshSpecialsStore.swift`,
`wisp/FreshFeedViewModel.swift`, `NostrKey.swift`, `FeatureFlags.swift`,
`wispTests/FreshSpecialsTests.swift` and
`wispTests/FreshFeedViewModelTests.swift`.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-specials \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath gs1.xcresult
sh ci_scripts/gate.sh --parse gs1.xcresult
```
```
gate: 1877 passed / 3 failed / 23 skipped / 1903 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1903 tests ran
```
First full run at ecea1b9. New suites: `FreshSpecialsTests` (23),
`FreshRecipeBoxTests` (5) and `FreshSpecialsStoreTests` (5). The full run
also covers `FreshFeedViewModelTests` (the recipe row is now routed through
`rowPicks`) and `FreshCopyTests`. No local patch. No `project.pbxproj` diff.

## Not gated
- No UI and no device pass: nothing is wired yet (S3).
- The rotation's equivalence to web's five-step pattern with memory never
  available is argued in the code, not tested against web's code.
- Spotlight posts' Report and Block land with the cards (S3).
