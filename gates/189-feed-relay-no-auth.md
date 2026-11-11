# GATE — concern/feed-relay-no-auth (PR #189: never answer NIP-42 AUTH from the feed relay)

Branch rebased onto main at 2cfd059 (#190). **Code frozen at 0208d39.** This
file is the only commit after it, and it is the HEAD commit. A review fix
breaks the freeze: push a fresh gate file last.

Fresh feed PR 1. No test opens a socket or publishes anything; the branch
adds no network calls.

## What was wrong
`wss://feed.zap.cooking` gives everyone the last 14 days and a logged-in
Cook+ member the full history. It sends its NIP-42 challenge on connect and
again before every `CLOSED auth-required:` (probed 2026-11-10). The shared
pool (`RelayPool.respondToAuthChallenge`), the group pool and Lazarus each
signed whatever challenge they were handed, so opening that relay as a relay
feed logged the user in: a paid unlock on iOS (Guideline 2.1(b), #177).

## The fix
- `FeatureFlags.swift`: `feedRelayLoginEnabled = false`.
- `Nip42.swift`: `loginAllowed(relayUrl:)` reads the flag;
  `buildAuthEvent` throws `AuthError.loginDisabled` when it says no. The
  three user-key signing paths all call it (`MainView.swift:265`,
  `GroupRelayPool.swift:583`, `wisp/Lazarus/LazarusRelayClient.swift:101`)
  and already treat a throw as "no AUTH sent".
- `wisp/FeedRelay.swift` (new): the URL and the host match.
- `wispTests/FeedRelayNoAuthTests.swift` (new): 12 tests, including the
  tripwire that no app source other than `Nip42.swift` names kind 22242.

`RelayPool.swift` is untouched. No `project.pbxproj` diff
(`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty).

## Gate 1: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.2 (27B52), iPhone 18 Pro on iOS 27.2
(`90B23E20-BA47-4AD0-98EF-175513626A4B`), at 0208d39: **TEST BUILD
SUCCEEDED**, no warnings in any file the branch touches.
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath pr1b.xcresult
sh ci_scripts/gate.sh --parse pr1b.xcresult
```
```
gate: 1658 passed / 3 failed / 22 skipped / 1683 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3)
```
`FeedRelayNoAuthTests` passed (12 tests).

**No local patch.** This run is the branch as pushed. The first gate
(b16bb6b, before #190) needed an uncommitted one-line fix to compile on
Xcode 27.2; #190 put that fix on main and this run replaces that one. Same
counts as before.

## Not gated
- `RelayPool.respondToAuthChallenge` takes a real `URLSessionWebSocketTask`
  and is not driven hermetically; the tests cover the signer it calls.
- No live run against the relay: proving a refusal live would need a member
  key on a socket that then declines to use it. The frame behaviour this
  defends against is recorded in the Phase 0 probe.
- Accepted limit: paging the feed relay as a relay feed past 14 days waits
  for the timeout (`RelayConn` swallows `CLOSED auth-required`).

## Overlap with #183
`Nip42.buildAuthEvent` becomes `async` there (about three lines against
the guard here; the tests need `try await` after it). The tripwire flags
`Nip46.swift:87` and `:263` on that branch: allow-list the file and call
`Nip42.loginAllowed` in `transportAuthEvent`.
