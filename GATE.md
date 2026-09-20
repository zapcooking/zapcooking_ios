# GATE — concern/food-tag-picker (the "+" opens the full food-tag set; selected first; "+N")
UI only: no new event kind, nothing published, no network change, so
§7.13's live-write protocol does not apply. Off main at d5c3698 (#92, with
#93's fixture fix underneath). This is the picker commit that was pushed
to `concern/compose-toolbar` after #92 merged and never landed, cherry-
picked clean. Local build + serial suites on Seth's MacBook Air (the Air
is the gate machine until the Mac Studio lands); the box block below is
the standard form for the Studio.

**Frozen at this commit.** App code is frozen at **c69b544**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

## What landed
- `wisp/FoodTagPickerView.swift` — the sheet behind the row's "+": every
  `FoodHashtags` tag (85), "Popular" (the eight pills) then the rest
  alphabetical, search (leading "#" ignored, case-insensitive, substring),
  empty state. Taps use the row's `toggleSuggestedHashtag` (cap applies).
  Presented from `ComposeView` at medium / large detent after the keyboard
  hop; editor refocused on dismiss.
- `wisp/HashtagSuggestionRow.swift` / `wisp/OnlyFoodCompose.swift` —
  selected food tags first in body order (`rowOrder`), then the
  suggestions that fit, then the "+", which reads "+N" when N selected
  tags are past the cut (`rowLayout` iterates the wider "+N" to a fixed
  point). `HashtagChip` shared by row and picker. Accessibility label
  "More tags, N selected not shown".
- `wispTests/FoodTagPickerTests.swift` — 8 hermetic tests: the set,
  search, row order, a picked tag first, "+N" arithmetic and convergence,
  six selected fitting at 375pt, renders (pinned row, "+N" row, the picker
  in a hosted 375pt window).

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at c69b544: **1019 passed / 1 failed /
  21 skipped / 1041** — the one is #4
  `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`, main's set on
  the Air now that #93 is in. `gate.sh --parse`: PASS. +8 tests over main.
  Warnings in touched files: **zero**.
- A first attempt ran zero tests: the simulator app's tmp held 44 GB of
  the #91 `CFNetworkDownload_*.tmp` leak and the disk was at 3.2 GB free.
  Cleared (app scratch), rerun above.
- Renders written to the dir named in `wispTests/.zc_snapshot_dir`:
  `compose-pills-pinned-375`, `compose-pills-plusN-375`,
  `compose-tag-picker-375`.
- pbxproj: no diff (three-dot). New files are under `wisp/` and `wispTests/`.
- Gate 4 (by hand) is Seth's device pass: the "+" sheet at medium detent
  with the keyboard hop in and back out, a picked tag like #sushi pinning
  first, "+N" once more than fit are selected, chips dimming at the cap,
  and Dynamic Type at a large size (fewer pills fit, "+N" appears sooner).

## Gate 1 — hermetic, serial (Mac Studio / box form)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests
```
Pass = main's failure set on that machine and nothing else (#4, plus the
box's #57 trio); judge the `.xcresult` via `xcresulttool get test-results
summary` (`sh ci_scripts/gate.sh --parse <bundle>`). Expect +8 tests over
main.

## Gate 2 — the compose suites alone
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/FoodTagPickerTests \
  -only-testing:wispTests/ComposeToolbarTests \
  -only-testing:wispTests/OnlyFoodComposeTests
```
Put a directory in `wispTests/.zc_snapshot_dir` first to keep the PNGs.

## Gate 6 — project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Must print nothing.
