# Gate 239: the composer schedules through /api/schedule (scheduled posts 2/3)

Branch `concern/schedule-compose`. Cut stacked on #237; #237 has since merged
(main e66dd9f) and main is merged into this branch, so the PR's base is `main`
and its diff is this work only.
**Code frozen at ede3c74** (the merge of main; the last code commit is 40d840c,
the review fix below). This file is the only commit after it, and it is the
HEAD commit. A review fix breaks the freeze: push a fresh gate file last.

**Review fix (40d840c):** a scheduled post's toast said "Posted". It now says
"Scheduled for <time>", in the same toast. The wording moved from
`ComposeView` to `ComposeViewModel.publishToastMessage` so it is tested; posts
sent now keep "Posted", "Poll posted", "Reply sent", "Quote posted".

Changes: `ComposeViewModel.swift`, `ComposeView.swift`, `ScheduleSheet.swift`,
`PollOptionsEditor.swift`, `wisp/ComposerDragHarness.swift` (two DEBUG launch
arguments), new `wisp/ScheduleSubmitter.swift`, new
`wispTests/ScheduleComposeTests.swift`, new
`wispUITests/ComposerScheduleScreenshotsUITests.swift`, three screenshots in
`docs/screenshots/composer/`.
**pbxproj:** `git diff origin/main...HEAD -- wisp.xcodeproj` is empty.

## Toolchain and destination
Mac Studio, Xcode 27.2 (27B52),
`platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B`
(iPhone 18 Pro, iOS 27.2), pre-booted with `ci_scripts/preboot-sim.sh`.
Same commands as `gates/237-schedule-api-client.md`.

## Results

| | passed | failed | skipped | total |
|---|---|---|---|---|
| Baseline, #237 at 6dee7f0 (= main e66dd9f) | 2075 | 4 | 24 | 2103 |
| Branch as first gated, 2b6f2d9 | 2103 | 4 | 24 | 2131 |
| Branch, ede3c74 | 2106 | 4 | 24 | 2134 |
| Difference from baseline | +31 | 0 | 0 | +31 |

The +3 since the first gate are the toast tests.

**Failures are the same four on both:** the known set (#4, #117, #134) and
`BlockInstantHideTests/thread_swapsBlockedRepliesForThePlaceholder`, which
fails on main and is issue #238. It is not in `KNOWN_FAILURES`, so
`gate.sh --parse` prints FAIL for main, #237 and this branch alike.

| gate | result |
|---|---|
| Build | TEST BUILD SUCCEEDED; with every touched file recompiled, no warning in any of them |
| New and schedule suites alone | `ScheduleComposeTests`, `ScheduleApiRequestTests`, `ScheduleApiSignTests`, `ScheduleApiRelayTests`: all pass |
| UI screenshots | `ComposerScheduleScreenshotsUITests` 3/3 pass at 2b6f2d9; not re-shot, the fix changes a toast's words only and no captured screen |
| pbxproj | no diff |

The live suite (`ScheduleLiveTests`) was not run for this branch: the sentinel
is absent and the request code it covers is unchanged from #237.

## Screenshots
`docs/screenshots/composer/`, from the real composer in the DEBUG harness:

- `composer-schedule-picker-limits.png`: the sheet at full height, days before
  today disabled, the limits line under the time row.
- `composer-schedule-time-passed.png`: a restored draft whose saved time was an
  hour ago; the notice, and no "Scheduled for" banner.
- `composer-schedule-poll-ends.png`: a one-day poll scheduled three days out;
  "Ends" is one day after the scheduled time.

## Not covered here
- **editor-matrix: waived for this PR (Seth, 2026-11-24).** AGENTS.md asks for
  it before and after a composer change. The reason for the waiver: the diff
  does not change how content or tags are built, apart from the poll close
  time, which has its own tests (`ScheduleComposeTests`, the poll section).
  This repository has no runner yet; issue #240 is open for writing it so the
  rule can be met in future.
- No request left the simulator: scheduling from the composer against
  zap.cooking, and with a real signer app, is the by-hand list in the PR
  thread.
- The failure copy is tested as strings and as `lastError`; how each one looks
  on screen is the existing red `lastError` line, unchanged.
