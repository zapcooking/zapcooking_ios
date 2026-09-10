# GATE — unified-feed/7-scroll-behavior
Unified feed, PR 7 of 7 (§9), the last one: Android's stick-to-top scroll
behaviour (§7) on both feed bodies, and the PR 2 scroll-position regression
fixed by keeping both bodies mounted. Own branch off main at 13c0614 (the PR 6
merge). Local build only on Seth's MacBook Air; gates run on the MacinCloud box
by hand. This GATE.md replaces PR 6's.

**Frozen at this commit.** App code is frozen at **2aa7731**. This GATE.md is the
only commit after it and is the HEAD commit — `gate.sh` refuses to run otherwise.
A review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at 2aa7731. Two builds, not
  one: the first failed on the test file (a mutating call inside `#expect`, and
  `FeedKindSwitchTracker` wrongly `nonisolated` next to the main-actor
  `FeedKind`); both fixed, second build green. Free disk 53 GB before, 53 GB after.
- Warnings in touched files: **zero**. `MainView.swift`, `wisp/FeedTabRouting.swift`,
  `wisp/FeedFollowState.swift`, `wisp/KeptMountedFeedBodies.swift`,
  `wispTests/FeedStickToTopTests.swift`: none.
- Targeted serial run, 2026-09-09, `test-without-building` over every suite
  matching `feed|onlyfood` (17 suites): **140 tests, 139 passed, 1 failed** — the
  failure is the known #4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`,
  identical on main. `FeedStickToTopTests` 10 / 10, including the three hosted
  gates. Measurement printed by the hosted test: hidden rows evaluated while the
  visible body scrolled **0**, visible rows during that scroll 25, hidden rows on
  an off-screen prepend **1 of 61**.
- pbxproj: no diff (three-dot). New files `wisp/FeedFollowState.swift`,
  `wisp/KeptMountedFeedBodies.swift`, `wispTests/FeedStickToTopTests.swift` are
  self-registering.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout unified-feed/7-scroll-behavior && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh unified-feed/7-scroll-behavior
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on unified-feed/7-scroll-behavior @ <this commit>`, with the four
known failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus
the three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **824** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 814; the delta is **+10**
(`FeedStickToTopTests` 10). If the parsed total is 814 the run was on a stale
tree — the script's branch assertion is a hard stop.

**Hosted gates on the box.** Three `FeedStickToTopTests` cases open a real
`UIWindow` in the test host and pump the run loop (`kindSwitch_awayFromOnlyFoodAndBack_restoresScrollPosition`,
`viewBuilderSwitch_losesScrollPosition_theRegression`,
`hiddenBody_doesNoRowWorkWhileTheVisibleBodyScrolls`). They took ~26 s locally.
If one fails on the box with "did not lay out", that is the harness, not §7 —
report the recorded issue text rather than retrying blind.

## Gate 2 — unit coverage (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'FeedStickToTopTests|FeedTabRoutingTests|OnlyFood'
```
Required cases, each present and passing (the gate list from the PR 7 brief):
- head change with autoFollowTop true and no drag re-pins: `headChange_whileFollowingAndSettled_repins`
- head change after a user drag does not re-pin: `headChange_afterUserDrag_doesNotRepin`
- resumes only when settled AND at the very top, not near it:
  `follow_resumesOnlyWhenSettledAtTheVeryTop_notNearIt`
- re-tap / pill never fight auto-follow: `retapAndPill_followAgain_andNeverFightAutoFollow`
- explicit picker selection re-pins; first composition and tab re-entry do not:
  `pickerSelection_repins_firstCompositionAndTabReentryDoNot`
- switching kind away from OnlyFood and back restores the scroll position:
  `kindSwitch_awayFromOnlyFoodAndBack_restoresScrollPosition` (and the control
  `viewBuilderSwitch_losesScrollPosition_theRegression`)
- the optimistic self-insert while scrolled down does not re-pin:
  `optimisticSelfInsert_whileScrolledDown_doesNotRepin`
- the hidden body's cost: `hiddenBody_doesNoRowWorkWhileTheVisibleBodyScrolls`
- prefetch distance unchanged: `pagePrefetchDistance_staysSix`
- all pre-existing feed and OnlyFood gates: every other suite in the grep passes
  (only the known #4 case fails).
