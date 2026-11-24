# Gate 239: the composer schedules through /api/schedule (scheduled posts 2/3)

Branch `concern/schedule-compose`, **stacked on #237**
(`concern/schedule-api-client` at 8c53f28; #237 was still open when this was
cut). The PR's base is that branch, so its diff is this work only.
**Code frozen at 2b6f2d9.** This file is the only commit after it, and it is
the HEAD commit. A review fix breaks the freeze: push a fresh gate file last.

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
| Baseline, #237 at 6dee7f0 | 2075 | 4 | 24 | 2103 |
| Branch, 2b6f2d9 | 2103 | 4 | 24 | 2131 |
| Difference | +28 | 0 | 0 | +28 |

**Failures are the same four on both:** the known set (#4, #117, #134) and
`BlockInstantHideTests/thread_swapsBlockedRepliesForThePlaceholder`, which
fails on main and is issue #238. It is not in `KNOWN_FAILURES`, so
`gate.sh --parse` prints FAIL for main, #237 and this branch alike.

| gate | result |
|---|---|
| Build | TEST BUILD SUCCEEDED; with every touched file recompiled, no warning in any of them |
| New and schedule suites alone | `ScheduleComposeTests`, `ScheduleApiRequestTests`, `ScheduleApiSignTests`, `ScheduleApiRelayTests`: all pass |
| UI screenshots | `ComposerScheduleScreenshotsUITests` 3/3 pass |
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
- **editor-matrix was not run.** AGENTS.md asks for it before and after a
  composer change; this repository has no runner yet. The change does not
  touch how text is edited or built into `content`.
- No request left the simulator: scheduling from the composer against
  zap.cooking, and with a real signer app, is the by-hand list in the PR
  thread.
- The failure copy is tested as strings and as `lastError`; how each one looks
  on screen is the existing red `lastError` line, unchanged.
