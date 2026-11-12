# GATE — fresh/specials-on (PR #219: Fresh specials S5, flag on)

Stacked on #217 (`fresh/specials-cards` at cd84956, its gate HEAD). One
code commit, **3ef75ef (code frozen)**. This file is the only commit after
it, and it is the HEAD commit. Merge only after Seth's device pass of #217
with the flag flipped locally.

The only app change: `FeatureFlags.freshSpecialsEnabled = true`.
Test-only changes:
- `FreshSpecialsTests/flagIsOn`
- `FreshTopicListTests/defaultFollowsTheFlag`: a scripted fetch, so no
  network.
- The two `FreshFeedViewModelTests` rigs pass `specialsEnabled: false`.

With the flag on, no test can reach the shared topic list. Every view model
built with specials on is given its topic groups: `FreshSpecialsListTests`
and the screenshot fixtures. No hosted test builds `MainView` or activates
Fresh outside those suites. Nothing publishes an event or sends AUTH.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), DerivedData `wisp-specials-cards`
(incremental): **TEST BUILD SUCCEEDED** at 3ef75ef. Zero warnings in
`FeatureFlags.swift`, `wispTests/FreshSpecialsTests.swift`,
`wispTests/FreshTopicListTests.swift` and
`wispTests/FreshFeedViewModelTests.swift`. No "will never be executed"
warnings anywhere in the build, before or after the flip.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-specials-cards \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath s5-gate.xcresult
sh ci_scripts/gate.sh --parse s5-gate.xcresult
```
```
gate: 1955 passed / 3 failed / 23 skipped / 1981 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1981 tests ran
```
First full run at 3ef75ef. The total equals #217's (one flag test replaced
one, one topic-list test replaced one). No local patch. No
`project.pbxproj` diff.

## Not gated
- The device pass: Seth's, on #217 with the flag flipped locally.
- No live relay or NIP-11 request from tests.
