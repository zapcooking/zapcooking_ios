# GATE — concern/tag-suggestion-pills
C-H's automatic "#foodstr\n\n" prefill in the OnlyFood composer is gone; nothing
is added to a note unless the user taps. In its place a row of tappable tag pills
(`HashtagSuggestionRow`) under the editor, OnlyFood composer only; a live "n/5
tags" count and pill disabling at the §7.3 cap, counted exactly as
`OnlyFoodFilter` counts; a publish confirm when no food-set tag is present
("Add #foodstr" is a tap). `OnlyFoodFilter`, `FoodHashtags` and the
optimistic-insert rule are unchanged. Own branch off main at 9652e49 (the #82
merge). Local build only on Seth's MacBook Air; gates run on the MacinCloud box
by hand.

**Frozen at this commit.** App code is frozen at **eac62f1**. This GATE.md is the only
commit after it and is the HEAD commit — `gate.sh` refuses to run otherwise. A
review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- Build (iPhone 17 / OS 26.2, incremental behind `xcodebuild test`): **green** at
  eac62f1. Four builds this session (2026-09-19): one compile fix in the new test
  file (`Comment` wrappers), one logic fix in `OnlyFoodCompose.removing` (a space
  left after a newline), then green twice. Free disk 19 → 13 GB across the runs
  (the usual transient simulator dip); no local Time Machine snapshots.
- Warnings in touched files (`ComposeView.swift`, `ComposeViewModel.swift`,
  `MainView.swift`, `wisp/ComposePresenter.swift`, `wisp/FeedTabRouting.swift`,
  `wisp/HashtagSuggestionRow.swift`, `wisp/OnlyFoodCompose.swift`, the four test
  files): **zero**.
- Serial runs on the Air (the C-G exception form): `OnlyFoodComposeTests` 12/12,
  `FeedTabRoutingTests`, `ComposeSeedTests`, `OnlyFoodOwnPublishTests`,
  `FeedTopBarPolishTests` all green (42 tests). PNGs of the row in the three
  by-hand states (no pill, one, at the cap with the rest disabled) examined.
- pbxproj: no diff (three-dot). `wisp/HashtagSuggestionRow.swift` is
  self-registering.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout concern/tag-suggestion-pills && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh concern/tag-suggestion-pills
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on concern/tag-suggestion-pills @ <this commit>`, with the four known
failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the three
`SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **855** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 849; the delta is **+6**
(`OnlyFoodComposeTests` 12, was 6). If the parsed total is 849 the run was on a
stale tree. `OnlyFoodComposeLiveTests` stays opt-in and skipped.

## Gate 2 — C-H's seed tests updated (name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'OnlyFoodComposeTests|FeedTabRoutingTests|ComposeSeedTests'
git grep -n 'prefill' -- wisp/OnlyFoodCompose.swift wisp/FeedTabRouting.swift MainView.swift
```
- no seed: `onlyFoodComposer_opensEmpty_nothingAutoAdded`,
  `generalComposer_hasNoPills_noConfirm`, `presenter_newNoteRequest_carriesPillsAndNoSeed`,
  `FeedTabRoutingTests/composeSuggestions_areTheFoodPillsOnOnlyFoodOnly`
- the set: `suggestedTags_allReachOnlyFood_noDuplicates_foodstrFirst`
- toggle: `pill_tapAppends_secondTapRemoves_bodyIsTruth`,
  `pill_afterProse_startsATagLine_thenJoinsIt`, `typedTag_selectsPill_andPillRemovesIt`
- the cap, as the filter counts it: `cap_countsLikeTheFilter_disablesFurtherPills_reenablesOnRemove`,
  `typedOverflow_isFlagged_andMatchesTheFilter`
- the dead end: `publishConfirm_onlyWhenNoFoodTag_fromOnlyFood`, `confirmAddFoodstr_isTheToggle`
- the row: `suggestionRow_renders_none_one_cap`
- `ComposeSeedTests` (5) unchanged in substance — wallet / share seeds still merge.
- the grep returns nothing: no `prefill` symbol remains on the OnlyFood path.

## Gate 3 — BY HAND on device: compose from OnlyFood, screenshot each
1. **No pill tapped**: OnlyFood → FAB. Editor empty, placeholder "What are you
   cooking?", the row under it: hint, eight pills, "0/5 tags". Type a line, tap
   Publish → the "No food tag yet" alert with Add #foodstr / Post anyway / Cancel.
   Cancel. Screenshot the composer and the alert.
2. **One pill**: tap #foodstr → it fills, "#foodstr" appears on its own line under
   the text, the chip row shows it, "1/5 tags". Tap it again → gone from the body
   and the count. Tap it once more. Screenshot.
3. **At the cap**: tap four more → "5/5 tags", the three remaining pills dim and
   do not respond; a selected pill still toggles off and frees a slot. Type a
   sixth "#tag" by hand → the count turns red with the "hides notes with more
   than 5 tags" line. Delete it. Screenshot at 5/5.
4. **General composer**: Follows → FAB: no row, "What's on your mind?", no alert
   on Publish. Recipes → +: the recipe form, unchanged.

## Gate 4 — BY HAND: a pill-tagged note reaches OnlyFood
From OnlyFood, compose "test <time>", tap #foodstr, Publish (let the undo timer
run). Expect: the note appears at the top of OnlyFood at once (optimistic insert,
rule unchanged), survives a pull-to-refresh, and shows in the web /community feed.
Hermetic mirror, opt-in on the box: `OnlyFoodComposeLiveTests` (see its header for
the enable file / env) publishes from an ephemeral key with one pill tapped and
checks the insert.

## Gate 5 — pbxproj
`git diff origin/main...HEAD --stat -- wisp.xcodeproj` → empty.

## Results
Pending — recorded in the PR description after Seth's run.
