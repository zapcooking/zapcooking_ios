# GATE — fresh/view-model (PR #205: FreshFeedViewModel, FeedKind.fresh, picker entry, behind freshFeedEnabled = false)

Branched from main at 16b98f9 (#202); main merged in at e17755f (#191,
#197) as e41f634. **Code frozen at 28d00c8** (Copilot review fixes on top
of 04644c7). This file is the only commit after it, and it is the HEAD
commit. A review fix breaks the freeze: push a fresh gate file last.

Fresh feed PR 5. Ships off (`FeatureFlags.freshFeedEnabled = false`): no
picker entry, and a stored `FRESH` landing falls back to the default. No
test opens a socket or touches a relay (profiles go through a no-op
`FreshProfileSource` in the tests); nothing publishes or sends AUTH.

## Review fixes (28d00c8)
All 13 Copilot comments, each with a regression test (12 new tests,
`FreshFeedViewModelTests` 28): private replies excluded; an epoch
invalidates page / recipe / first-load work on deactivation, and new
connections wait for the pending close; no tail on foreground while page 1
or a refresh is pending; refresh stops the tail before resetting seen and
restarts it with the overlap; empty full pages hop (max 5, cursor must
move); tail anchor and visit mark clamped to now + 30 s; tail edits
persisted; own long-form one row per coordinate; visit mark from merged
rows; empty window shows the finish line; foreground forwarded whatever
the kind; own posts reloaded on refresh; injectable profile source. Also
found while writing the tests: refresh did not reset the finish line.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), iPhone 18 Pro on iOS 27.2
(`90B23E20-BA47-4AD0-98EF-175513626A4B`). Measured at 04644c7; both builds cold (fresh
DerivedData), so every file compiled and every warning printed:
- main 16b98f9 → `wisp-main-cold`: **TEST BUILD SUCCEEDED**, 163 unique
  warning sites.
- branch 04644c7 → `wisp-fresh-vm-cold`: **TEST BUILD SUCCEEDED**, 163.

Per touched file (main / branch): `FeedViewModel.swift` 5 / 5 (main's),
`MainView.swift`, `FeedKindStore.swift`, `FeedTabRouting.swift`,
`FeatureFlags.swift`, `NostrKey.swift`, `AppDataWipe.swift`,
`KeptMountedFeedBodiesTests.swift` 0 / 0; new `FreshFeedViewModel.swift`
and `FreshFeedViewModelTests.swift` 0.
At 28d00c8 (incremental; the four changed files recompiled):
`FreshFeedViewModel.swift`, `FreshFeedViewModelTests.swift`,
`FeedTabRouting.swift`, `MainView.swift` 0 warnings.

## Gate 2: hermetic at the known set, serial
At 28d00c8:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-vm \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath vm-gate4.xcresult
sh ci_scripts/gate.sh --parse vm-gate4.xcresult
```
```
gate: 1787 passed / 3 failed / 23 skipped / 1813 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1813 tests ran
```
First full run at this commit; no re-run. `FreshFeedViewModelTests` 28/28
(also 3 targeted runs in a row, 28/28 each, since several tests are about
ordering); `KeptMountedFeedBodiesTests`, `FeedStickToTopTests`,
`FeedTabRoutingTests` green. The 23rd skip is #202's opt-in live smoke
test. **No local patch.** No `project.pbxproj` diff.

One targeted run before this failed to start: the simulator's SpringBoard
crashed launching the test host ("Failed to install or launch the test
runner"); no test ran, and the next run started normally.

**History at 04644c7 (before the review):** PASS 1769 / 3 / 23 / 1795 on
the third full run; the first two hit the Studio render flake (the same 17
hosted-window / `ImageRenderer` tests as #202's first run, starting at the
fourth suite, before anything Fresh runs).

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
