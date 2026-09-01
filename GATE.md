# GATE — fix/3.1b-hidden-unsave @ 34a44b4
Runner: xcodebuild test, iPhone 17 Pro / iOS 26.5, Xcode 26.6, -only-testing:wispTests, -parallel-testing-enabled NO
Hermetic: 602 tests / 5 issues — failure set IDENTICAL to main's known set:
  FeedRenderableTests/mentionTaggedNoteFollowsReplyGate (#4)
  SafetyTests/notificationDropsReplyInBlockedSubThread
  SafetyTests/notificationIngestZapJudgedByResolvedActor
  SafetyTests/purgeNonWotQualifiedScrubsInMemoryItems (2 issues)
RecipeSaveToggleTests/toggle_hiddenCoordinate_alreadySaved_unsaves: now PASSES (failed on main 19f3ee4 with process crash). Fatal errors in log: 0.
Live (RecipeSaveToggleLiveTests, sentinel wispTests/.save_toggle_live_enable, removed after): passed 1 / skipped 0 — first ever run of this gate.
SaveToggle live: afterSave=["30023:112d2d16d2aa419ce92f00566ef4dd2ec0ed152cc23fb7f9cfdcd353d59f5fbf:ios-3.1b-save-1788272585"] in 1.172969102859497s
SaveToggle live: afterUnsave=[] in 0.7539730072021484s
SaveToggle live: deleteAccepted=["wss://relay.primal.net", "wss://nos.lol", "wss://relay.nostr.net"]
SaveToggle live: leftoverAfterDelete=[]
SaveToggle live: delete-and-gone in 2.1497089862823486s
SaveToggle live: total 6.09230899810791s; cleanup confirmed=true
pbxproj: no diff.
