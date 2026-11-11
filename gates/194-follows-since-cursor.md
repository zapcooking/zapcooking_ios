# GATE — fix/follows-since-cursor (PR #194: Follows since from its own sync cursor, issue #188)

**Code frozen at 722797f** (Copilot review fixes), on top of the merge of
main at 39c6797 (main b1140bc → 64f95cb, one conflict in `NostrKey.swift`:
the wipe list keeps both `FollowsSyncCursor.key` and main's
`FreshLastVisit.key`). This file is the only commit after it, and it is
the HEAD commit. Replaces the gate at 798e0a6 (code 8a51e09).

## Review fixes (722797f)
All five Copilot comments on #194:
1. **Follow-list race** (`FollowsCache.swift`): `update` now compares the
   set, clears the cursor and swaps the list under one lock hold;
   `FollowsLoadSettle` writes the cursor through the new
   `FollowsCache.ifFollowListUnchanged(pubkey:stamp:)`, which checks the
   stamp under that same lock.
2. **Rejected requests** (`RelayPool.swift`, `wisp/FollowsSince.swift`):
   `CLOSED` goes to a new `rejected(relayUrl:reason:streamCount:)` and no
   longer counts as an answer, except `blocked:` / `restricted:` /
   `invalid:`, where asking again gets the same refusal (so a paid or
   allow-listed write relay does not stall the cursor for ever).
   `rate-limited:`, `error:` and unprefixed reasons leave the load
   unsettled. **Seth may want to rule on this split.**
3. **Ended loads** (`FollowsLoadSettle.end()`): an ended load ignores late
   `EOSE`s and never commits.
4. **Cursor before persistence**: settling no longer writes the cursor.
   `RelaySubscription` counts yields under its lock (`yieldedCount`); each
   `EOSE` carries that count. The load commits once the feed consumer has
   reported (`consumed(_:accepted:)`) every element ahead of the settling
   `EOSE`, and the notes it accepted have been written to `EventStore`.
   Held notes are capped at 5,000; past that the load gives up on the
   cursor (errs towards re-asking).
5. **Hermetic test**: `FeedViewModel.StartupServices` gains
   `ensureProfiles` and `observeMissingProfiles`; `hydrateProfiles` and the
   missing-profile sweep go through them. `FollowsSinceTests` stubs both and
   asserts the uncached author's fetch went through the stub.

New tests in `FollowsSinceTests` (now 23): commit waits for consumption
and persistence; consumer already caught up commits at settle; ended load
ignores late answers / uncommitted backlog; final vs transient `CLOSED`;
held-backlog cap; `ifFollowListUnchanged`; `yieldedCount` counts stream
elements. The end-to-end test now pushes its note through a real
`RelaySubscription` stream and checks it is on disk when the cursor moves.

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
  asked relay ended its backlog; not if the follow list changed during the
  load; the review fixes above tighten both halves).
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
Counts and a duration only: no relay URLs, authors or account. The log line
does not change the settle rule. `wispTests/FollowsLoadReportTests.swift` (new, 4 tests):
format, settled-once-then-replaced, unsettled-replaced-twice, nothing asked.

No `project.pbxproj` diff (`git diff origin/main...HEAD --stat --
wisp.xcodeproj` is empty).

## Gate 1: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.2, iPhone 18 Pro on iOS 27.2
(`90B23E20-BA47-4AD0-98EF-175513626A4B`, pre-booted with
`ci_scripts/preboot-sim.sh`), tree identical to 722797f, no local patch:
**TEST BUILD SUCCEEDED**. No new warning sites in any touched file (the
one the first build showed, an `await` in a default-argument closure in
`FollowsSince.swift`, was fixed before the commit).
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath t-full.xcresult
sh ci_scripts/gate.sh --parse t-full.xcresult
```
```
gate: 1831 passed / 3 failed / 23 skipped / 1857 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1857 tests ran
```
`FollowsSinceTests` 23/23, `FollowsLoadReportTests` 4/4, `FeedStartTests`
and `LiveStreamReviewTests` green. No `project.pbxproj` diff
(`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty).

## Not gated
- No live relay run: the subscription is faked at the seam. How often real
  loads settle is what the new log line is for.
- The view-model wiring of `end()` is not covered by a test; the report
  sink is not injectable through the view model.
- The cross-thread interleavings (#1, #4) are covered by ordering tests
  and locks, not by a stress test.
- No line is written if the app is killed while a load is unsettled.
- Device pass: pick Follows after an OnlyFood landing on a fresh install,
  confirm the list fills, and read the `follows-sync` line in Console.
