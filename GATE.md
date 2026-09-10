# GATE — feed/onlyfood-polish
Unified feed follow-ups from TestFlight 2.1 (2) device testing, six items on one
surface: the live-now rail on OnlyFood (§2.3 reversed), the online-users pill and
relay-count menu removed from the feed top bar, a Feed Relay row (and an Online Now
row) in the drawer, a Cheffy entry in the bar's trailing slot, the bolt as the
zap-glyph default, and the bounded read of the OnlyFood first-item clipping. Own
branch off main at dca127a (the #75 merge). Local build only on Seth's MacBook Air;
gates run on the MacinCloud box by hand. This GATE.md replaces #75's.

**Frozen at this commit.** App code is frozen at **b8b1254**. This GATE.md is the
only commit after it and is the HEAD commit — `gate.sh` refuses to run otherwise.
A review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at b8b1254 (fourth build,
  2026-09-10: builds one and two failed on "unable to type-check this expression in reasonable time" at the root `body` once the drawer call gained four arguments — fixed by moving the drawer and the Cheffy cover into their own properties; build three failed on argument order in that call; build four is the green one). Free disk 54.1 GB before the first, 54.0 GB after the last; no local Time
  Machine snapshots at build time.
- Warnings in touched files (`MainView.swift`, `SidebarDrawerView.swift`,
  `DrawerRow.swift`, `AppSettings.swift`, `wisp/FeedTabRouting.swift`,
  `wisp/FeedTopBar.swift`, `wispTests/FeedTopBarPolishTests.swift`): **zero** (the green build was incremental, so its 441 total warning lines are not comparable to a full-build baseline; every line is in a file this branch does not touch).
- pbxproj: no diff (three-dot, `git diff origin/main...HEAD --stat -- wisp.xcodeproj`
  empty). New files `wisp/FeedTopBar.swift`, `wispTests/FeedTopBarPolishTests.swift`
  are self-registering.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout feed/onlyfood-polish && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh feed/onlyfood-polish
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on feed/onlyfood-polish @ <this commit>`, with the four known failures
(#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the three
`SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **838** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 830; the delta is **+8**
(`FeedTopBarPolishTests` 8). If the parsed total is 830 the run was on a stale tree.

**Hosted gate on the box.** `feedPicker_staysCentred_whateverSitsAtTheEdges` opens a
real `UIWindow` in the test host and pumps the run loop (the `FeedStickToTopTests`
pattern). If it fails with "did not lay out", that is the harness, not the bar —
report the recorded issue text rather than retrying blind.

## Gate 2 — the brief's hermetic gates (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'FeedTopBarPolishTests|FeedTabRoutingTests|FeedStickToTopTests|BottomBarAndActionRowTests|OnlyFood'
```
- live rail on OnlyFood: `liveRail_rendersOnEveryKind_includingOnlyFood`
- no online-users or relay-count control on any kind:
  `topBar_hasNoOnlinePillOrRelayMenu_onAnyKind`
- drawer relay row shows the count, red at zero: `drawerRelayRow_showsTheCount_redAtZero`
- Cheffy present iff `CheffyGate.entryVisible()`:
  `cheffyEntry_presentWhenGateOpen_absentWhenClosed_onEveryKind`,
  `cheffyButton_rendersAtThe44ptTarget_withAvatarWeightGlyph`
- picker centred on every kind (hosted, measured): `feedPicker_staysCentred_whateverSitsAtTheEdges`
- bolt default / explicit bitcoin kept / fiat coin stack:
  `zapGlyph_defaultsToBolt_onFreshInstall`,
  `zapGlyph_explicitBitcoinPick_survives_andFiatStillCoinStack`
- all pre-existing feed, OnlyFood and top-bar gates: every other suite in the grep
  passes (only the known #4 case fails).

## Gate 3 — MANUAL on device
1. Launch on OnlyFood with at least one live stream discoverable, then switch to
   Follows: the live-now rail shows the same pills on both. Screenshot OnlyFood and
   Follows side by side; both list tops sit at the same offset under the bar.
2. Top bar on every kind: avatar, (content filter on general kinds), centred picker,
   Cheffy at the trailing edge; no person-count pill, no relay-count menu.
3. Tap Cheffy from OnlyFood and from Follows: the Cheffy cover opens both times.
   (With `cheffyEnabled` off the button is absent.)
4. Drawer: "Feed Relay" shows the connected count (red when 0) and opens the relay
   picker; "Online Now" opens the online sheet. Feed picker → Relay still opens the
   same picker.
5. Fresh install: the zap glyph is the bolt. Set Interface → Bitcoin B: the B shows
   and survives relaunch. Fiat mode: the coin stack, either way.
6. Item 1 diagnostic (see PR body): after a pull-to-refresh on OnlyFood with no live
   stream, the first card's avatar and name must sit fully below the bar.

## Gate 4 — pbxproj
`git diff origin/main...HEAD --stat -- wisp.xcodeproj` → empty.

## Results
Pending — recorded in the PR description after Seth's run.
