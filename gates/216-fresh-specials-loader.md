# GATE — fresh/specials-loader (PR #216: Fresh specials S2)

Branched from main at 45842df. One code commit, **fd98482 (code frozen)**.
This file is the only commit after it, and it is the HEAD commit. A review
fix breaks the freeze: push a fresh gate file last.

Loader and topic-list fetch only. Nothing in the app calls them yet, and
`freshSpecialsEnabled` is `false`. No test opens a socket or makes a network
request, publishes an event or sends AUTH.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), DerivedData `wisp-specials` (incremental
from S1's tree; every touched file is new or recompiled): **TEST BUILD
SUCCEEDED**. Zero warnings in `wisp/FreshTopicList.swift`,
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
  -collect-test-diagnostics never -resultBundlePath s2-gate.xcresult
sh ci_scripts/gate.sh --parse s2-gate.xcresult
```
```
gate: 1929 passed / 3 failed / 23 skipped / 1955 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1955 tests ran
```
First full run at fd98482. New suites:
- `FreshSpotlightLoaderTests` (19)
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
