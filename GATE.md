# GATE — concern/draft-survives-rejected-publish (#122: keep the draft on rejection / stopped mining)
Composer + `PostPublisher` + `PostStatusPill`; nothing new is published,
the tests drive an offline publish path (the `127.0.0.1` noise in the log
is that test doing its job).

**Frozen at this commit.** App code is frozen at **7094523**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.
Rebased onto main at 4d89593 (#120). The MacBook Air is the gate machine
until the Mac Studio lands; the box block below is the standard form.

## What changed since the last gate run
- Rebased onto main 4d89593. No conflicts.
- Copilot audit fixes (7094523, three findings that arrived 2026-09-20):
  `retry()` restarts the optimistic feed row via `PendingPostStore.start`
  (a stopped post had no row on retry; a failed one stayed `.failed` while
  the retry mined); `clearAutosaveIfStillThisDraft` compares the whole
  autosave property list, not just `content`, so a newer draft with the
  same body but different settings survives a late success; the pill's
  icon-only dismiss button has an accessibility label. +1 test
  (`successKeepsADraftWithTheSameBodyButDifferentSettings`).
- Merge-order note: #121 lands before this one and touches the same two
  compose files in different regions; a dry-run merge of both in order
  is clean.

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at 7094523: **1088 passed / 2 failed / 21 skipped / 1111** — exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone; `RecipeComposeViewModelTests` passed in this run). +10 tests over main (9 from the concern, 1 from the review fix). Zero warnings on lines this branch adds. Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial, 616 s of tests.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand): publish with every relay unreachable (airplane mode
  after the sheet dismisses) — the pill shows Retry and stays until
  acknowledged; reopen the composer, the text is back; tap Retry and the
  feed's pending row reappears and follows the attempt. Stop a long PoW
  run — same. VoiceOver reads the pill's X as "Dismiss".

## Gate 1 — hermetic, serial (Mac Studio / box form)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests
```
Pass = main's failure set on that machine and nothing else; judge the
`.xcresult` via `sh ci_scripts/gate.sh --parse <bundle>`.

## Gate 6 — project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Must print nothing.
