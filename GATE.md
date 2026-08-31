# GATE — concern-0.7b/compute-client @ ff3dcf8
Runner: xcodebuild test, iPhone 17 Pro / iOS 26.5, Xcode 26.6, -only-testing:wispTests, -parallel-testing-enabled NO
Result: 540 tests, 5 issues — failure set IDENTICAL to origin/main 28a8d34 run serially on this box in the same worktree:
  FeedRenderableTests/mentionTaggedNoteFollowsReplyGate (#4)
  SafetyTests/notificationDropsReplyInBlockedSubThread
  SafetyTests/notificationIngestZapJudgedByResolvedActor
  SafetyTests/purgeNonWotQualifiedScrubsInMemoryItems (2 issues)
HttpClientFactoryTests: 4/4 pass
Branch introduces no new failures. The three SafetyTests are a baseline drift from the documented 529/1 (see issue).
Parallel run of the same branch failed 2 additional SafetyTests — nondeterministic under clones.
Live gate: n/a
