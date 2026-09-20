# GATE — concern/color-contrast (PR #132: #117 re-scoped — measure the tiers on the grounds that render; gate.sh KNOWN_FAILURES)
Tests + gate script only. `Themes.swift` is untouched (dark `surfaceVariant`
stays #374151). Nothing published, no network change, so §7.13's live-write
protocol does not apply. Branch cut from main at fe82f6a (#131). The MacBook
Air is the gate machine until the Mac Studio lands; the box block below is
the standard form for the Studio.

**Frozen at this commit.** Code is frozen at **cb26212**. This file is the
only commit after it and is the HEAD commit — `gate.sh` refuses to run
otherwise. A review fix re-opens the freeze: push a fresh gate file last.

First gate file under `gates/` instead of a root `GATE.md`; `ci_scripts/gate.sh`
on this branch finds the one gate file the branch adds (three-dot against
origin/main) and applies the freeze rule to it.

## What changed
- `wispTests/ColorHierarchyTests.swift`: the raw-token contrast test becomes
  three, floors unchanged — rendered grounds (passes), the 60% chip washes
  (fails on purpose, #134), the raw token = group-chat bubble (fails on
  purpose, #117).
- `ci_scripts/gate.sh`: `KNOWN_FAILURES` named constant, one commented entry
  per line with its issue — #4, #117, #134; the box's SafetyTests trio (#57)
  retired; gate file located under `gates/`.

## Gate 1 — build green, hermetic on the Air
Machine: Seth's MacBook Air, Xcode 27.0 (27A266a), iOS 26.2 simulator
(iPhone 17), serial, shared DerivedData. Full `-only-testing:wispTests` at
cb26212: **1185 passed / 3 failed / 21 skipped / 1209 total**. Judged by this
branch's `sh ci_scripts/gate.sh --parse`: **PASS — failure set is exactly the
known set (3/3)**: #4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`,
#117 `ColorHierarchyTests/…onTheRawToken_groupChatBubble`, #134
`ColorHierarchyTests/…onTheSixtyPercentWashes`. Main's clean baseline on this
machine the same day was 1077/3/21 of 1101 (#4, #117 as the old single test,
plus a load flake). +2 tests over main (one test split into three). Zero
warnings in the files this branch touches.

## Gate 2 — ColorHierarchyTests, floors unmodified
`interactiveFloorOnBackground` 4.5, `interactiveFloorOnSurfaces` 3.8,
`linkFloor` 3.0 — the same numbers the old test carried inline. The
rendered-grounds case passes (background 4.73/3.93, surface 3.98/3.40, 25%
4.29/3.62, 30% 4.19/3.57, 40% 4.01/3.42, 30%-in-25%-row 3.87/3.30). The two
failing cases fail at exactly the measured values (3.59 and 3.31/2.88; 2.88/2.53).

## Gate 3 — BrandColorParityTests
Unmodified from main; passes (its #374151 pin holds).

## Gate 4 — BY HAND (Seth's device pass)
No UI change on this branch; nothing to compare. For the record, hermetic
renders of a quoted note and a link preview on the feed background and inside
a surface card at #374151 / #242A35 / #2B2A2E were produced for the decision
(not committed): text identical across the three, card edge 1.72:1 → 1.23:1.

## Gate 5 — project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Prints nothing (verified at cb26212).

## Gate 1 — hermetic, serial (Mac Studio / box form)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests
```
Pass = `sh ci_scripts/gate.sh --parse <bundle>` from THIS branch says PASS
(known set #4, #117, #134 and nothing else). Expect +2 tests over main.

## Gates 2 + 3 — the two colour suites alone
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/ColorHierarchyTests \
  -only-testing:wispTests/BrandColorParityTests
```
Expect exactly two failures, both in the known set.
