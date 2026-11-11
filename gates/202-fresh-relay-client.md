# GATE — fresh/relay-client (PR #202: FreshRelayClient, the feed relay's own read-only connection)

main merged in at cdbb9e6 (#201) as cb6cebe. **Code frozen at 9ef9a0c.**
This file is the only commit after it, and it is the HEAD commit. A review
fix breaks the freeze: push a fresh gate file last. Replaces the gate for
1ecd407 (on b1140bc).

Fresh feed PR 2. Nothing in the app calls the client yet. No hermetic test
opens a socket. The one live test is opt-in and read-only.

## What changed since the first gate (9ef9a0c, Seth's rulings 2026-11-10)
- `invalid:` is remembered for topic slugs only. A feed page, recipes page
  or tail refused `invalid:` is reported (`.invalid`, or the tail ends
  `.ended(.invalid)`) and the next request is sent again.
- The tail's newest `created_at` is clamped to now + 30 s
  (`FreshRelayClient.futureSkewSeconds`, the app's skew), so a future-dated
  post cannot move the resume point ahead.
- Number conversions checked (the #201 crash class): the client has no
  `Int(_:)` / `Int(Double)` on relay or stored values. Relay events are
  parsed by `NostrEvent(json:)`, whose `as? Int` returns nil for `1e100`
  or `1700000000.5`, so such an event is dropped and counted as rejected.
  A test pins it.
- 5 new tests: feed page, recipes and tail each sent again after
  `invalid:`; the clamp on revive; out-of-range / fractional numbers
  dropped. The overlap test's newest post moves from now + 600 to
  now − 600 (a post at now + 600 is now clamped; the test's point is the
  overlap, unchanged).

## Gate 1: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.2 (27B52), iPhone 18 Pro on iOS 27.2
(`90B23E20-BA47-4AD0-98EF-175513626A4B`), at 9ef9a0c: **TEST BUILD
SUCCEEDED**, no warnings in any file the branch touches (the three new
Swift files).
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-client \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath fc-gate3.xcresult
sh ci_scripts/gate.sh --parse fc-gate3.xcresult
```
```
gate: 1753 passed / 3 failed / 23 skipped / 1779 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1779 tests ran
```
`FreshRelayClientTests` passed (33 tests). `FreshRelayClientLiveTests/smoke`
was skipped (the 23rd skip; no sentinel file). **No local patch.** No
`project.pbxproj` diff (`git diff origin/main...HEAD --stat -- wisp.xcodeproj`
is empty).

**The run before this one failed and is reported, not hidden.** The first
full run at the same commit (fc-gate2) gave 1736 / 20 / 23 / 1779: the
known three plus 17 hosted-window and `ImageRenderer` tests (Lazarus
renders, compose toolbar, attachment strip, EntryPresentation,
FeedStickToTop, KeptMountedFeedBodies, ColorHierarchyRender) that "drew
nothing" / "did not lay out". None touches this branch's code. This is the
Studio flake already recorded (seen 1 in 4 runs in November: the render
tests fail together and pass on an identical re-run). The run above is
that re-run, with nothing changed and nothing rebuilt.

## Gate 2: one live read-only smoke run (at 1ecd407, not repeated)
2026-11-10 23:37–23:38 UTC, same simulator, `touch
wispTests/.fresh_relay_live_enable` then
`-only-testing:wispTests/FreshRelayClientLiveTests`, sentinel removed
afterwards. No key exists in the test. A recording transport wraps the
production socket. **Passed in 4.8 s:**
```
page1 outcome=answered events=30 received=30 rejected=0 short=false
page1 kinds=[1, 30023]
walk pages=21 events=598 lastOutcome=answered lastShort=true rejected=0
belowFloor outcome=floor (not sent)
preview pasta outcome=answered events=5
preview unknown outcome=invalid(reason: "invalid: unknown topic no-such-topic-ios-smoke")
preview unknown again outcome=invalid(reason: "invalid: (refused earlier)") framesSent=0
recipes outcome=answered events=624 rejected=0 oldest=2023-09-27 13:56:38 +0000
tail lost=false
framesSent=51 byPrefix=["[\"REQ\",\"": 26, "[\"CLOSE\"": 25] authChallengesReceived=1
```
This matches the contract section. The 9ef9a0c changes do not alter any
request that run sent: the unknown slug is still remembered (topic slugs
are the one case kept), and the relay answered no feed, recipes or tail
request with `invalid:`. Not re-run, so the live run stays at one.

## Not gated
- A real background suspension on a device: the drop → lost → foreground
  revive path is hermetic only (FakeGroupSocket drop + a private
  NotificationCenter).
- The tail's `auth-required` / `invalid:` handling, `invalid:` on a feed or
  recipes page, and the topic preview's `auth-required` are fixtures: the
  client never sends the requests that provoke them live.
- No red run for the two fixes: the old code remembered `"feed"`,
  `"recipes"` and `"tail"` keys and stored the raw `created_at`, so the
  new tests fail against it by construction, but that was not executed.
- A post delivered more than an hour after its `created_at` is lost on a
  revive; one observation (827 s) set the overlap.
- Retrying a lost tail while the app stays in the foreground (with
  backoff) is ruled for the view-model PR, not here.
