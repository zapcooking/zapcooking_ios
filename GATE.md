# GATE — unified-feed/1-feedkind-onlyfood
Unified feed, PR 1 of 7 (§9): `FeedKind.onlyFood` + picker entry + cold-start
landing / persistence, still routed to the old OnlyFood tab. Own branch off
main at 9a65c67. Local build only on Seth's MacBook Air; gates run on the
MacinCloud box by hand.

**Frozen at this commit.** App code is frozen at **640006b**; this GATE.md is
the only commit after it and is the HEAD commit — `gate.sh` refuses to run
otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at 640006b.
- Warnings in touched files: **zero new**. The five `FeedViewModel.swift`
  warnings in the log (`:382`, `:640`, `:709`, `:1021`×2 — `SafetyFilter.shared`
  from a detached closure, `flushPendingInserts` await) blame to
  04c150e0 / e317ca21 / 52ce4838 / b7ddc4af on main, shifted by this
  branch's insertions. `MainView.swift`, `RelaySetRepository.swift`,
  `wisp/FeedKindStore.swift`, `wispTests/FeedKindStoreTests.swift`: none.
- Targeted serial run, 2026-09-09, `test-without-building`
  `-only-testing:wispTests/FeedKindStoreTests`: **10 tests in 1 suite passed**
  (79 s, all new).
- pbxproj: no diff (three-dot). New files, both self-registering:
  `wisp/FeedKindStore.swift`, `wispTests/FeedKindStoreTests.swift`.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout unified-feed/1-feedkind-onlyfood && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh unified-feed/1-feedkind-onlyfood
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on unified-feed/1-feedkind-onlyfood @ <this commit>`, with the four
known failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus
the three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **764** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 754; the delta is the
**+10** new `FeedKindStoreTests`. If the parsed total is 754 the run was on a
stale tree — the script's branch assertion is a hard stop.

## Gate 2 — unit coverage (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'FeedKindStoreTests'
```
Required cases, each present and passing (§10, PR 1 row: "cold start with no
saved key lands on OnlyFood **and** leaves `last_feed_type_<pubkey>` unset; an
explicit pick writes it"):
- `coldStart_noSavedKey_landsOnOnlyFood_andDoesNotWrite`,
  `viewModel_coldStart_landsOnOnlyFood_andLeavesKeyUnset`
- `explicitPick_writesKey_andRoundTrips`, `explicitOnlyFood_isDistinctFromNeverChose`,
  `viewModel_restoresSavedPick_andExplicitOnlyFoodWritesKey`
- relay / relay-set restore and fallback:
  `relay_restoresNormalizedUrl_andClearsRelaySetKey`,
  `relay_withoutRestorableUrl_fallsBackToOnlyFood`,
  `relaySet_restoresViaLookup_clearsUrlKey_andFallsBackWhenGone`
- on-disk contract: `unknownStoredName_fallsBackToOnlyFood_withoutRewriting`,
  `storedNames_areStable`

## Gate 3 — pbxproj (three-dot)
```sh
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Expected: empty.

No live gate: this PR opens no new relay path. A restored relay-set landing
uses the same `startSubscription` the explicit Relay pick already used.

## Results
Gates 1–3 pending — recorded in the PR description after Seth's run.
