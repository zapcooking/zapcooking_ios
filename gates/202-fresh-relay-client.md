# GATE — fresh/relay-client (PR #202: FreshRelayClient, the feed relay's own read-only connection)

Branched from main at b1140bc (#199). **Code frozen at 1ecd407.** This file
is the only commit after it, and it is the HEAD commit. A review fix breaks
the freeze: push a fresh gate file last.

Fresh feed PR 2. Nothing in the app calls the client yet. No hermetic test
opens a socket. The one live test is opt-in and read-only.

## Gate 1: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.2 (27B52), iPhone 18 Pro on iOS 27.2
(`90B23E20-BA47-4AD0-98EF-175513626A4B`), at 1ecd407: **TEST BUILD
SUCCEEDED**, no warnings in any file the branch touches (the three new
Swift files; the other warning sites are main's, checked against a b1140bc
build log).
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-fresh-client \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath fc-gate.xcresult
sh ci_scripts/gate.sh --parse fc-gate.xcresult
```
```
gate: 1688 passed / 3 failed / 23 skipped / 1714 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1714 tests ran
```
`FreshRelayClientTests` passed (28 tests). `FreshRelayClientLiveTests/smoke`
was skipped (the 23rd skip; no sentinel file). **No local patch.** No
`project.pbxproj` diff (`git diff origin/main...HEAD --stat -- wisp.xcodeproj`
is empty).

## Gate 2: one live read-only smoke run
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
This matches the contract section. The window was 598 events over 21 pages
(616 / 22 on probe day). The last page was short. The relay sent one AUTH
challenge on connect and the client ignored it. An unknown slug got
`invalid:` and was not asked again. Recipes went back to 2023-09 (620 on
probe day). All 1,222 events received verified, none rejected, so the iOS
id serialization agrees with the relay's events. Every frame sent was
`REQ` or `CLOSE`; the one `REQ` without a `CLOSE` is the unknown slug, which
the relay closed itself.

## Not gated
- A real background suspension on a device: the drop → lost → foreground
  revive path is hermetic only (FakeGroupSocket drop + a private
  NotificationCenter).
- The tail's `auth-required` / `invalid:` handling, and the topic
  preview's `auth-required`, are fixtures: the client never sends the
  requests that provoke them live.
- A post delivered more than an hour after its `created_at` is lost on a
  revive; one observation (827 s) set the overlap.
