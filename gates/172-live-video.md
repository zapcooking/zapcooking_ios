# GATE — fix/llhls-playlist-rewriter (PR #172: LL-HLS rewriter, Live Video feed, review follow-ups)

Branch cut from main at 0eafc5e (2.7). Picked up at **e53a416** (11 Copilot
review fixes written on another machine, never compiled or tested). Three
commits on top, kept apart so each can be cited alone:
- **d66c611**: `HLSPlaylistRewriter` and `HLSPlaylistLoader` are marked
  `nonisolated`. e53a416's message claims this, but the annotation never
  landed. Annotation only, no runtime change.
- **36a5ddd**: `wispTests/LiveStreamReviewTests.swift` (6 tests).
- **d3743c6**: discard `addChatMessage`'s new `Bool` in the chat consumer
  (a warning the PR introduced at `LiveStreamViewModel.swift:123`).

**Code frozen at d3743c6.** This file is the only commit after it, and it
is the HEAD commit. A review fix breaks the freeze: push a fresh gate file
last. No diff to `project.pbxproj`; the one new file is under `wispTests/`.

## Toolchain and destination
Mac Studio, **Xcode 27.2 (27B52)**, Swift 6.4.2 (swiftlang-6.4.2.1.9).
`platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B`
(**iPhone 18 Pro, iOS 27.2**, taken from `-showdestinations`). Every
earlier gate file was Xcode 27.0, so the baseline below was re-run on this
toolchain.

## Gate 1: build
e53a416 as received: **TEST BUILD SUCCEEDED**. No compile errors, so
nothing was changed to make it build. This was effectively a full build
(783 compile steps), and all 15 touched Swift files were recompiled in it:
- `KeptMountedFeedBodies` three-body generics compile, and the two-body
  `init(showOnlyFood:onlyFood:general:)` (an extension where
  `Live == EmptyView`) still serves `FeedStickToTopTests`, which passes.
- The PiP start handshake (`startPictureInPicture(onRestore:onStarted:)`,
  `ManualLivePipDelegate` did-start / failed-to-start) compiles with no
  diagnostics.
- `HLSPlaylistRewriter` was **not** nonisolated (see below).

