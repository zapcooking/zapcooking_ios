# GATE — ci/render-flake-preboot (PR #208: pre-boot the simulator, name the scene-less host state; issue #207)

Branched from main at 8f0c2d8 (#205). **Code frozen at 6ec56d0.** This file
is the only commit after it, and it is the HEAD commit. A review fix breaks
the freeze: push a fresh gate file last.

CI and test only: `ci_scripts/preboot-sim.sh` (new), `ci_scripts/gate.sh`
(pre-boot step when `GATE_DEST` names `id=`, `--parse` HINT, header note),
`wispTests/HostSceneProbeTests.swift` (new, 1 test). No production code. No
`project.pbxproj` diff (`git diff origin/main...HEAD --stat --
wisp.xcodeproj` is empty).

## Gate 1: build green, no new warnings in touched files
Mac Studio, Xcode 27.2 (27B52), at 6ec56d0: **TEST BUILD SUCCEEDED**,
`HostSceneProbeTests.swift` 0 warnings. `sh -n` clean on both scripts.

## Gate 2: hermetic at the known set, serial, pre-booted
iPhone 18 Pro on iOS 27.2 (`90B23E20-BA47-4AD0-98EF-175513626A4B`), run
under the session's simulator lock:
```
sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-flake \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath gate208.xcresult
sh ci_scripts/gate.sh --parse gate208.xcresult
```
```
preboot: 90B23E20-BA47-4AD0-98EF-175513626A4B booted, SpringBoard 95951 stable for 15s
gate: 1788 passed / 3 failed / 23 skipped / 1814 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1814 tests ran
```
`HostSceneProbeTests` passed. First run, no re-run. **No local patch.** The
gate simulator is left booted (that is the mitigation).

## Gate 3: the fix does what it claims (clone simulator `flake-sim`)
- Reproduction: SIGABRT to the clone's SpringBoard after the run starts →
  3/3 runs with every LazarusRenderTests case `!isBlank(image)` at
  `LazarusRenderTests.swift:76` and FeedStickToTop "did not lay out"; the
  probe, placed after other suites, failed 2/2 with its message, and
  `gate.sh --parse` on that bundle printed the HINT.
- Pre-booted: 5/5 full runs passed, simulator stayed booted, no new
  SpringBoard crash reports. Cold-booted: 1/10 failed, matched by a
  SpringBoard crash report (#207).

## Not gated
- The gate runner path of `gate.sh <branch>` (MacinCloud form) was not run;
  only `--parse` and the script it calls.
- Why the poster-snapshot crash started recurring on 2026-11-10, and whether
  `simctl erase` or a newer runtime stops it.
- The forced reproduction leaves 5 extra SpringBoard crash reports in
  `~/Library/Logs/DiagnosticReports` (20:5x–21:1x): those are the kills.
