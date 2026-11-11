# GATE — fresh/default-on (PR #209: Fresh on, the default for new sign-ins only)

Branched from main at 8f0c2d8 (#205). **Code frozen at a4d59f0.** This file
is the only commit after it, and it is the HEAD commit. A review fix breaks
the freeze: push a fresh gate file last. Does not contain #206.

Fresh feed PR 7. `FeatureFlags.freshFeedEnabled = true`; the
`FeedDefaultMigration` one-time write keeps existing accounts on their feed.
No hermetic test opens a socket or publishes anything.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52). Cold build in `wisp-fresh-default`, then
incremental rebuilds after each change: **TEST BUILD SUCCEEDED**. Unique
warning sites in touched files equal main's cold build (16b98f9):
`ContentView.swift` 1 / 1 (main's, line 104); `FeedKindStore.swift`,
`NostrKey.swift`, `FeatureFlags.swift`, `MainView.swift`,
`FreshRelayClient.swift`, the four test files 0 / 0; new
`FeedDefaultMigration.swift`, `FreshScreenshotHarness.swift`,
`FreshScreenshotsUITests.swift` 0. (The first cold build had 2 in
`FeedDefaultMigration.swift`, a `nonisolated` enum calling MainActor
`FeedKindStore`; fixed before the freeze.)

## Gate 2: hermetic at the known set, serial
iPhone 18 Pro on iOS 27.2 (`90B23E20-BA47-4AD0-98EF-175513626A4B`):
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-default \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath def-gate.xcresult
sh ci_scripts/gate.sh --parse def-gate.xcresult
```
```
gate: 1795 passed / 3 failed / 23 skipped / 1821 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1821 tests ran
```
First full run at this commit. **No local patch.** No `project.pbxproj`
diff. The gate simulator was never given an account (the screenshot runs
used their own simulators).

## Gate 3: screenshots (not part of the hermetic gate)
`FreshScreenshotsUITests.testFreshScreens` at a4d59f0's code, on two new
simulators (`fresh-shots-iphone`: iPhone 18 Pro, `fresh-shots-ipad`:
iPad Pro 13" M5, both iOS 27.2, created for this, erased before use):
iPhone passed in 164 s, iPad (portrait then landscape) in 493 s. The live
feed relay was read with a watch-only account (no key, nothing signed);
the 12 attachments were exported, landscape ones rotated upright, scaled
to 1400 px and saved as JPEG in `docs/screenshots/fresh/`.

## Not gated
- No device pass. The migration's protected-data path (`isProtectedDataAvailable`
  false at launch) is covered by `FeedKindStoreTests` with an injected
  value, not by a real pre-unlock launch.
- The divider / finish-line screenshots show #205's styling; they need a
  re-shoot after #206 is merged and main is merged in here.
