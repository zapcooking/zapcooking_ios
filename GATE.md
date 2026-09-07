# GATE — concern-1/dead-relay-10002
Concern 1 / issue #1: a dead relay can be signed into a user's published
kind-10002. Part A (prune at ingest + probed fallback, commit 9ed6517) and
Part B (one-time republish, commit 8351ed7) as separate commits in one PR,
plus the build-doc correction (bbf7978). Own branch off main at aa9a688 (#62).
Local build only on Seth's MacBook Air; gates run on the MacinCloud box by hand.

**Frozen at this commit.** App code is frozen at **bbf7978**; this GATE.md is
the only commit after it and is the HEAD commit — `gate.sh` refuses to run
otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

Headline finding, so the reviewer is not surprised by an empty set:
`relay.damus.io` is **live** (websocat probe 2026-09-07 17:07 UTC, fresh
events + EOSE, strfry 1.1.0). `RelayDefaults.decommissioned` ships **empty**;
the structural fix is the probed fallback path, which needs no list.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at 8351ed7 (bbf7978 is
  doc-only: `git diff 8351ed7 bbf7978 --stat -- '*.swift' Info.plist` is empty).
- Warnings in touched files: **zero new**. `RelaySettingsRepository.swift:475`
  (`result of call to 'run(resultType:body:)' is unused`) is main's `:454`,
  shifted by the Part B insertions; its blame is on origin/main.
  `SignUpViewModel.swift:374,625` are the same two main warnings C-J recorded.
- Targeted serial run, 2026-09-07, `-only-testing:wispTests/RelayDecommissionTests
  -only-testing:wispTests/RelayListRepairTests -only-testing:wispTests/RelaySettingsTests`:
  **29 tests in 3 suites passed** (10 + 12 + 7; 22 of them new). The live suite
  registers but is `.enabled(if:)`-skipped without its opt-in file.
- pbxproj: no diff (three-dot). New files, all self-registering:
  `wisp/RelayDecommission.swift`, `wisp/RelayListRepair.swift`,
  `wispTests/RelayDecommissionTests.swift`, `wispTests/RelayListRepairTests.swift`,
  `wispTests/RelayListRepairLiveTests.swift`.
- Disk: the Air's Data volume hit 327 MB free mid-run (ENOSPC lines in the
  test log; one result bundle failed to save while the tests themselves
  passed). Cause was 2.6 GB of `CFNetworkDownload_*` under the test host's
  simulator container `tmp/`; removed that only. Not a branch issue, but the
  box run should be judged from its `.xcresult`, as `gate.sh` does.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout concern-1/dead-relay-10002 && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh concern-1/dead-relay-10002
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on concern-1/dead-relay-10002 @ <this commit>`, with the four known
failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the
three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **754** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 731; the delta is the
**+23** new tests (`RelayDecommissionTests` 10, `RelayListRepairTests` 12,
`RelayListRepairLiveTests` 1, skipped without opt-in). If the parsed total is
731 the run was on a stale tree — the script's branch assertion is a hard stop.

## Gate 2 — unit coverage (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'RelayDecommissionTests|RelayListRepairTests'
```
Required cases, each must be present and passing:
- prune on the fallback path: `probedFallback_publishesOnlyPassers_inConstantOrder`,
  `probedFallback_neverProbesDecommissioned_andCanReturnEmpty`
- prune on a harvested list: `proberCandidates_dropDecommissionedFromHarvest`
- preserve user-added relays and read/write markers:
  `pruneTags_removesOnlyDeadRelayTags_byteForByte`,
  `republish_removesOnlyDead_preservesMarkersOrderForeignTags`
- idempotent republish: `idempotent_secondRunIsMarkerNoOp_andClearedMarkerFindsNothingToRemove`,
  `setVersionChange_rerunsExactlyOnce`
- no-op when clean: `noOp_whenListIsClean_burnsMarkerWithoutSigning`,
  `emptySet_settlesCleanWithoutFetching`
- watch-only skips: `watchOnly_skipsEverything_andLeavesMarkerUnset`

## Gate 3 — LIVE per §7.13 (MacinCloud; writes a kind-10002 to production)
Ephemeral key, never printed or persisted; `RelayDefaults.defaults`
(primal / nos.lol / nostr.net); publish → verify → repair → verify → two
no-op reruns → kind-5 (`e`×2 + `k`) → re-query until gone; the key is held
until the re-query is empty. The "dead" host is `wss://decommissioned-probe.invalid`
injected through `RelayListRepair.Environment` — the production set is not
touched and no real relay is named dead. **A hang or timeout is a leak, not a
test to retry with a fresh key**; rerun the same invocation so the cleanup
path executes.
```sh
cd /Users/user301940/Development/zapcooking_ios
touch wispTests/.relay_repair_live_enable
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/RelayListRepairLiveTests
rm -f wispTests/.relay_repair_live_enable
```
Expected in the log, in order: `seedAccepted=[…]` non-empty;
`outcome=republished(removed: ["wss://decommissioned-probe.invalid"])`;
no expectation failure on `user relays / markers / order not preserved`;
`second run must not republish` holds; `deleteAccepted=[…]` non-empty;
`leftoverAfterDelete=[]`; `cleanup confirmed=true`. Typical wall-clock is
under a minute against defaults (the 3.1 indexer-union hang does not apply;
this gate never targets indexers).

## Gate 4 — pbxproj (three-dot)
```sh
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Expected: empty.

## Results
Gates 1–4 pending — recorded in the PR description after Seth's run.
