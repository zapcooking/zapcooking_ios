# GATE — fresh/ui (PR #206: Fresh UI and fixes, flag off)

Branched from main at 8f0c2d8 (#205). **Code frozen at 6f97ee8.** This file
is the only commit after it, and it is the HEAD commit. A review fix breaks
the freeze: push a fresh gate file last.

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

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), at 6f97ee8: **TEST BUILD SUCCEEDED**
(incremental in `wisp-fresh-vm`; every touched file recompiled). Warnings
in `FreshFeedViewModel.swift`, `FreshFeedComponents.swift`,
`MainView.swift`, `DeletionSender.swift`, `FreshFeedViewModelTests.swift`,
`FreshCopyTests.swift`: 0, as on main's cold build (16b98f9: 0 in each).

## Gate 2: hermetic at the known set, serial
iPhone 18 Pro on iOS 27.2 (`90B23E20-BA47-4AD0-98EF-175513626A4B`):
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-vm \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath ui-gate.xcresult
sh ci_scripts/gate.sh --parse ui-gate.xcresult
```
```
gate: 1797 passed / 3 failed / 23 skipped / 1823 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1823 tests ran
```
First full run at this commit. The Fresh suites also passed three targeted
runs in a row (38/38 each). The 23rd skip is #202's opt-in live smoke test.
**No local patch.** A render-flake investigation was running experiments
on a separate simulator clone during this run.

## Not gated
- No device pass; the flag is off, so the UI is reachable only in tests.
- No screenshots in this PR (nothing in the app changes with the flag off);
  PR B ships them with the flag on.
- The pill's scroll-to-top and the recipe row's posters are view code
  exercised by the build only.