Warnings on lines the PR touches: **none** (998 added or changed lines
intersected with the build's warnings, both at e53a416 and at d3743c6).
Warning totals, unique `file:line`: 147 at the base, 149 at e53a416.
- `LiveStreamViewModel.swift:123` "result of call to 'run(resultType:body:)'
  is unused": caused by the PR on an untouched line. Fixed in d3743c6; the
  file now has 0 warnings.
- `ShareExtension/ShareViewController.swift:92`: pre-existing. It's in the
  first main build's log; the base log only lacked it because that build
  reused the cached extension.

No lock held across an await: the diff adds no lock of any kind.

**Isolation defect (fixed in d66c611).** Under
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, both HLS types were
MainActor-isolated. But AVFoundation calls the loader on its own
`wisp.hls.playlist-loader` queue, and the `URLSession` completion (a
Sendable closure) mutates `tasks` and calls `rewrite`. Swift 5 mode's
minimal checking hides this from the build. A Swift 6-mode
`swiftc -typecheck` with the target's flags reports it at
`HLSPlaylistLoader.swift:86` and `:93`. After d66c611 the Swift 5 typecheck
is clean. In Swift 6 mode one note remains, not an isolation crossing: the
weak `self` captured into the nested `queue.async` closure (`:86`).

## Gate 2: hermetic suite, serial, compared with the base
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath <dd> -parallel-testing-enabled NO \
  -collect-test-diagnostics never -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```
| tree | passed | failed | skipped | total | verdict (from the .xcresult) |
|---|---|---|---|---|---|
| base 0eafc5e | 1547 | 3 | 22 | 1572 | PASS, known set exactly |
| d3743c6, run 2 | 1558 | 3 | 22 | 1583 | PASS, known set exactly |
| d3743c6, run 3 | 1558 | 3 | 22 | 1583 | PASS, known set exactly |

Failures on both trees: #4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`,
#117 `ColorHierarchyTests/…onTheRawToken_groupChatBubble`, #134
`ColorHierarchyTests/…onTheSixtyPercentWashes`. **No failure is new on this
branch.** 36a5ddd had also passed at the known set (1558/3/22/1583).

**Why the base is 0eafc5e, not main's tip.** `origin/main` (1ab7864) does not
compile on Xcode 27.2: `wisp/Lazarus/LazarusRecovery.swift:220` uses
`URL.percentEncodedPath`, which isn't a member of `URL` in this SDK. It
landed in #169 (078a6c5), after this branch's fork point. That's not this
PR's concern, so it's left alone. The fork point is the tree this PR's diff
applies to.

Test delta, +11 (no result changed on any test present in both runs):
- +6 `LiveStreamReviewTests` (36a5ddd)
- +5 `HLSPlaylistRewriterTests` (the PR's own)
- +1 `FeedTopBarPolishTests/liveVideoKind_rendersTheLiveVideoBody_andTheRestDoesNot`;
  −1 `…/liveRail_rendersOnEveryKind_includingOnlyFood` (the PR removes the rail)

**Transient run, recorded rather than dropped.** d3743c6 run 1 came back
1542/19/22/1583: the known three plus 16 hosted-window or render tests.
Examples: `toolbar_render_idle_and_active_at375` ("toolbar drew nothing"),
`FeedStickToTopTests/viewBuilderSwitch_…` and `…kindSwitch_…`, the Lazarus
`renders…` set, and `sheet_` / `fullScreenCover_rendersTheFlowOnFirstPresentation`.
The same build, re-run twice with no change, passed all 16. The only code
change from the clean 36a5ddd run is d3743c6's `_ =` inside a chat
consumer task, which none of those tests reach. Read it as a simulator
rendering flake, 1 in 4 full runs on this machine. Cause unknown.

## Tests added (`wispTests/LiveStreamReviewTests.swift`, Swift Testing)
- `zapScan_oldReceiptsCountButOnlyRecentOnesAnnounce`: receipts older than
  the oldest loaded chat add to the total without becoming chat rows.
  Receipts at (inclusive) or after it become announcements.
- `zapScan_dedupesAgainstRescansAndTheLiveSubscription`
- `zapScan_fullPageOfOldReceiptsLeavesTheChatBufferAlone` (1,000 receipts)
- `start_doesNothingWhileSwitchIsOff`: no `setCurrent`, no relay resolution.
- `switchOff_clearsDiscoveredStreams`: streams, chat and zap totals cleared,
  current stream dropped, discovery not restarted.
- `switchOn_startsDiscovery_refreshWhileOffDoesNot`

Mutation check: with the `>=` boundary in `addArchivedZaps` changed to
`>`, and the `LiveStreamRepository.shared.clear()` dropped from
`liveContentSettingChanged`, exactly the two intended tests failed (4/2
of 6). Reverted before commit.

**Not tested: needs a seam, so not forced.**
- History paging (a full page that adds nothing doubles the limit, capped
  at 1,000, and the cursor holds) and history exhaustion (ends only on a
  short page after every relay answered; a timeout stays retryable).
  `loadOlderMessages` calls `RelayPool.queryDetailed` directly, and it
  returns early unless the private `started` latch is set, which only a
  real `start()` sets.
- `start()` installing no subscriptions when cancelled between awaits.
  Its awaits are `RelayListRepository` (indexer fetch on a cache miss) and
  `RelayPool.query`, and `subs` is private.

Both need an injectable query/subscribe/relay-resolution seam on
`LiveStreamViewModel`, like `FeedViewModel.StartupServices`.

## Gate 3: on-device Picture-in-Picture (Seth)
PiP can't be shown on the simulator. On a device, play a live HLS stream
(zap.stream) from the Live Video feed.
1. **Start PiP from the stream.** Tap the in-view PiP button. **PASS:** the
   floating window appears and keeps playing, and the stream view pops
   only after that. Tap restore: you're back on the stream, still playing,
   one audio track.
2. **Start PiP before it's possible.** Open a stream and tap PiP the moment
   the player appears (before the first frame). **PASS:** PiP starts within
   about 3 s once playback begins, or nothing happens and the inline view
   stays open and playing. It must not pop to a blank screen or leave a
   silent PiP window.
3. **Failed start leaves the inline view open.** A failed start is hard to
   force on purpose. Try tapping PiP during a FaceTime or phone call, with
   another app's PiP window floating, or with Settings → General →
   Picture in Picture → "Start PiP Automatically" off and PiP restricted by
   Screen Time. **PASS:** no dismissal, inline playback continues, and a
   second tap works once the condition clears. If none of these fails
   the start, record "not reproduced": the failure path (`onFailed` →
   `stopManualPictureInPicture`) is then unverified.
4. **Switch off mid-PiP.** With PiP floating, open Settings → Interface and
   turn off "Show live streams". **PASS:** the PiP window closes, audio
   stops, the Live Video entry leaves the feed menu, and nothing resumes
   when you background and foreground the app.
5. **Second session after restore** (see note 1 below). Start PiP, restore,
   then immediately tap PiP again. **PASS:** the second PiP stays up. If it
   closes by itself, note 1 is the cause.

## Notes found, not fixed (one concern)
1. **PiP `onStopped` is not identity-guarded.** `onFailed` checks that the
   failing controller is still the store's (`manualPipController ===
   controllerRef`); `onStopped` doesn't. Because `stopManualPictureInPicture`
   now calls `stopPictureInPicture()` itself, a superseded session's late
   `didStop` can tear down the newer session, and it can end
   `VideoPiPCoordinator` ownership of an unrelated video PiP. Guarding it
   the same way would change behavior, so it's left for review.
2. **Zap scan with no loaded chat.** `announceFrom` falls back to 0, so
   every archived receipt (up to 1,000) becomes a chat announcement and
   fills the buffer. That's the case the split was meant to prevent.
   Whether it's intended for chat-less streams is a product call.
3. Worst-case paging is six sequential 8 s queries (limit 50 → 1,000)
   while `isLoadingOlder` is set.
4. `HLSPlaylistRewriterTests` (the PR's) indexes `lines[1]` without
   `#require`.
5. `origin/main` doesn't build on Xcode 27.2 (`LazarusRecovery.swift:220`,
   #169). See Gate 2.
