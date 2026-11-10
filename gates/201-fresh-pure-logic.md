# GATE — fresh/pure-logic (PR #201: Fresh pure logic)

Branched from main at b1140bc (#199). **Code frozen at 8b543ad.** This
file is the only commit after it, and it is the HEAD commit. A review fix
breaks the freeze: push a fresh gate file last.

Fresh feed PR 3. Pure Swift ports of web `src/lib/freshFeed` (posts /
spacing / lastVisit / finishLine / topicList) with their test cases. No
view model, no UI, no network; no test opens a socket or touches a relay.

## What changed
- New, under `wisp/`: `FreshPosts.swift`, `FreshSpacing.swift`,
  `FreshLastVisit.swift`, `FreshFinishLine.swift`, `FreshTopicCatalog.swift`.
- New, under `wispTests/`: `FreshPostsTests`, `FreshSpacingTests`,
  `FreshLastVisitTests`, `FreshFinishLineTests`, `FreshTopicCatalogTests`
  (47 tests).
- No existing file is modified. No `project.pbxproj` diff
  (`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty).

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), at 8b543ad:
```
xcodebuild build-for-testing -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -skipPackagePluginValidation \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-logic
```
**TEST BUILD SUCCEEDED.** Zero warnings in any of the ten new files (every
touched file is new, so any warning there would be new). The rest of the
build's warnings are main's.

## Gate 2: hermetic at the known set, serial
iPhone 18 Pro on iOS 27.2 (`90B23E20-BA47-4AD0-98EF-175513626A4B`):
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-logic \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath logic-gate.xcresult
sh ci_scripts/gate.sh --parse logic-gate.xcresult
```
```
gate: 1707 passed / 3 failed / 22 skipped / 1732 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1732 tests ran
```
The five new suites passed (47 tests). **No local patch:** this run is
the branch as pushed.

## Not gated
- Nothing is wired into the app. The filters, spacer, divider and finish
  line get exercised in a running feed only in the view-model PR.
- The topic catalog was tested against a hand-written document in the
  measured NIP-11 shape (build spec §2), not a live fetch.
