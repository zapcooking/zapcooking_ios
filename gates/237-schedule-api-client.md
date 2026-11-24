# Gate 237: ScheduleApi client (scheduled posts 1/3)

Branch `concern/schedule-api-client`, cut from main at f4133dc.
**Code frozen at 6dee7f0.** This file is the only commit after it, and it is
the HEAD commit. A review fix breaks the freeze: push a fresh gate file last.

Changes: new `wisp/ScheduleApi.swift`, new `wispTests/ScheduleApiTests.swift`,
new `wispTests/ScheduleLiveTests.swift`, one line in `.gitignore`
(`wispTests/.schedule_live_enable`). Nothing calls the client yet; no screen
changes, so no screenshots.
**pbxproj:** `git diff origin/main...HEAD -- wisp.xcodeproj` is empty.

## Toolchain and destination
Mac Studio, Xcode 27.2 (27B52),
`platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B`
(iPhone 18 Pro, iOS 27.2), pre-booted with `ci_scripts/preboot-sim.sh`.

```
xcodebuild build-for-testing -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -skipPackagePluginValidation -derivedDataPath <dd>
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath <dd> -parallel-testing-enabled NO \
  -collect-test-diagnostics never -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```

## Results

| | passed | failed | skipped | total |
|---|---|---|---|---|
| Baseline, main f4133dc | 2023 | 4 | 23 | 2050 |
| Branch, 6dee7f0 | 2075 | 4 | 24 | 2103 |
| Difference | +52 | 0 | +1 | +53 |

The +1 skipped is the live suite, off by default.

**Failures are the same four on both.** Three are the known set (#4
`FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`, #117 and #134 in
`ColorHierarchyTests`). The fourth is
`BlockInstantHideTests/thread_swapsBlockedRepliesForThePlaceholder`
(`BlockInstantHideTests.swift:163`). It fails on main at f4133dc, fails again
when the suite runs alone, and this branch touches nothing it uses. It is not
in `KNOWN_FAILURES`, so `gate.sh --parse` prints FAIL for main and for this
branch alike. It has no issue yet.

| gate | result |
|---|---|
| Build | TEST BUILD SUCCEEDED; no warning in a new file |
| New suites alone | `ScheduleApiRelayTests`, `ScheduleApiSignTests`, `ScheduleApiRequestTests`, `ScheduleFailureCodeTests`: all pass |
| Live check | `ScheduleLiveTests/scheduleListCancel_neverPosts` passed against zap.cooking with the sentinel present, once, 2026-11-24 |
| pbxproj | no diff |

Warnings: the baseline build was cold (177 unique `file:line` sites); the
branch build was incremental, so its total is not comparable. The two new
source files and the new test files produce none.

## The live check
Run once with a throwaway key, then the sentinel was removed:

1. Signed a kind-1 note with `created_at` two hours out; `POST` returned 201,
   `pending`.
2. `POST` again with the same signed event returned `already_scheduled`,
   `pending`, read as success.
3. `GET ?status=pending` listed it with the same id and signature.
4. `DELETE` returned `cancelled`.
5. `GET ?status=cancelled` listed it as cancelled with no `sent_at`;
   `GET ?status=pending` no longer did.
6. A second `DELETE` read as already cancelled; a third `POST` of the same
   event was refused as `already_scheduled`, `cancelled`.

Nothing was published to any relay.

## Not covered here
- No signer app was exercised. The remote-signer path is covered by a fake
  through `Signer.remoteSigningOverrides`.
- `pickRelays` is a hand port of a WHATWG-URL-based check onto
  `URLComponents`. It is at least as strict on every case tested; a URL with
  dot segments in its path (`/a/../b`) is normalized by the server and not by
  this client, which can only cost a duplicate, never a rejection.
