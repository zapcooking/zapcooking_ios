# GATE — fix/follows-since-test-landing (PR #212: main red after #194 + #209)

Branched from main at 66bd7a2. **Code frozen at 3828145** (test only). This
file is the only commit after it, and it is the HEAD commit.

## What it fixes
`FollowsSinceTests/pickingFollowsAfterOnlyFood_asksForTheWholeDefaultWindow`
fails on main 66bd7a2 (`vm.currentKind` is `.fresh`, not `.onlyFood`).
#194 wrote it when a new account landed on OnlyFood. #209 made new sign-ins
land on Fresh. The test now stores ONLY_FOOD for its throwaway account, as an
existing account would have.

Evidence that main is red without this fix: full serial runs of three
branches, each with main 66bd7a2 merged in, that never touch
`FollowsSinceTests`, `FeedViewModel` or `FeedKindStore`: #195 (4f3e66e),
#196 (30799b1) and #184 (1ec4498). Each failed the known set plus this test,
and nothing else.

## Gate 1: build
Mac Studio, Xcode 27.2 (27B52): **TEST BUILD SUCCEEDED** (cold, DerivedData
`wisp-follows-test`). No warning in `FollowsSinceTests.swift`.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-follows-test \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath gft.xcresult
sh ci_scripts/gate.sh --parse gft.xcresult
```
```
gate: 1843 passed / 3 failed / 23 skipped / 1869 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1869 tests ran
```
First full run at 3828145. No local patch. No `project.pbxproj` diff.

## Not gated
- No device pass needed: test only.
