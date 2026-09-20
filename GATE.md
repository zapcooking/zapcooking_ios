# GATE — concern/hashtag-routes (#124: hashtag taps work on every tab)
`MainView` only: four stacks gain the `HashtagFeedRoute` destination and
a real `onHashtagTap`; nothing published, no network change.

**Frozen at this commit.** App code is frozen at **2294056**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.
Rebased onto main at 4d89593 (#120). The MacBook Air is the gate machine
until the Mac Studio lands; the box block below is the standard form.

## What changed since the last gate run
- Rebased onto main 4d89593. No conflicts, no review threads, code
  unchanged from the gated version (d47ac85 → 2294056 is the rebase only).

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at 2294056: **1078 passed / 2 failed / 21 skipped / 1101** — exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone). No test delta. Zero warnings on lines this branch adds. Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand): open a profile from Recipes / Kitchen / Search /
  Notifications, tap a hashtag in a note, the hashtag feed pushes on that
  tab; a hashtag inside the hashtag feed pushes on the same stack;
  back-swipe returns to the profile, not Home.

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
