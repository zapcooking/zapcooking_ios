# GATE — concern-3.2/my-kitchen @ 5ef2a8f
Runner: xcodebuild test, iPhone 17 Pro / iOS 26.5, Xcode 26.6, -only-testing:wispTests, -parallel-testing-enabled NO
Hermetic: 563 tests / 5 issues — failure set IDENTICAL to origin/main 28a8d34 on this box:
  FeedRenderableTests/mentionTaggedNoteFollowsReplyGate (#4)
  SafetyTests/notificationDropsReplyInBlockedSubThread
  SafetyTests/notificationIngestZapJudgedByResolvedActor
  SafetyTests/purgeNonWotQualifiedScrubsInMemoryItems (2 issues)
No failures in new or touched files. +23 tests vs main.
Live (MyKitchenLiveTests, sentinel wispTests/.my_kitchen_live_enable, removed after):
  publish 1.54s -> appeared in Published 1.36s -> delete accepted on nos.lol, relay.primal.net, relay.nostr.net -> gone 2.06s
  total 5.77s; cleanup confirmed=true; d-tag ios-3.2-my-kitchen-1788223759, throwaway key
pbxproj: no diff.
