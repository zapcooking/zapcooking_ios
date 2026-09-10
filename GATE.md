# GATE — unified-feed/6-bottom-bar-and-buttons
Unified feed, PR 6 of 7 (§9): bottom bar Feed · Recipes · Search · Messages ·
Notifications (§5) and the shared 44×44 / 20pt action-row control (§6). Own
branch off main at 862856b (the PR 5 merge). Local build only on Seth's MacBook
Air; gates run on the MacinCloud box by hand. This GATE.md replaces PR 5's.

**Frozen at this commit.** App code is frozen at **feeb74e**. This GATE.md is the
only commit after it and is the HEAD commit — `gate.sh` refuses to run otherwise.
A review fix re-opens the freeze: push a fresh GATE.md last.

**Launch tab not decided here.** Bar order puts Feed first; `selectedTab` still
launches on `.recipes`, so the launch tab is the second slot. Seth decides.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at feeb74e. Free disk
  56 GB before, 55 GB after.
- Warnings in touched files: **zero**. `MainView.swift`, `PostCardView.swift`,
  `SidebarDrawerView.swift`, `wisp/MessagesView.swift`, `wisp/ActionRowItem.swift`,
  `wisp/ArticleView.swift`, `wisp/RecipeBookmarkButton.swift`, both test files:
  none. 663 warning lines in the build overall, all outside the touched set.
- Targeted serial run, 2026-09-09, `test-without-building` over
  `BottomBarAndActionRowTests FeedTabRoutingTests`: **17 tests in 2 suites
  passed** (BottomBarAndActionRowTests 9, FeedTabRoutingTests 8).
- pbxproj: no diff (three-dot). New files `wisp/ActionRowItem.swift` and
  `wispTests/BottomBarAndActionRowTests.swift` are self-registering.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout unified-feed/6-bottom-bar-and-buttons && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh unified-feed/6-bottom-bar-and-buttons
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on unified-feed/6-bottom-bar-and-buttons @ <this commit>`, with the
four known failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`
plus the three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **814** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 805; the delta is **+9**
(`BottomBarAndActionRowTests` 9; `FeedTabRoutingTests`' enum gate was rewritten,
not added). If the parsed total is 805 the run was on a stale tree — the
script's branch assertion is a hard stop.

## Gate 2 — unit coverage (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'BottomBarAndActionRowTests|FeedTabRoutingTests'
```
Required cases, each present and passing (the gate list from the PR 6 brief):
- every control in the shared action row measures ≥ 44×44:
  `everyActionRowControl_rendersAtLeast44by44`, `actionRowButton_rendersItsItemAtFullTarget`,
  `actionRowItem_constantsMatchSpec`
- the worst-case row fits the narrowest supported width:
  `worstCaseRow_fitsTheNarrowestSupportedWidth`
- `bottomBarCases` is exactly [feed, recipes, search, messages, notifications]:
  `bottomBar_isFeedRecipesSearchMessagesNotifications`
- kitchen and wallet are drawer-only and absent from the bar:
  `kitchenAndWallet_areDrawerOnly_andAbsentFromTheBar`
- no remaining My Kitchen bar slot; one feed case; flame glyph:
  `bottomTab_hasNoHomeOrOnlyfood_andOneFeedCase`, `feed_usesFlame_andGlyphSizesMatchSpec`
- amber dot: `unreadDot_isAmberFBBF24`; watch-only bar: `watchOnlyBar_dropsMessages_likeAndroidReadOnly`
- feed re-tap still pops on both kinds: `feedTabRetap_popsToRoot_onBothKinds`

Messages badge-on-unread and pop-on-re-tap are wiring in `MainView`
(`hasUnreadBadge(_:)`, `popToRoot(.messages)` → `messagesPath`) and are checked by
hand alongside Gate 3.

## Gate 3 — MANUAL (box or by hand): visual comparison against Android
On the narrowest device, screenshot the post action row and the bottom bar side by
side with the Android build and attach both to the PR. Not asserted in code.
