# GATE — concern/tag-suggestion-pills (PR #85: #84 on top of the merged pills)
The pills themselves merged as #83 (0a5f6ee). This branch is rebased onto that
merge and carries **#84**: `OnlyFoodFilter.maxHashtags` is **20** (was 5 — the
3.3 live sample's 6–20 band was genuine food posts, 100+ was aggregators) and the
pills are the cross-platform set in the cross-platform order (`foodstr, coffee,
cooking, breakfast, dinner, lunch, cookstr, food`). Since the eight pills now fit
under the cap together, the cap is only reachable by typing. Plus the three
Copilot findings on #85: the "No food tag yet" message says the note's real tag
count (it can exceed the cap when typed) and how many to remove
(`OnlyFoodCompose.noFoodTagMessage`); `removing` collapses runs of spaces until
stable; `isHashtagLine` accepts only real hashtag tokens, so a pill after
`#foodstr,` starts a paragraph. `FoodHashtags` and the optimistic-insert rule are
unchanged. Off main at 0a5f6ee (the #83 merge). Local build only on Seth's MacBook Air; gates run on the MacinCloud box
by hand.

**Frozen at this commit.** App code is frozen at **f2172da** (9701cd6, #84 rebased
onto main, plus the Copilot fixes). The previous GATE.md (4c895e7, before the
rebase) is superseded. This GATE.md is the only commit after it and is the
HEAD commit — `gate.sh` refuses to run otherwise. A
review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- Build (iPhone 17 / OS 26.2, `build-for-testing`, shared DerivedData): see the
  #84 line below. Earlier: **green** at 9b19c50 and at eac62f1. Four builds this session (2026-09-19): one compile fix in the new test
  file (`Comment` wrappers), one logic fix in `OnlyFoodCompose.removing` (a space
  left after a newline), then green twice. Free disk 19 → 13 GB across the runs
  (the usual transient simulator dip); no local Time Machine snapshots.
- Warnings in touched files (`ComposeView.swift`, `ComposeViewModel.swift`,
  `MainView.swift`, `OnlyFoodFilter.swift`, `wisp/ComposePresenter.swift`,
  `wisp/FeedTabRouting.swift`, `wisp/HashtagSuggestionRow.swift`,
  `wisp/OnlyFoodCompose.swift`, the five test files): **zero**.
- #84 (2026-09-19): `build-for-testing` **green** at d096290 (pre-rebase) and at
  f2172da; zero new warnings (the eight Swift 6 concurrency lines in
  `OnlyFoodFilter.swift` at 94–105 pre-exist at 90–101 — stash-build proven the
  same day). Suites not run on the Air (the no-local-test rule) — Gate 1 on the
  box is the proof.
- Serial runs on the Air (the C-G exception form): `OnlyFoodComposeTests` 13/13,
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

**Count.** This branch has **860** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main (0a5f6ee, with #83) has 856;
the delta is **+4** (`OnlyFoodComposeTests` 17, was 13 — #84 added
`suggestedTags_matchTheCrossPlatformSetAndOrder`; the Copilot fixes added
`removing_collapsesRunsOfSpaces`, `appending_afterPunctuatedTag_startsNewParagraph`,
`noFoodTagMessage_saysTheRealCount`). If the parsed total is 856 the run was on
main's tree. If the parsed total is 849 the run was on a
stale tree. `OnlyFoodComposeLiveTests` stays opt-in and skipped.

## Gate 2 — C-H's seed tests updated (name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'OnlyFoodComposeTests|OnlyFoodFilterTests|FeedTabRoutingTests|ComposeSeedTests'
git grep -n 'prefill' -- wisp/OnlyFoodCompose.swift wisp/FeedTabRouting.swift MainView.swift
```
- no seed: `onlyFoodComposer_opensEmpty_nothingAutoAdded`,
  `generalComposer_hasNoPills_noConfirm`, `presenter_newNoteRequest_carriesPillsAndNoSeed`,
  `FeedTabRoutingTests/composeSuggestions_areTheFoodPillsOnOnlyFoodOnly`
- the set: `suggestedTags_allReachOnlyFood_noDuplicates_foodstrFirst`,
  `suggestedTags_matchTheCrossPlatformSetAndOrder` (#84 order, pinned literally)
- the cap is 20 (#84): `OnlyFoodFilterTests/structuralSpam_boundaries` — 7 and 20
  t-tags accept, 21 and 100 reject, same on the content side
- the Copilot fixes: `removing_collapsesRunsOfSpaces`,
  `appending_afterPunctuatedTag_startsNewParagraph`, `noFoodTagMessage_saysTheRealCount`
- toggle: `pill_tapAppends_secondTapRemoves_bodyIsTruth`,
  `pill_afterProse_startsATagLine_thenJoinsIt`, `typedTag_selectsPill_andPillRemovesIt`
- the cap, as the filter counts it: `cap_countsLikeTheFilter_disablesFurtherPills_reenablesOnRemove`,
  `typedOverflow_isFlagged_andMatchesTheFilter`
- the dead end: `publishConfirm_onlyWhenNoFoodTag_fromOnlyFood`, `confirmAddFoodstr_isTheToggle`,
  `confirmAddFoodstr_atCapWithNoFoodTag_isRefused`
- the row: `suggestionRow_renders_none_one_cap`
- `ComposeSeedTests` (5) unchanged in substance — wallet / share seeds still merge.
- the grep returns nothing: no `prefill` symbol remains on the OnlyFood path.

## Gate 3 — BY HAND on device: compose from OnlyFood, screenshot each
1. **No pill tapped**: OnlyFood → FAB. Editor empty, placeholder "What are you
   cooking?", the row under it: hint, eight pills in the order foodstr, coffee,
   cooking, breakfast, dinner, lunch, cookstr, food, "0/20 tags". Type a line, tap
   Publish → the "No food tag yet" alert with Add #foodstr / Post anyway / Cancel.
   Cancel. Screenshot the composer and the alert.
2. **One pill**: tap #foodstr → it fills, "#foodstr" appears on its own line under
   the text, the chip row shows it, "1/20 tags". Tap it again → gone from the body
   and the count. Tap it once more. Screenshot.
3. **All pills, then the cap**: tap the other seven → "8/20 tags", nothing dims
   (the whole row fits under the cap). Clear the body, type eighteen tags by hand
   ("#a1 #a2 … #a18"), tap #foodstr and #coffee → "20/20 tags", the six remaining
   pills dim and do not respond; a selected pill still toggles off and frees a
   slot. Type a 21st "#tag" by hand → the count turns red with the "hides notes
   with more than 20 tags" line. Delete it. Screenshot at 20/20.
   Then clear the body and type twenty non-food tags, Publish → the alert offers
   only Post anyway / Cancel and says "already has 20 tags. Remove one". Add two
   more, Publish → "already has 22 tags. Remove 3". Cancel. Type "#foodstr," on
   its own line, tap #coffee → it lands on a new paragraph, not after the comma.
4. **General composer**: Follows → FAB: no row, "What's on your mind?", no alert
   on Publish. Recipes → +: the recipe form, unchanged.

## Gate 4 — BY HAND: a pill-tagged note reaches OnlyFood
From OnlyFood, compose "test <time>", tap #foodstr, Publish (let the undo timer
run). Expect: the note appears at the top of OnlyFood at once (optimistic insert,
rule unchanged), survives a pull-to-refresh, and shows in the web /community feed.
Then (#84) compose "test <time>" with all eight pills tapped (8 tags): it must also
appear in OnlyFood after a pull-to-refresh — on the old cap it would have been
hidden. The web feed shows it only once frontend#742 ships; note which.
Hermetic mirror, opt-in on the box: `OnlyFoodComposeLiveTests` (see its header for
the enable file / env) publishes from an ephemeral key with one pill tapped and
checks the insert.

## Gate 5 — pbxproj
`git diff origin/main...HEAD --stat -- wisp.xcodeproj` → empty.

## Results
Pending — recorded in the PR description after Seth's run.
