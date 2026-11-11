# GATE — fix/unsupported-video-format-card (PR #195: explicit card for videos iOS can't decode)

main 66bd7a2 (#194, #209) merged in. **Code frozen at 4f3e66e.** This file is
the only commit after it, and it is the HEAD commit. A review fix breaks the
freeze: push a fresh gate file last.

## What is on the branch
dmnyc's two commits (51fb52a code + tests, b33e085 screenshot) plus the merge of main
(4f3e66e). Nothing else: this gate re-runs #195 on current main, as asked.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), cold build in `wisp-pr195`: **TEST BUILD
SUCCEEDED**. No warnings in `InlineVideoView.swift` or
`wispTests/UnplayableVideoNoteTests.swift`.

## Gate 2: hermetic, serial — FAIL by gate.sh, and the one extra failure is main's
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-pr195 \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath g195.xcresult
sh ci_scripts/gate.sh --parse g195.xcresult
```
```
gate: 1843 passed / 4 failed / 23 skipped / 1870 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   NEW     pickingFollowsAfterOnlyFood_asksForTheWholeDefaultWindow()  (Expectation failed: vm.currentKind == .onlyFood
vm.currentKind → .fresh)
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: FAIL — 1 failure(s) outside the known set (KNOWN_FAILURES in gate.sh): pickingFollowsAfterOnlyFood_asksForTheWholeDefaultWindow()
```
The extra failure is on main 66bd7a2, not this branch. #194 wrote the test
when new accounts landed on OnlyFood, and #209 made them land on Fresh. The
branch touches none of `FollowsSinceTests`, `FeedViewModel` and
`FeedKindStore`. #212 fixes the test, and its full run on main plus the fix
is PASS 1843/3/23/1869. Once #212 is on main, re-gate by merging main and
pushing a fresh gate file. Expected result: exactly the known set.

`UnplayableVideoNoteTests` passed.

First full run at 4f3e66e. No local patch. No `project.pbxproj` diff
(`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty). No test
opens a socket, publishes an event or sends AUTH.

## Not gated
- No device pass. The card's behaviour on a real undecodable video is
  covered only by the unit tests and dmnyc's screenshot
  (`docs/unsupported-video-card/`). The screenshot is not in
  `docs/screenshots/<area>/` as AGENTS.md asks.
