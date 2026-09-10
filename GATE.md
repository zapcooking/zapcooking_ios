# GATE — unified-feed/5-onlyfood-wot
Unified feed, PR 5 of 7 (§9): OnlyFood web-of-trust — opt-in gate (§3.4,
default OFF), drop counter, hidden-by-WoT empty state (§4). Own branch off main
at 78fe6bf (the PR 4 merge). Local build only on Seth's MacBook Air; gates run
on the MacinCloud box by hand. This GATE.md replaces PR 4's.

**Frozen at this commit.** App code is frozen at **17c32af** (604d989 plus the
Copilot review fixes: the toggle persists its own key without a `SafetyFilter`
rebuild; plural in the a11y label). This GATE.md is the only commit after it
and is the HEAD commit — `gate.sh` refuses to run otherwise. Previous GATE.md
commits (79fd972, 9aa7c62) are superseded; a further review fix re-opens the
freeze again: push a fresh GATE.md last.

**The toggle ships OFF**: nothing changes for a user who does not turn it on.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at 17c32af.
- Warnings in touched files: **zero new**. `OnlyFoodFeedViewModel.swift`,
  `wisp/OnlyFoodWotGate.swift`, `SafetyPreferences.swift`,
  `SafetySettingsView.swift`, `MainView.swift`, both test files: none.
  `OnlyFoodFilter.swift`'s eight (`SafetyFilter.shared` / `.snapshot` from
  the `@Sendable` closures in `live()`) are the set proven pre-existing in
  PR 4 by stash + rebuild of main's file; the new `isWotFiltered` closure
  reads the nonisolated `OnlyFoodWotGate` and adds none.
- Targeted serial run, 2026-09-09, `test-without-building` over
  `OnlyFoodWotTests SafetyTests OnlyFoodIngestParityTests OnlyFoodFeedViewModelTests
  OnlyFoodOwnPublishTests OnlyFoodHelpersTests OnlyFoodFilterTests FeedTabRoutingTests`:
  **106 tests in 8 suites passed** (OnlyFoodWotTests 15, SafetyTests 27,
  OnlyFoodIngestParityTests 18, OnlyFoodFeedViewModelTests 13,
  OnlyFoodOwnPublishTests 8, OnlyFoodHelpersTests 11, OnlyFoodFilterTests 6,
  FeedTabRoutingTests 8), verdict read from the `.xcresult` with
  `xcresulttool get test-results summary` (106 / 106 / 0 / 0). `SafetyTests` is
  in the run on purpose: the toggle's original `didSet` went through the shared
  `persist()`, which scheduled a `SafetyFilter.rebuildSnapshot` that landed
  during `SafetyTests` and failed `wordMatchIsCaseInsensitive`. The review fix
  persists the key alone; the preference test now flips the toggle and pins a
  sentinel snapshot to prove no rebuild is scheduled.
- pbxproj: no diff (three-dot). New files `wisp/OnlyFoodWotGate.swift` and
  `wispTests/OnlyFoodWotTests.swift` are self-registering.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout unified-feed/5-onlyfood-wot && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh unified-feed/5-onlyfood-wot
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on unified-feed/5-onlyfood-wot @ <this commit>`, with the four
known failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus
the three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **805** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 790; the delta is
**+15** (`OnlyFoodWotTests` 15; the `OnlyFoodFilterTests` live-gate case
was renamed, not added). If the parsed total is 790 the run was on a stale
tree — the script's branch assertion is a hard stop.

## Gate 2 — unit coverage (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'OnlyFoodWotTests|OnlyFoodFilterTests|OnlyFoodIngestParityTests|OnlyFoodFeedViewModelTests'
```
Required cases, each present and passing (the gate list from the PR 5 brief):
- toggle OFF drops nobody: `toggleOff_dropsNobody`
- toggle ON, network not ready, drops nobody: `toggleOn_networkNotReady_dropsNobody`,
  `networkReady_requiresFreshNonEmptyCache`
- toggle ON, ready: stranger dropped; self / network / seed kept:
  `toggleOn_networkReady_dropsStranger_keepsSelfNetworkAndSeed`,
  `make_buildsNetworkFromBothDegrees_andSeedLoadedFromSeed`
- seed not yet loaded fails open: `toggleOn_seedNotLoaded_failsOpen`
- trusted reposter of an untrusted author is KEPT: `repost_trustedReposter_ofUntrustedAuthor_isKept`
- both fail → dropped and counted: `repost_bothFail_isDropped_andCounted`,
  `counter_countsKind1_poll_andRepost_branches`
- counter resets on reload: `wotDropped_resetsOnEveryReload`
- toggle flip reloads once, accounted, re-filters the cache:
  `toggleFlip_reloadsOnce_reFiltersCache_andIsAccounted`, `reloadForWotChange_beforeStart_isANoOp`,
  `wotEnabled_isCapturedPerLoad`
- empty state is WoT only with the toggle on; stale count + toggle off → genuine
  empty; relay miss wins: `displayState_truthTable`
- toggle ships OFF, own key, notifies, schedules no SafetyFilter rebuild:
  `preference_shipsOff_persistsOwnKey_notifies_andDoesNotRebuildSafetySnapshot`
- live hook default: `OnlyFoodFilterTests/live_wotGateIsOffByDefault`
- all pre-existing OnlyFood and §7.4 gates: every case in `OnlyFoodIngestParityTests`,
  `OnlyFoodFeedViewModelTests`, `OnlyFoodOwnPublishTests`, `OnlyFoodHelpersTests`,
  `OnlyFoodFilterTests`, `FeedTabRoutingTests`

## Gate 3 — pbxproj (three-dot)
```sh
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Expected: empty.

No live gate: no relay path changed. A device smoke of the toggle (Safety →
"OnlyFood web of trust" on with no computed graph → feed unchanged; compute the
graph → strangers drop and the hidden-count state appears when everything
drops; "Show all" restores) is worth a minute before merge.

## Results
Gates 1–3 pending — recorded in the PR description after Seth's run.
