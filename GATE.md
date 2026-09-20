# GATE — concern/scroll-lockup (#123: home feed can scroll to the top again)
Two lines of substance in `FeedViewModel` / `MainView`; nothing published,
no network change. Guideline 2.1 exposure, so first in the merge order.

**Frozen at this commit.** App code is frozen at **5bd46b8**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.
Rebased onto main at 4d89593 (#120). The MacBook Air is the gate machine
until the Mac Studio lands; the box block below is the standard form.

## What changed since the last gate run
- Rebased onto main 4d89593. No conflicts, no review threads, code
  unchanged from the gated version (6bce8a1 → 5bd46b8 is the rebase only).

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at 5bd46b8: **1078 passed / 2 failed / 21 skipped / 1101** — exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone). No test delta (no new tests in this concern). Zero warnings on lines this branch adds. Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial. A first run the same hour completed with the same two failures but wrote an empty result bundle because the #91 simulator leak had filled the disk; this is the rerun with a valid bundle.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand) is the real verification: scroll the home feed past the
  new-posts threshold and back to the top, repeat; the top stays reachable;
  the feed mounts at the top after a cold launch.

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
