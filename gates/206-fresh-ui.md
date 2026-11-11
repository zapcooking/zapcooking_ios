# GATE — fresh/ui (PR #206: Fresh UI and fixes, flag off)

Branched from main at 8f0c2d8 (#205); main merged in at f603be0 (#208) as
7993a34. **Code frozen at 8853648** (Copilot review fixes on top of
6f97ee8). This file is the only commit after it, and it is the HEAD
commit. A review fix breaks the freeze: push a fresh gate file last.

Fresh feed PR 6. `FeatureFlags.freshFeedEnabled` stays `false`. No test
opens a socket or touches a relay; profiles go through the no-op
`FreshProfileSource`; nothing publishes or sends AUTH.

## What changed
- `wisp/FreshFeedViewModel.swift`: new-posts pill state (`pendingNew`,
  `newPostsCount`, `showsNewPostsPill`, `showNewPosts`,
  `dismissNewPostsPill`); a failed / timed-out / refused refresh keeps the
  list; own posts top-level only (`isTopLevel`, NIP-10); deletions through
  `DeletionTracker` (strict) at ingest and on `.eventDeletionRecorded`;
  posts dated more than 30 s ahead dropped; `reachEnd()` rebuilds the list.
- `wisp/FreshFeedComponents.swift` (new): `FreshNewSinceDivider`,
  `FreshCaughtUpCard`, `FreshRecipeRow`.
- `MainView.swift` (Fresh section only): pill overlay, `PendingPostRow`,
  the new components.
- `DeletionSender.swift`: posts `.eventDeletionRecorded` after a
  successful publish + record.
- Tests: `FreshFeedViewModelTests` 35 (7 new, 6 existing tail tests now tap
  the pill, 1 rewritten); `FreshCopyTests` 3 (new).

No `project.pbxproj` diff (`git diff origin/main...HEAD --stat --
wisp.xcodeproj` is empty).

## Review fixes (8853648)
All 6 Copilot comments, each with a regression test (6 new,
`FreshFeedViewModelTests` 41): the optimistic row only for kinds Fresh
keeps (`showsPendingRow`); a failed page 1 with posts behind the pill shows
the list (`showsFailureMessage` / `showsEmptyMessage` check the pill);
`pillDismissedAt` is observed (checked with `withObservationTracking`); a
failed refresh puts the posts that did arrive behind the pill (the client
had marked them seen); a failed refresh keeping the finish line restarts an
unfinished recipe load; the recipe row drops deleted and far-future
recipes.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), at 8853648: **TEST BUILD SUCCEEDED**
(incremental in `wisp-fresh-vm`; every touched file recompiled). Warnings
in `FreshFeedViewModel.swift`, `FreshFeedComponents.swift`,
`MainView.swift`, `DeletionSender.swift`, `FreshFeedViewModelTests.swift`,
`FreshCopyTests.swift`: 0, as on main's cold build (16b98f9: 0 in each).

## Gate 2: hermetic at the known set, serial
At 8853648, after `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`
(#208: SpringBoard stable for 15 s before the run):
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-vm \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath ui-gate2.xcresult
sh ci_scripts/gate.sh --parse ui-gate2.xcresult
```
```
gate: 1804 passed / 3 failed / 23 skipped / 1830 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1830 tests ran
```
First full run at this commit; `HostSceneProbeTests` (#208) passed. The
Fresh suites also passed four targeted runs (44/44 each). **No local
patch.** Before the review: PASS 1797 / 3 / 23 / 1823 at 6f97ee8.

## Not gated
- No device pass; the flag is off, so the UI is reachable only in tests.
- No screenshots in this PR (nothing in the app changes with the flag off);
  PR B ships them with the flag on.
- The pill's scroll-to-top and the recipe row's posters are view code
  exercised by the build only.
