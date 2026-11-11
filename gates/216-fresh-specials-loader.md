# GATE — fresh/specials-loader (PR #216: Fresh specials S2)

Branched from main at 45842df. Code commits fd98482 (loader and topic list)
and **21abb18 (code frozen)**. This file replaces gate 73f5bb4 and is the
HEAD commit. A review fix breaks the freeze: push a fresh gate file last.

21abb18 fixes a race found in S3's screenshot run. `kick()` starts a build
in a Task, and a slot decided in the same main-actor turn saw no spotlight
ready and none building, so the turn went to a recipe.
`isAvailable(strict: true)` now also counts a kicked build that hasn't
started. New test: `kickedBuildCountsAsBuilding`.

Loader and topic-list fetch only. Nothing in the app calls them yet, and
`freshSpecialsEnabled` is `false`. No test opens a socket or makes a network
request, publishes an event or sends AUTH.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), DerivedData `wisp-specials` (incremental
from S1's tree; every touched file is new or recompiled): **TEST BUILD
SUCCEEDED** at 21abb18. Zero warnings in `wisp/FreshTopicList.swift`,
`wisp/FreshSpotlightLoader.swift`, `wisp/FreshTopicCatalog.swift`,
`FeatureFlags.swift`, `wispTests/FreshTopicListTests.swift` and
`wispTests/FreshSpotlightLoaderTests.swift`.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-specials \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath s2b-gate.xcresult
sh ci_scripts/gate.sh --parse s2b-gate.xcresult
```
```
gate: 1930 passed / 3 failed / 23 skipped / 1956 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1956 tests ran
```
First full run at 21abb18. (At fd98482: PASS 1929/3/23/1955.) New suites:
- `FreshSpotlightLoaderTests` (20)
- `FreshSpotlightLoaderRelayTests` (1): the AUTH-frame check on the real client.
- `FreshTopicListTests` (10)

No local patch. No `project.pbxproj` diff.

## Mutation check
With cookies turned on in `FreshTopicList` (`.always`, `httpShouldSetCookies`,
`.shared` storage, `httpShouldHandleCookies = true`), `requestShape` and
`sessionShape` fail. `wireRequest` still passes, because a URLProtocol stub
never sees cookie headers. Its doc comment says so. Reverted before fd98482.

## Not gated
- No UI and no device pass: nothing is wired in yet (S3).
- No live NIP-11 request: the topic list was tested with a scripted fetch
  and a stub only.
