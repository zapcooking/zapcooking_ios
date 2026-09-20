# GATE — concern/compose-correctness (#121: trailing blank lines, npub-in-URL, relay cap)
Publish-path changes (what a note's body and a poll's relay tags contain)
but no new kind and nothing published by the tests; the live check is
the device pass below.

**Frozen at this commit.** App code is frozen at **9e1ea47**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.
Rebased onto main at 4d89593 (#120). The MacBook Air is the gate machine
until the Mac Studio lands; the box block below is the standard form.

## What changed since the last gate run
- Rebased onto main 4d89593. No conflicts.
- Copilot review fixes (9e1ea47): `RelayUrlValidator.isValid` now
  requires a dotted host, so `wss://https//relay…` (host `https`) is
  rejected instead of taking one of the five slots — a shared-validator
  change (relay settings, scoreboard, ingest), noted here on purpose. The
  filter-then-cap moved into `ComposeViewModel.capWriteRelays(_:)`
  (nonisolated static, cap in `nonisolated static maxAdvertisedRelays`) so
  `ComposeRelayCapTests` pins the 480-tag regression hermetically.
  +4 tests (3 cap, 1 validator). A first gate run at the previous fix
  commit was green on tests but showed one new warning on the cap constant
  (main-actor static referenced from the nonisolated helper); this is the
  re-freeze after marking it `nonisolated`.

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at 9e1ea47: **1091 passed / 2 failed / 21 skipped / 1114** — exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone). +13 tests over main (9 from the concern, 4 from the review fix). Zero warnings on lines this branch adds (a first run at the previous fix commit had one, on the cap constant; fixed and re-run). Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand): publish a kind-1068 poll on an account with a
  populated scoreboard and confirm ≤5 `relay` tags; paste a Blossom URL
  with an npub subdomain and confirm the preview and the published note
  keep the URL intact; a note typed with trailing newlines publishes
  without them.

## Gate 1 — hermetic, serial (Mac Studio / box form)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests
```
Pass = main's failure set on that machine and nothing else; judge the
`.xcresult` via `sh ci_scripts/gate.sh --parse <bundle>`.

## Gate 6 — project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Must print nothing.
