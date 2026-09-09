# GATE — unified-feed/4-ingest-parity
Unified feed, PR 4 of 7 (§9): OnlyFood ingest parity with Android — relay set
(§3.1), kinds 1 / 6 / poll (§3.2), resume paint (§3.3). WoT is PR 5. Own branch
off main at 7bf3e9f (the PR 3 merge). Local build only on Seth's MacBook Air;
gates run on the MacinCloud box by hand. This GATE.md replaces PR 3's.

**Frozen at this commit.** App code is frozen at **f2cf3f5** (cc3dcc9 plus the
Copilot review fixes: paging cursor counts repost-inserted inner notes;
`dropHidden` rebuilds the attribution dictionary). This GATE.md is the only
commit after it and is the HEAD commit — `gate.sh` refuses to run otherwise.
Previous GATE.md commits (d9ff69f, 42ad918) are superseded; a further review
fix re-opens the freeze again: push a fresh GATE.md last.

**This PR changes what every user sees on the default feed.** Expected
visible difference: more posts (three relays instead of one), reposts and
polls now appear, a faster first paint after a cold start. See the PR body
for the one UI gap (reposts render without a "reposted by" line).

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at f2cf3f5.
- Warnings in touched files: **zero new**. `OnlyFoodFeedViewModel.swift`,
  `MainView.swift`, `wisp/FeedTabRouting.swift`, both test files: none.
  `OnlyFoodFilter.swift` shows eight (`SafetyFilter.shared` / `.snapshot`
  from the `@Sendable` closures in `live()`, lines 88 / 92 / 98 / 99 ×2) —
  **pre-existing**: stash + `touch` + rebuild of main's file at 7bf3e9f
  produces the same eight at lines 84 / 88 / 94 / 95 (this branch's header
  comment shifts them by four); the lines blame to 93115c6d / 51621b38
  (2026-08-30). `live()` is untouched.
- Targeted serial run, 2026-09-09, `test-without-building` over
  `OnlyFoodIngestParityTests OnlyFoodFeedViewModelTests OnlyFoodOwnPublishTests
  OnlyFoodHelpersTests OnlyFoodFilterTests FeedTabRoutingTests FeedKindStoreTests`:
  **75 tests in 7 suites passed** (OnlyFoodIngestParityTests 18, OnlyFoodFeedViewModelTests 13,
  OnlyFoodOwnPublishTests 8, OnlyFoodHelpersTests 11, OnlyFoodFilterTests 6,
  FeedTabRoutingTests 8, FeedKindStoreTests 11; the new suite and one new
  routing case are the +19 over main).
- pbxproj: no diff (three-dot). New file `wispTests/OnlyFoodIngestParityTests.swift`
  is self-registering.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout unified-feed/4-ingest-parity && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh unified-feed/4-ingest-parity
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on unified-feed/4-ingest-parity @ <this commit>`, with the four
known failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus
the three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **790** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 771; the delta is
**+19** (`OnlyFoodIngestParityTests` 18, `FeedTabRoutingTests` +1). If
the parsed total is 771 the run was on a stale tree — the script's branch
assertion is a hard stop.

## Gate 2 — unit coverage (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'OnlyFoodIngestParityTests|OnlyFoodFeedViewModelTests|FeedTabRoutingTests'
```
Required cases, each present and passing (§10 rows for this PR):
- kind-6 inserts the INNER note at the REPOST's timestamp:
  `repost_insertsInnerNote_sortedByRepostTimestamp`, `repost_byCurrentUser_marksUserReposts`
- repost dropped for blocked inner author / muted inner word / inner reply:
  `repost_dropped_whenInnerAuthorBlocked`, `repost_dropped_whenInnerContentHitsMutedWord`,
  `repost_dropped_whenInnerNoteIsReply`, `repost_dropped_whenInnerIsStructuralSpam_orUnparseable`
- two reposters, one entry, both attributed:
  `repost_sameInnerByTwoAuthors_oneEntry_bothAttributed`,
  `repost_ofNoteAlreadyInList_addsAttributionOnly_keepsPosition`
- poll accepted, structural cap applies: `poll_isAccepted_andStructuralCapApplies`,
  `poll_dropped_onMutedWord_andBlockedAuthor`
- §7.4 across three relays: `threeRelays_oneLogicalLoad_latchHolds_refreshRequeries`;
  the pre-existing `OnlyFoodFeedViewModelTests/start_isOneShot`,
  `repeatedStart_afterLoad_keepsCacheAndIssuesNoREQ`, `refresh_isTheOnlyRequeryPath`
- resume: `resume_withNonEmptyList_doesNotRepaint_andNeverClears`,
  `resume_withEmptyList_paintsFromCache_thenMerges`,
  `resume_beforeStart_orDuringInitialLoad_isANoOp`,
  `FeedTabRoutingTests/resumeHook_onlyResumesOnlyFood_andOnlyAfterStart`
- cache paint replays attribution: `cachePaint_replaysRepostAttribution_fromOuterEvent`
- review fixes: `paging_cursorCountsRepostInsertedInner_evenWithoutItsOwnFoodTag`,
  `hiddenReposter_losesAttribution_entryKeptWhileOtherReposterRemains`
- all pre-existing OnlyFood gates: every case in `OnlyFoodFeedViewModelTests`,
  `OnlyFoodOwnPublishTests`, `OnlyFoodHelpersTests`, `OnlyFoodFilterTests`

## Gate 3 — pbxproj (three-dot)
```sh
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Expected: empty.

No live gate in this file: the three-relay REQ is the same one-shot
`OnlyFoodRelay.query` path over the existing pool. A manual smoke on device
(cold start → OnlyFood shows reposts and polls; background → foreground does
not blank the list) is worth a minute before merge, given the blast radius.

## Results
Gates 1–3 pending — recorded in the PR description after Seth's run.
