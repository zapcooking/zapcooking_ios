# GATE — unified-feed/3-drop-following-mode
Unified feed, PR 3 of 7 (§9): delete OnlyFood's Following mode. Deletion-only;
Following went unreachable in PR 2. Own branch off main at 0759aa6 (the PR 2
merge). Local build only on Seth's MacBook Air; gates run on the MacinCloud
box by hand. This GATE.md replaces PR 2's.

**Frozen at this commit.** App code is frozen at **98953b7** (4de3981 plus the
Copilot review fix: `ModeState` renamed `OnlyFoodCacheState`, four references
in one file). This GATE.md is the only commit after it and is the HEAD commit —
`gate.sh` refuses to run otherwise. The previous GATE.md (5177ded) is
superseded; a further review fix re-opens the freeze again: push a fresh
GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at 98953b7.
- Warnings in touched files: **zero** — `OnlyFoodFeedViewModel.swift`,
  `MainView.swift`, `wispTests/OnlyFoodFeedViewModelTests.swift`,
  `wispTests/OnlyFoodOwnPublishTests.swift`, `wispTests/FeedTabRoutingTests.swift`
  produce no warning lines.
- Targeted serial run, 2026-09-09, `test-without-building`
  `-only-testing:wispTests/OnlyFoodFeedViewModelTests -only-testing:wispTests/OnlyFoodOwnPublishTests -only-testing:wispTests/FeedTabRoutingTests -only-testing:wispTests/FeedKindStoreTests`:
  **39 tests in 4 suites passed** (13 + 8 + 7 + 11), re-run at the re-freeze.
- pbxproj: no diff (three-dot). No files added or removed.
- `OnlyFoodFeedViewModel.swift`: **780 → 614 lines**.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout unified-feed/3-drop-following-mode && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh unified-feed/3-drop-following-mode
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on unified-feed/3-drop-following-mode @ <this commit>`, with the
four known failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`
plus the three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **771** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 775. Net **-4**:
`OnlyFoodFeedViewModelTests` 15 → 13 (three empty-follows tests removed, the
toggle test rewritten as `repeatedStart_…`, one derived-states gate added);
`OnlyFoodOwnPublishTests` 10 → 8 (two Following tests removed). If the parsed
total is 775 the run was on a stale tree — the script's branch assertion is
a hard stop.

## Gate 2 — unit coverage (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'OnlyFoodFeedViewModelTests|OnlyFoodOwnPublishTests|FeedTabRoutingTests'
```
Required cases, each present and passing:
- §7.4 in single-mode form (initial load queries once, a second `start()`
  does not re-query, refresh does): `OnlyFoodFeedViewModelTests/start_isOneShot`,
  `repeatedStart_afterLoad_keepsCacheAndIssuesNoREQ`,
  `zeroEvents_stillLatches_soSecondStartDoesNotRequery`,
  `refresh_isTheOnlyRequeryPath`, `cacheSeed_paintsBeforeQuery_andDoesNotLatch`;
  and across the feed-kind switch,
  `FeedTabRoutingTests/kindSwitch_awayFromOnlyFoodAndBack_issuesNoNewREQ_pullToRefreshDoes`
- derived states unchanged for every reachable input:
  `derivedStates_truthTable_unchangedWithoutEmptyFollows`, plus
  `timeout_doesNotLatch`, `connectMiss_isLoadFailedNotEmpty`,
  `refreshAfterTimeout_clearsLoadFailedOnSuccess`,
  `timeout_withSeededNotes_doesNotFlagLoadFailed`
- optimistic self-insert unchanged: every `OnlyFoodOwnPublishTests` case
  (`ownFoodNote_landsAtTop_withNoQuery`, `duplicateInsert_isIdempotent`,
  `insertDuringInitialLoad_survivesSettle_onTop`, `publishedNotification_reachesTheFeed`, …)
- no remaining reference to `Mode`, `setMode`, `emptyFollows` or
  `observeFollowsChanges` in the target: enforced by the compiler (the
  symbols no longer exist); `git grep -n 'setMode\|emptyFollows\|observeFollowsChanges' -- '*.swift' ':!wispTests'`
  returns only `SearchViewModel` / `TrendingFeedViewModel`'s unrelated `setMode`.

## Gate 3 — pbxproj (three-dot)
```sh
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Expected: empty.

No live gate: no relay path, filter or kind changed.

## Results
Gates 1–3 pending — recorded in the PR description after Seth's run.
