# Gate 241: the Scheduled list reads and cancels through /api/schedule (scheduled posts 3/3)

Branch `concern/schedule-list`, **stacked on #239** (`concern/schedule-compose`
at 5f91768; #239 was still open when this was cut). The PR's base is that
branch, so its diff is this work only.
**Code frozen at b5ea94f.** This file is the only commit after it, and it is
the HEAD commit. A review fix breaks the freeze: push a fresh gate file last.

Changes: `DraftsViewModel.swift`, `DraftsScheduledView.swift`,
`wisp/wispApp.swift` (one DEBUG harness branch), new `wisp/ScheduledPosts.swift`,
new `wisp/ScheduledListHarness.swift` (DEBUG), new
`wispTests/ScheduledListTests.swift`, new
`wispUITests/ScheduledListScreenshotsUITests.swift`, five screenshots in
`docs/screenshots/scheduled/`, `README.md`, `ZAPCOOKING_IOS_BUILD.md`.
**pbxproj:** `git diff origin/main...HEAD -- wisp.xcodeproj` is empty.
**Scheduler relay:** no reference to `schedulerRelay` or
`scheduler.nostrarchives.com` remains in any Swift file or in the README. The
build doc names the old relay once, to say it is gone.

## Toolchain and destination
Mac Studio, Xcode 27.2 (27B52),
`platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B`
(iPhone 18 Pro, iOS 27.2), pre-booted with `ci_scripts/preboot-sim.sh`.
Same commands as `gates/237-schedule-api-client.md`.

## Results

| | passed | failed | skipped | total |
|---|---|---|---|---|
| Baseline, #239 at ede3c74 | 2106 | 4 | 24 | 2134 |
| Branch, b5ea94f, run 1 | 2131 | 5 | 24 | 2160 |
| Branch, b5ea94f, run 2 (identical re-run) | 2132 | 4 | 24 | 2160 |
| Difference from baseline (run 2) | +26 | 0 | 0 | +26 |

**Run 2's failures are the baseline's four:** the known set (#4, #117, #134)
and `BlockInstantHideTests/thread_swapsBlockedRepliesForThePlaceholder`
(issue #238, fails on main, not in `KNOWN_FAILURES`, so `gate.sh --parse`
prints FAIL for main and every branch in this series).

**Run 1 had a fifth failure that run 2 did not:**
`FreshSpecialsListTests` "paging: a post row's position counts posts, not the
cards above it" (`FreshSpecialsListTests.swift:281`, `cards(rig.vm)` empty
after its wait). The log shows a 1650 ms main-thread stall
(`[main-stall] MAIN STALL 1650ms … richtext.sizeThatFits`) immediately before
it; run 1 logged 8 such stalls and run 2 logged 4. The branch touches nothing
that test uses. It passed in run 2 and in the four earlier full runs of this
series. Recorded here as a one-off; it was not investigated further.

| gate | result |
|---|---|
| Build | TEST BUILD SUCCEEDED; with every touched file recompiled, no warning in any of them |
| New and schedule suites alone | `ScheduledListTests`, `ScheduleApiRequestTests`: all pass |
| UI screenshots | `ScheduledListScreenshotsUITests` 3/3 pass |
| pbxproj | no diff |

The live suite (`ScheduleLiveTests`) was not run for this branch: the sentinel
is absent and the request code it covers is unchanged from #237.

## Screenshots
`docs/screenshots/scheduled/`, from the real `DraftsScheduledView` over a
scripted scheduler (`-ScheduledListHarness`, DEBUG), in the app's theme:

- `scheduled-list-kinds.png`: note with a picture, poll with its options,
  picture post, reply, video; soonest first, each with status and time.
- `scheduled-list-failed.png`: the failed post under "Didn't post", plain
  explanation, the server's text as detail, no cancel button.
- `scheduled-cancel-too-late.png`: cancelling a post that already went out:
  the notice, and the reloaded list without it.
- `scheduled-empty.png`, `scheduled-empty-after-pull.png`: the empty list, and
  the same list after a pull brought in a post.

Picture thumbnails are placeholders: the harness URLs do not resolve.

## Not covered here
- No request left the simulator. Listing and cancelling against zap.cooking,
  and the cross-client checks (schedule in the app, see it on the web;
  schedule on the web, cancel in the app), are the by-hand list in the PR
  thread.
- editor-matrix does not apply: this PR does not touch a composer.
- A failed post cannot be dismissed from the list; the API has no call for it.
