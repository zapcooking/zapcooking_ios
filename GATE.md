# GATE — concern/compose-toolbar (shield out, action glyphs, Publish says why, one row of pills)
UI + one preference default: no new event kind, nothing published, no
network change, so §7.13's live-write protocol does not apply. Off main at
0cbe1ca (#90). Local build + serial suites on Seth's MacBook Air (the Air
is the gate machine until the Mac Studio lands); the box block below is
the standard form for the Studio.

**Frozen at this commit.** App code is frozen at **9ee955d**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

## What landed
- `ComposeView.swift` / `wisp/ComposeActionsRow.swift` — the toolbar is
  its own view: photos, paste, GIF, sensitive (`eye.slash` /
  `eye.slash.fill`, NIP-36 tag unchanged), poll, private reply, schedule
  (`calendar` / `calendar.badge.checkmark`). The Proof of Work shield is
  gone. Publish shows `publishBlocker` when greyed.
- `ComposeViewModel.swift` — `publishBlocker` (mirrors `validate()`,
  including uploads in flight), `canPublish == (publishBlocker == nil)`,
  `togglePow` removed, autosave no longer carries `powEnabled`.
- `PowPreferences.swift` — note PoW default **off** (reactions / DMs
  unchanged); `Keys` made `nonisolated` (clears six pre-existing warnings).
- `wisp/HashtagSuggestionRow.swift` / `wisp/OnlyFoodCompose.swift` — one
  row, no wrap, no scroll: the pills that fit (measured via
  `HashtagPillMetrics`, `OnlyFoodCompose.visiblePillCount`) then a "+"
  pill wired to state that presents nothing yet. Outlined unselected,
  filled orange selected, dimmed at the cap.
- `wispTests/ComposeToolbarTests.swift` — 16 hermetic tests incl. 375pt
  renders (pills none / one / cap via ImageRenderer; toolbar idle / active
  and the whole composer via a hosted 375pt window).

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2, shared DerivedData,
  `-skipPackagePluginValidation`): **green**. Warnings in touched files:
  **zero** (the six `PowPreferences.swift` "main actor-isolated static
  property" warnings that main carries are gone with `nonisolated Keys`).
- `ComposeToolbarTests` serial: **16/16**. With `OnlyFoodComposeTests` +
  `ComposeSeedTests`: 37/37.
- Full serial `-only-testing:wispTests`: **1007 passed / 4 failed / 21
  skipped / 1032** — the four are exactly main's Air set: #4
  `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the three
  #88 structural-cap fixtures (`OnlyFoodIngestParityTests` ×2,
  `OnlyFoodOwnPublishTests` ×1), which are fixed on their own branch
  (`fix/onlyfood-cap-fixtures`, 26/26 in those two suites with the patch
  applied here). Nothing new. +16 tests over main.
- Renders written to the dir named in `wispTests/.zc_snapshot_dir`:
  `compose-pills-{none,one,cap}-375`, `compose-toolbar-{idle,active}-375`,
  `compose-sheet-empty-375`.
- pbxproj: no diff (three-dot). New files are under `wisp/` and `wispTests/`.
- Gate 4 (by hand) is Seth's device pass: OnlyFood composer at the
  smallest width (pills: four + "+", selected orange only), text / gallery
  / poll / reply composers (glyphs, no shield, Publish reason in each
  empty state, "Wait for uploads to finish." during an upload), the
  sensitive banner, a scheduled post (calendar badge), and Settings →
  Proof of Work showing notes off on an untouched install.

## Gate 1 — hermetic, serial (Mac Studio / box form)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests
```
Pass = main's failure set on that machine and nothing else; judge the
`.xcresult` via `xcresulttool get test-results summary`
(`sh ci_scripts/gate.sh --parse <bundle>`). Expect +16 tests over main.
Until `fix/onlyfood-cap-fixtures` merges, main's set includes the three
#88 tests; after it, #4 alone (plus the box's #57 trio).

## Gate 2 — the compose suites alone
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/ComposeToolbarTests \
  -only-testing:wispTests/OnlyFoodComposeTests \
  -only-testing:wispTests/ComposeSeedTests
```
Put a directory in `wispTests/.zc_snapshot_dir` first to keep the PNGs.

## Gate 6 — project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Must print nothing.
