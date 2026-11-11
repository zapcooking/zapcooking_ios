# GATE — fix/unsupported-video-format-card (PR #195: explicit card for videos iOS can't decode)

main 4631b6a (#212, #213) merged in as 5f8b885. **Code frozen at 5f8b885.** This
file is the only commit after it, and it is the HEAD commit. A review fix
breaks the freeze: push a fresh gate file last. This file replaces the gate
at a6d4444 (code 4f3e66e on main 66bd7a2). That gate failed only on main's
`FollowsSinceTests` test, which #212 has since fixed.

## What is on the branch
dmnyc's two commits (51fb52a code + tests, b33e085 screenshot) plus the merge of main
(4f3e66e). Nothing else: this gate re-runs #195 on current main, as asked.

## Gate 1: build green, no new warnings in touched files
Rebuilt incrementally at 5f8b885 after the main merge, which touched no branch file (only `wispTests/FollowsSinceTests.swift` and `gates/`). The warning scan below is from the build of the branch code, which is unchanged since.

Mac Studio, Xcode 27.2 (27B52), cold build in `wisp-pr195`: **TEST BUILD
SUCCEEDED**. No warnings in `InlineVideoView.swift` or
`wispTests/UnplayableVideoNoteTests.swift`.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-pr195 \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath rg195.xcresult
sh ci_scripts/gate.sh --parse rg195.xcresult
```
```
gate: 1844 passed / 3 failed / 23 skipped / 1870 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1870 tests ran
```
`UnplayableVideoNoteTests` passed.

First full run at 5f8b885. No local patch. No `project.pbxproj` diff
(`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty). No test
opens a socket, publishes an event or sends AUTH.

## Not gated
- No device pass. The card's behaviour on a real undecodable video is
  covered only by the unit tests and dmnyc's screenshot
  (`docs/unsupported-video-card/`). The screenshot is not in
  `docs/screenshots/<area>/` as AGENTS.md asks.
