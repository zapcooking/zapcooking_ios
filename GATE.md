# GATE — issue-6/subscribe-auth @ e744045
Runner: xcodebuild test, iPhone 17 Pro / iOS 26.5, Xcode 26.6, -parallel-testing-enabled NO
Hermetic (-only-testing:wispTests): 599 passed / 4 failed / 11 skipped, 0 fatal errors.
  Failure set IDENTICAL to origin/main on this box:
    FeedRenderableTests/mentionTaggedNoteFollowsReplyGate (#4)
    SafetyTests/notificationDropsReplyInBlockedSubThread
    SafetyTests/notificationIngestZapJudgedByResolvedActor
    SafetyTests/purgeNonWotQualifiedScrubsInMemoryItems (2 issues)
  No failures in new or touched files. +8 GroupRelayAuthTests, all pass.
Live (GroupRelayAuthLiveTests, sentinel .group_auth_live_enable, member key via git-ignored .group_auth_member_nsec, both removed after): 3 passed / 0 failed / 0 skipped
  throwawayKey -> terminal .notMember, 1.71s (F-6: no RTT loop, real relay)
  watchOnly    -> terminal .authUnavailable, no AUTH frame sent, 0.26s
  memberKey    -> AUTH survived + reconnect reordered (REQ->AUTH->AUTH->OK->REQ tail after socket kill), 2.44s
pbxproj: no diff. Guarded files (wallet/zap/RelayConn/Nip98/RecipePublisher): untouched.
