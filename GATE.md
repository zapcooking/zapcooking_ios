# GATE — concern/small-correctness-batch (#129: NIP-05 _@domain, mute copy, onboarding skip, following count, contacts retry, untrimmed nsec)
Seventeen files, small and independent; nothing published by the tests.
Last in the merge order on purpose: it absorbs the line-level overlap
with #125 (`ProfileTabs` / `ProfileView` / `ProfileViewModel`) and #128
(`PostCardView`); the dry-run merge in order is clean.

**Frozen at this commit.** App code is frozen at **5ebd7ea**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.
Rebased onto main at 4d89593 (#120). The MacBook Air is the gate machine
until the Mac Studio lands; the box block below is the standard form.

## What changed since the last gate run
- Rebased onto main 4d89593. No conflicts.
- Copilot review fix (one commit): the contacts retry keys off a real
  miss — `loadContacts` found no kind-3 while the target's write relays
  were still unknown — instead of `followingPubkeys.isEmpty`, which was
  also true for a genuinely empty contact list and cost every such
  profile a second 10-second timeout before `start()` completed. No test
  delta (the retry is a live relay path).

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at 5ebd7ea: **1084 passed / 2 failed / 21 skipped / 1107** — exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone; `RecipeComposeViewModelTests` passed in this run). +6 tests over main. Zero warnings on lines this branch adds (compiler warning lines intersected with the branch's added hunks). Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial, 579 s of tests.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand): a profile with an empty contact list finishes
  loading without a 10 s tail; a profile whose kind-3 lives only on its
  own write relays shows a non-zero following count; `_@domain` NIP-05
  renders as the bare domain; the onboarding follow step can be skipped;
  an nsec pasted with surrounding whitespace adds the account.

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
