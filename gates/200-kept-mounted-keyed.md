# GATE — refactor/kept-mounted-keyed (PR #200: KeptMountedFeedBodies keyed by FeedTabRouting.Body)

Branched from main at b1140bc (#199). **Code frozen at 7525e88.** This file
is the only commit after it, and it is the HEAD commit. A review fix breaks
the freeze: push a fresh gate file last.

Fresh feed foundation (Task 4). This is a pure refactor and adds no network
calls.

## The change
- `wisp/KeptMountedFeedBodies.swift`: one container keyed by
  `FeedTabRouting.Body`, with a `mounted: Set<Body>`, replacing three
  generic bodies and three mounted flags. Bodies are a
  `ForEach(Body.allCases, id: \.self)` in the old stacking order. The
  two-body `init(showOnlyFood:…)` is kept through `KeptMountedPair`.
- `wisp/FeedTabRouting.swift`: `Body` is now `Hashable, CaseIterable`.
- `MainView.swift` (`feedContent`): the three trailing closures become one
  `switch key`, with the same expressions per branch.
- `wispTests/KeptMountedFeedBodiesTests.swift` (new, 3 tests).

`wispTests/FeedStickToTopTests.swift` and `wispTests/FeedTabRoutingTests.swift`
are unmodified (`git diff origin/main...HEAD` on them is empty). No
`project.pbxproj` diff (`git diff origin/main...HEAD --stat -- wisp.xcodeproj`
is empty).

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), `build-for-testing` at 7525e88: **TEST BUILD
SUCCEEDED**. `MainView.swift`, `wisp/FeedTabRouting.swift`,
`wisp/KeptMountedFeedBodies.swift` and the new test file have zero warnings
on the branch, and the first three have zero on main at b1140bc as well.
Comparing the normalized `file: message` sets with main's build log, the
branch has one extra line, `ShareExtension/ShareViewController.swift:
consider using asynchronous alternative function`. That is a file the branch
does not touch; the most likely cause is a difference between the two logs'
build actions (`build-for-testing` here). It is not this change.

## Gate 2: hermetic at the known set, serial
iPhone 18 Pro on iOS 27.2 (`90B23E20-BA47-4AD0-98EF-175513626A4B`), at 7525e88:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-kept-mounted \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath km-gate.xcresult
sh ci_scripts/gate.sh --parse km-gate.xcresult
```
```
gate: 1663 passed / 3 failed / 22 skipped / 1688 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3)
```
`FeedStickToTopTests`, `FeedTabRoutingTests` and `KeptMountedFeedBodiesTests`
all passed; they also passed in a separate targeted run (21/21).

**No local patch.** This run is the branch as pushed.

## Not gated
- No device pass. Switching between the real OnlyFood, Follows and Live Video
  bodies with live data is covered only by the hosted harness, which uses
  stand-in lists.
- No screenshots: nothing on screen changes.
