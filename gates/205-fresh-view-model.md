# GATE — fresh/view-model (PR #205: FreshFeedViewModel, FeedKind.fresh, picker entry, behind freshFeedEnabled = false)

Branched from main at 16b98f9 (#202). **Code frozen at 04644c7.** This file
is the only commit after it, and it is the HEAD commit. A review fix breaks
the freeze: push a fresh gate file last.

Fresh feed PR 5. Ships off (`FeatureFlags.freshFeedEnabled = false`): no
picker entry, and a stored `FRESH` landing falls back to the default. No
test opens a socket or touches a relay; nothing publishes or sends AUTH.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), iPhone 18 Pro on iOS 27.2
(`90B23E20-BA47-4AD0-98EF-175513626A4B`). Both builds cold (fresh
DerivedData), so every file compiled and every warning printed:
- main 16b98f9 → `wisp-main-cold`: **TEST BUILD SUCCEEDED**, 163 unique
  warning sites.
- branch 04644c7 → `wisp-fresh-vm-cold`: **TEST BUILD SUCCEEDED**, 163.

Per touched file (main / branch): `FeedViewModel.swift` 5 / 5 (main's),
`MainView.swift`, `FeedKindStore.swift`, `FeedTabRouting.swift`,
`FeatureFlags.swift`, `NostrKey.swift`, `AppDataWipe.swift`,
`KeptMountedFeedBodiesTests.swift` 0 / 0; new `FreshFeedViewModel.swift`
and `FreshFeedViewModelTests.swift` 0.

## Gate 2: hermetic at the known set, serial
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-vm \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath vm-gate3.xcresult
sh ci_scripts/gate.sh --parse vm-gate3.xcresult
```
```
gate: 1769 passed / 3 failed / 23 skipped / 1795 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1795 tests ran
```
`FreshFeedViewModelTests` 16/16; `KeptMountedFeedBodiesTests`,
`FeedStickToTopTests`, `FeedTabRoutingTests` green. The 23rd skip is
#202's opt-in live smoke test. **No local patch.** No `project.pbxproj`
diff (`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty).

**Two earlier full runs at the same commit failed, and are reported here.**
vm-gate (run while a cold main build was compiling) and vm-gate2 (nothing
else running) each gave 1752 / 20 / 23 / 1795: the known three plus the
same 17 hosted-window / `ImageRenderer` tests that failed in #202's first
run, with the same messages ("drew nothing", "did not lay out", blank
renders): AttachmentStrip, ColorHierarchyRender, ComposeToolbar,
EntryPresentation, FeedStickToTop, KeptMountedFeedBodies, Lazarus renders.
Why they are not this branch:
- the first failure, `AttachmentStripRenderTests`, is the fourth suite in
  the run, thousands of lines before `FreshFeedViewModelTests` starts; the
  three suites before it touch nothing here;
- five of those suites (Lazarus renders, KeptMountedFeedBodies,
  ComposeToolbar, EntryPresentation, FeedStickToTop: 46 tests) pass on
  main's cold build run on their own, and passed on this branch in a
  targeted run;
- the run above is the identical bundle re-run (nothing rebuilt), from a
  freshly booted simulator.

The flake is the Studio's, not a branch's. It has now hit 3 of the last 4
full runs (#202's first run and these two), up from 1 in 4 in November.
Its trigger is not known.

## Not gated
- No device pass. The `MainView` wiring (picker entry, `freshBody`,
  scene-phase and kind-change hooks) is build-checked only; with the flag
  off it is unreachable.
- No live relay run in this PR; #202's smoke run covers the client.
- `PostCardView`'s Report / Block actions are not driven; the tests post
  the `.contentHidden` payloads those actions produce
  (`ContentHide.broadcast` from `ReportedContent.hide` and
  `MuteRepository.blockUser`).
- No screenshots: with the flag off nothing on screen changes.
