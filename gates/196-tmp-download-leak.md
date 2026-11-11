# GATE — fix/tmp-download-leak (PR #196: CFNetworkDownload tmp leak)

main 4631b6a (#212, #213) merged in as f1b87fd. **Code frozen at f1b87fd.** This
file is the only commit after it, and it is the HEAD commit. A review fix
breaks the freeze: push a fresh gate file last. This file replaces the gate
at 8885171 (code 30799b1 on main 66bd7a2). That gate failed only on main's
`FollowsSinceTests` test, which #212 has since fixed.

## What is on the branch
dmnyc's ed8aa98 (TmpJanitor, SplashView tiles off AsyncImage), the merge of main
(6425cda), and 30799b1. 30799b1 moves the launch sweep off the main thread:
`TmpJanitor.sweepStaleDownloadFiles()` is synchronous and was called from
MainView's `.task`, which runs on the main actor, so the whole walk ran on
the main thread. MainView now awaits `TmpJanitor.sweepAtLaunch()`, which runs
the sweep in `Task.detached(priority: .utility)`. The sweep returns
`Outcome(removed:ranOnMainThread:)`, and `removed` now counts only
successful deletes.

## Gate 1: build green, no new warnings in touched files
Rebuilt incrementally at f1b87fd after the main merge, which touched no branch file (only `wispTests/FollowsSinceTests.swift` and `gates/`). The warning scan below is from the build of the branch code, which is unchanged since.

Mac Studio, Xcode 27.2 (27B52), cold build in `wisp-pr196`: **TEST BUILD
SUCCEEDED**. Zero warnings in `MainView.swift`, `wisp/SplashView.swift`,
`wisp/TmpJanitor.swift` and `wispTests/TmpJanitorTests.swift`.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-pr196 \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath rg196.xcresult
sh ci_scripts/gate.sh --parse rg196.xcresult
```
```
gate: 1849 passed / 3 failed / 23 skipped / 1875 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1875 tests ran
```
Which thread it runs on, from the run above: `TmpJanitorTests` 6/6.
- `directSweep_fromTheMainActor_runsOnTheMainThread` (control). Called
  directly from the main actor, as before, the sweep reports
  `Thread.isMainThread == true`. This proves the probe can read true.
- `launchSweep_fromTheMainActor_runsOffTheMainThread`. Awaited from the main
  actor, as MainView does, the sweep reports `false` and the stale file is
  gone.
- `mainView_launchesTheSweepOffTheMainThread`. A source tripwire: MainView
  calls `await TmpJanitor.sweepAtLaunch()` and never calls the synchronous
  sweep.
- The three original sweep tests also pass.

First full run at f1b87fd. No local patch. No `project.pbxproj` diff
(`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty). No test
opens a socket, publishes an event or sends AUTH.

## Not gated
- No device pass. The launch with a real 40k-file backlog is not timed.
- `prepareNotifications()` still waits for the sweep, as it did before.
  Only the thread changed.
