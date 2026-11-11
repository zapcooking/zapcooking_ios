# Gate 204: remote-signer created_at tests + LocalizedError for signer errors

Branch `fix/signer-remote-tests`, cut from main at b680867 (#183 merged).
**Code frozen at a6da426.** This file is the only commit after it, and it is
the HEAD commit. A review fix breaks the freeze: push a fresh gate file last.

Changes: `Signer.swift` (remote lookup returns `any RemoteSigning`; DEBUG-only
`remoteSigningOverrides`), new `wisp/RemoteSigning.swift`, new
`wisp/SignerErrorDescriptions.swift`, new
`wispTests/RemoteSignerCreatedAtTests.swift` (4 tests).
**Gate 6:** `git diff origin/main...HEAD -- wisp.xcodeproj` is empty.

## Toolchain and destination
Mac Studio, Xcode 27.2 (27B52),
`platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B`
(iPhone 18 Pro, iOS 27.2).

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

## Results at a6da426

| gate | result |
|---|---|
| Build | TEST BUILD SUCCEEDED; 154 unique `file:line` warnings, **none** in a touched file |
| Hermetic, serial | **1668 passed / 3 failed / 22 skipped / 1693 total: PASS** |
| Failures | exactly the known set: #4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`, #117 `ColorHierarchyTests/…onTheRawToken_groupChatBubble`, #134 `ColorHierarchyTests/…onTheSixtyPercentWashes` |
| New suite | `RemoteSignerCreatedAtTests` 4/4 pass |
| Gate 6 (pbxproj) | no diff |

**The regression test catches the bug.** With `Signer.swift` temporarily set
back to the pre-c2e39ba comparison (`event.createdAt == createdAt`), the suite
alone fails only `signsWithNoCreatedAtPassed`. The other three pass. The line
was restored before the commit.

The first build attempt failed on a stale `breez_sdk_sparkFFI` `.pcm` in a
reused DerivedData (main's #199 bumped the Breez SDK). Deleting that `.pcm`
and rebuilding cleared it. The failure was environmental: no code or flag
changed.
