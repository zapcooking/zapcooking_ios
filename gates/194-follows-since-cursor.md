# GATE — fix/follows-since-cursor (PR #194: Follows since from its own sync cursor, issue #188)

Branch rebased onto main at b1140bc (#199). **Code frozen at 8a51e09.**
This file is the only commit after it, and it is the HEAD commit. A review
fix breaks the freeze: push a fresh gate file last. Replaces the gate at
857d277 (code f6df58f, before the rebase).

Three code commits: 47a5458 (extraction, no behaviour change, red tests),
019ff2c (the fix), 8a51e09 (one log line per load). The first two are
628cf64 / f6df58f rebased unchanged (no conflicts). No test opens a socket
or publishes anything.

## What was wrong
The Follows feed's `since` was the newest note of any author in
`EventStore`, which OnlyFood, threads, profiles, the engagement
subscription and the relay feeds all write to. A note another feature
stored moved `since` past follows' notes that were never fetched.

## Gate 0: the bug reproduces (628cf64, before the rebase)
At the extraction commit 3 of 6 `FollowsSinceTests` failed as intended
(raw note; note − 60 s; note − 300 s) and passed at the fix with the test
bodies unchanged. Not re-run after the rebase; the rebase touched none of
those files.

## The fix (019ff2c)
- `wisp/FollowsSince.swift`: `FollowsSyncCursor` (per-account key
  `follows_sync_cursor_<pubkey>`, clamped to now + 30 s on write and read,
  never moves back) and `FollowsLoadSettle` (records on settle only: every
  asked relay sent `EOSE` or `CLOSED`; not if the follow list changed
  during the load).
- `FeedViewModel.swift`: both load paths read the cursor; `refresh()` uses
  the earlier of the list head and the cursor; the dead
  `latest_feed_ts_` writes are gone.
- `FollowsCache.swift`: `update` clears the cursor when the set changes.
- `EventStore.swift`: `newestTimestamp` removed (no callers).
- `NostrKey.swift`: new key added to the account wipe list.
- `RelayPool.swift` (47a5458): `subscribe(queries:)` takes an optional
  `RelayBacklogObserver`.

## The log line (8a51e09)
One `os.Logger` line per load (subsystem `wisp`, category `follows-sync`,
public), at whichever comes first: the load settles, or it ends unsettled
(`FeedViewModel.cancelLiveSubscription`: replaced by the next load, the
feed switched away, or `stop()`):
```
Follows load: relays asked 12, answered 12, settled yes, seconds to settle 3.4
Follows load: relays asked 12, answered 9, settled no, seconds to settle -
```
Counts and a duration only: no relay URLs, authors or account. The settle
rule is unchanged. `wispTests/FollowsLoadReportTests.swift` (new, 4 tests):
format, settled-once-then-replaced, unsettled-replaced-twice, nothing asked.

No `project.pbxproj` diff (`git diff origin/main...HEAD --stat --
wisp.xcodeproj` is empty).

## Gate 1: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.2 (27B52), iPhone 18 Pro on iOS 27.2
(`90B23E20-BA47-4AD0-98EF-175513626A4B`), at 8a51e09, no local patch:
**TEST BUILD SUCCEEDED**. Unique warning sites equal main's at b1140bc in
every touched file (`FeedViewModel.swift` 5, `RelayPool.swift` 3,
`EventStore.swift` 4, the rest 0); 155 in the whole build on both.
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath t1-gate.xcresult
sh ci_scripts/gate.sh --parse t1-gate.xcresult
```
```
gate: 1680 passed / 3 failed / 22 skipped / 1705 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1705 tests ran
```
`FollowsSinceTests` 16/16, `FollowsLoadReportTests` 4/4.

## Overlap with #183
`git merge-tree` of this branch against #183's head c15cc3b is clean: no
textual conflict in `NostrKey.swift`, `RelayPool.swift` or anywhere else.

## Not gated
- No live relay run: the subscription is faked at the seam. How often real
  loads settle is what the new log line is for.
- The view-model wiring of `end()` (three lines in `FeedViewModel`) is not
  covered by a test; the report sink is not injectable through the view
  model.
- No line is written if the app is killed while a load is unsettled.
- Device pass: pick Follows after an OnlyFood landing on a fresh install,
  confirm the list fills, and read the `follows-sync` line in Console.
