# GATE — concern/polls-zap-comments (#128: poll duration presets, tally leak, image-only zap comments)
Composer + `PostCardView` details drawer + `ContentParser.splitImages`;
nothing published by the tests.

**Frozen at this commit.** App code is frozen at **476cf69**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.
Rebased onto main at 4d89593 (#120). The MacBook Air is the gate machine
until the Mac Studio lands; the box block below is the standard form.

## What changed since the last gate run
- Rebased onto main 4d89593. No conflicts. Merge-order note: #119 lands
  first and rewrites `ContentParser` passes 5/6; this PR's
  `splitImages` is a separate section and the dry-run merge is clean.
- Copilot review fixes (one commit): the poll duration choice (preset /
  ∞ / custom date) moved from `PollOptionsEditor` `@State` to
  `ComposeViewModel` (`pollDurationPreset`, `pollDurationIsCustom`,
  `pollCustomEndDate`) because the editor is torn down whenever the poll
  is toggled off; `onAppear` stamps the one-day default only for a fresh
  composer. `splitImages` removes the trailing punctuation the parser
  trimmed off the URL token along with the URL. +3 tests
  (`PollDurationStateTests` ×2, `ZapCommentImageTests` +1).

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at 476cf69: **1090 passed / 2 failed / 21 skipped / 1113** — exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone; `RecipeComposeViewModelTests` passed in this run). +12 tests over main. Zero warnings on lines this branch adds (compiler warning lines intersected with the branch's added hunks). Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial, 793 s of tests.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand): in the composer pick ∞ (or 7d), toggle the poll off
  and on — the choice is still selected; the preview shows the caption
  above the options; a poll whose body hides results keeps them hidden
  in the details drawer; a zap comment that is only an image URL shows
  the image in the drawer and `[image]` on the pill.

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
