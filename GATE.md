# GATE — concern-3.5/nourish @ d499e65
Runner: xcodebuild test, iPhone 17 Pro / iOS 26.5, Xcode 26.6, -parallel-testing-enabled NO
Hermetic (-only-testing:wispTests): 633 passed / 4 failed / 9 skipped, 0 fatal errors.
  Failure set IDENTICAL to origin/main (98c29c9) on this box:
    FeedRenderableTests/mentionTaggedNoteFollowsReplyGate (#4)
    SafetyTests/notificationDropsReplyInBlockedSubThread
    SafetyTests/notificationIngestZapJudgedByResolvedActor
    SafetyTests/purgeNonWotQualifiedScrubsInMemoryItems (2 issues)
  No failures in new or touched files.
Live canary (NourishLiveTests, sentinel .nourish_live_enable, no key):
  pantryPinnedReq_eoseWithoutAuth -> EOSE received, no AUTH challenge, 2.90s
  (also confirms pantry still serves the pinned public filter unauthenticated)
Read path only; POST /api/nourish compute deferred to build-doc item 15.
pbxproj: no diff.
