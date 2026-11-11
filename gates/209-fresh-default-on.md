# GATE — fresh/default-on (PR #209: Fresh on, the default for new sign-ins only)

Branched from main at 8f0c2d8 (#205); main merged in at 858233d (#206,
#208) as the merge commit before 9e369f3. **Code frozen at 9e369f3.** This
file is the only commit after it, and it is the HEAD commit. A review fix
breaks the freeze: push a fresh gate file last. Replaces the gate for
a4d59f0.

Fresh feed PR 7. `FeatureFlags.freshFeedEnabled = true`; the
`FeedDefaultMigration` one-time write keeps existing accounts on their feed.
No hermetic test opens a socket or publishes anything.

## What changed since the first gate (9e369f3)
- main merged in: #206 (Fresh UI) and #208 (simulator pre-boot).
- Recipe row: recipes already shown in the feed are left out, by id and by
  coordinate (`recipePool` up to 60, `recipePicks` the row).
- iPad: the Fresh list is capped at 680 pt, centred (`FreshFeedLayout`).
- Screenshots: invented content (`FreshScreenshotFixtures` via an in-app
  `FreshFixtureTransport`, DEBUG `-FreshScreenshotFixtures`); the live-relay
  shots are replaced; the DEBUG window override in `FreshRelayClient` is
  removed (`git diff origin/main -- wisp/FreshRelayClient.swift` is empty).
- Tests: `recipeRowExcludesFeedRecipes`; `FreshScreenshotFixturesTests` (3).

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), at 9e369f3: **TEST BUILD SUCCEEDED**
(incremental in `wisp-fresh-default`; every touched file recompiled; the
first build of this branch was cold). The only warning in any touched file
is `ContentView.swift:104`, which is on main too.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-default \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath b2-gate.xcresult
sh ci_scripts/gate.sh --parse b2-gate.xcresult
```
```
gate: 1816 passed / 3 failed / 23 skipped / 1842 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1842 tests ran
```
First full run at this commit. **No local patch.** No `project.pbxproj`
diff. The gate simulator was never given an account.

## Gate 3: screenshots (not part of the hermetic gate)
`FreshScreenshotsUITests.testFreshScreens` at 9e369f3's code, on
`fresh-shots-iphone` (iPhone 18 Pro) and `fresh-shots-ipad` (iPad Pro 13"
M5), both iOS 27.2, erased before the run: iPhone passed in 81 s, iPad
(portrait, then landscape) in 145 s. Invented content only; nothing on the
network or in the event store. The 12 attachments were exported, EXIF
orientation applied and stripped (XCUITest tags landscape captures with
orientation 8), scaled to 1400 px and saved as JPEG in
`docs/screenshots/fresh/` (1.2 MB). Two earlier attempts failed in the
harness, not the app (zsh argument splitting; the caught-up card is one
combined accessibility element, now found by identifier, and the end of
the list can't scroll it higher).

## Not gated
- No device pass.
- The migration's pre-unlock path is covered by `FeedKindStoreTests` with
  an injected value, not by a real pre-unlock launch.
- The first live-relay screenshots stay in this branch's history (a4d59f0);
  a squash merge leaves them out of main.

## Device pass (Seth, 2026-11-11, iPhone): passed
Recorded after merge (08d2845). On iPhone:
- An existing account kept its feed after the update (the one-time
  `FeedDefaultMigration` write held).
- A new account landed on Fresh.
- Paging, the finish line, the new-posts pill, Report, Block, own post,
  own reply, delete, offline refresh and feed switching passed.

The "No device pass" line under Not gated is superseded by this section.
The device pass was iPhone only; iPad was covered by the screenshots
(Gate 3), not by hand.
