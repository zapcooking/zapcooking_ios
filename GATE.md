# GATE — unified-feed/2-render-onlyfood-in-feed
Unified feed, PR 2 of 7 (§9): render the OnlyFood list inside the feed tab
and delete the separate tab (`BottomTab.onlyfood` → `.feed`, `.home` and
the drawer's Feeds row gone). Own branch off main at a2975fc (the PR 1
merge). Local build only on Seth's MacBook Air; gates run on the MacinCloud
box by hand. This GATE.md replaces PR 1's, which main still carried.

**Frozen at this commit.** App code is frozen at **76829cf**; this GATE.md is
the only commit after it and is the HEAD commit — `gate.sh` refuses to run
otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at 76829cf.
- Warnings in touched files: **zero** — `MainView.swift`,
  `SidebarDrawerView.swift`, `wisp/FeedTabRouting.swift`,
  `wispTests/FeedTabRoutingTests.swift` produce no warning lines (both edited
  views had zero in the PR 1 baseline build as well).
- Targeted serial run, 2026-09-09, `test-without-building`
  `-only-testing:wispTests/FeedTabRoutingTests -only-testing:wispTests/OnlyFoodFeedViewModelTests -only-testing:wispTests/FeedKindStoreTests`:
  **33 tests in 3 suites passed** (13 s; 7 new + 15 + 11 unchanged).
- pbxproj: no diff (three-dot). The deleted `wisp/OnlyFoodFeedView.swift` and
  the new `wisp/FeedTabRouting.swift` / `wispTests/FeedTabRoutingTests.swift`
  all live in synchronized groups, so the deletion did not dirty the project.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout unified-feed/2-render-onlyfood-in-feed && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh unified-feed/2-render-onlyfood-in-feed
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on unified-feed/2-render-onlyfood-in-feed @ <this commit>`, with the
four known failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`
plus the three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **775** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 768; the delta is
the **+7** new `FeedTabRoutingTests`. If the parsed total is 768 the run was
on a stale tree — the script's branch assertion is a hard stop.

## Gate 2 — unit coverage (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'FeedTabRoutingTests|OnlyFoodFeedViewModelTests'
```
Required cases, each present and passing (§10, PR 2 rows):
- no new REQ across the kind switch, pull-to-refresh does:
  `kindSwitch_awayFromOnlyFoodAndBack_issuesNoNewREQ_pullToRefreshDoes`,
  `otherKinds_neverStartOnlyFood_noPrewarm`; and the pre-existing §7.4 latch
  cases `OnlyFoodFeedViewModelTests/start_isOneShot`,
  `refresh_isTheOnlyRequeryPath`, `zeroEvents_stillLatches_soToggleDoesNotRequery`
- default landing renders the OnlyFood list:
  `coldStart_defaultLanding_rendersOnlyFoodBody_notPlaceholder`
- deep link from a food post into a recipe resolves on feedPath:
  `foodPostRecipeLink_resolvesOnFeedStack`
- no remaining home / onlyfood tab cases:
  `bottomTab_hasNoHomeOrOnlyfood_feedKeepsSlotAndIcon` (source-level
  references are a compile error once the cases are gone)
- re-tap pops feedPath to root on both kinds: `feedTabRetap_popsToRoot_onBothKinds`
- §8 prefill: `composePrefill_isFoodstrOnOnlyFoodOnly`

## Gate 3 — pbxproj (three-dot)
```sh
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Expected: empty.

No live gate: this PR opens no new relay path; the OnlyFood REQ is the same
one the deleted tab issued, from the same latched view model.

## Results
Gates 1–3 pending — recorded in the PR description after Seth's run.
