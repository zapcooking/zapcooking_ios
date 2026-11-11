# GATE — fresh/specials-loader (PR #216: Fresh specials S2)

Branched from main at 45842df. Code commits fd98482 (loader and topic
list), 21abb18 (kick race) and **aa0e52f (code frozen)**: the Copilot
review fixes. This file replaces gate edd182d and is the HEAD commit. A
review fix breaks the freeze: push a fresh gate file last.

aa0e52f fixes three loader bugs:
1. **A kick during a hold.** It no longer counts as a pending build, so a
   far slot can't wait out a 60–600 s hold.
2. **Only the last spotlight's parent group left.** Spotlights are now out
   for the session, where the loader used to retry an empty pick every
   15 s.
3. **Repeated `prepare()` / `kick()`.** They now honour the 15 s failure
   retry.

Three new tests, red on the previous loader (edd182d) and green here:
`kickDuringHoldIsNotAvailable`, `onlyLastParentLeftGoesOut` and
`repeatedPrepareHonorsTheRetry`.

21abb18 fixed a race found in S3's screenshot run. A slot decided in the
same main-actor turn as `kick()` saw nothing building.
`isAvailable(strict: true)` now also counts a kicked build that hasn't
started yet; aa0e52f limits that to a build that can start now.

Loader and topic-list fetch only. Nothing in the app calls them yet, and
`freshSpecialsEnabled` is `false`. No test opens a socket or makes a network
request, publishes an event or sends AUTH.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), DerivedData `wisp-specials` (incremental
from S1's tree; every touched file is new or recompiled): **TEST BUILD
SUCCEEDED** at aa0e52f. Zero warnings in `wisp/FreshTopicList.swift`,
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
  -collect-test-diagnostics never -resultBundlePath s2c-gate.xcresult
sh ci_scripts/gate.sh --parse s2c-gate.xcresult
```
```
gate: 1933 passed / 3 failed / 23 skipped / 1959 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1959 tests ran
```
First full run at aa0e52f. (Earlier: 1929/1955 at fd98482 and 1930/1956 at
21abb18.) New suites:
- `FreshSpotlightLoaderTests` (23)
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
