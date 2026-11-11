# GATE — fresh/pure-logic (PR #201: Fresh pure logic)

main merged in at b680867 (#183, after #200) as a8581ec. **Code frozen at
1fa91e4.** This file is the only commit after it, and it is the HEAD
commit. A review fix breaks the freeze: push a fresh gate file last.
Replaces the gate for 8b543ad (on b1140bc).

Fresh feed PR 3. Pure Swift ports of web `src/lib/freshFeed` (posts /
spacing / lastVisit / finishLine / topicList) with their test cases. No
view model, no UI, no network; no test opens a socket or touches a relay.

## What changed
- 8b543ad: new under `wisp/`: `FreshPosts.swift`, `FreshSpacing.swift`,
  `FreshLastVisit.swift`, `FreshFinishLine.swift`, `FreshTopicCatalog.swift`;
  new under `wispTests/`: the five matching suites (47 tests).
- a8581ec: main merged in (no conflicts; every file here is new).
- 1fa91e4, review fixes (Copilot review on this PR):
  - `FreshLastVisit.recordNewest` reads, compares and writes under the
    lock; concurrent records could store an older mark.
  - A stored mark, `published_at` or `count_14d` too large for `Int`
    (`"1e100"`) reads as no value / 0 instead of trapping in `Int(_:)`
    (`Int(exactly:)`).
  - `FreshDivider.withDivider` places no divider when the new count is 0
    (special cards above the first seen post produced `newCount: 0`).
    **≠ web**: web has the same bug.
  - 5 regression tests. **Red check:** with only the lock removed,
    `concurrentRecords_leaveTheNewestStored` fails (stored mark ≠ "200");
    it passes with the lock.
- No existing file is modified. No `project.pbxproj` diff
  (`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty).

## Which tree was gated
The runs below were made at 6313b1f, the same two code commits rebased
onto b680867 (that rebase could not be force-pushed, so main was merged
instead). `git diff 6313b1f 1fa91e4` is empty apart from this file: the
gated tree and the pushed tree are byte-identical.

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52):
```
xcodebuild build-for-testing -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -skipPackagePluginValidation \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-logic
```
**TEST BUILD SUCCEEDED.** Zero warnings in any of the ten files (every
touched file is new, so any warning there would be new).

## Gate 2: hermetic at the known set, serial
iPhone 18 Pro on iOS 27.2 (`90B23E20-BA47-4AD0-98EF-175513626A4B`):
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-logic \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath logic-gate2.xcresult
sh ci_scripts/gate.sh --parse logic-gate2.xcresult
```
```
gate: 1716 passed / 3 failed / 22 skipped / 1741 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1741 tests ran
```
The five Fresh suites passed (52 tests: FinishLine 2, LastVisit 12,
Posts 15, Spacing 12, TopicCatalog 11). **No local patch.**

## Not gated
- Nothing is wired into the app. The filters, spacer, divider and finish
  line get exercised in a running feed only in the view-model PR.
- The topic catalog was tested against a hand-written document in the
  measured NIP-11 shape (build spec §2), not a live fetch.
- The race test is probabilistic by nature (200 concurrent records with a
  pause between read and write); it failed on the one red run.
