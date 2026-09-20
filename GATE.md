# GATE — concern/nip22-comments (#125: NIP-22 comments — ingest, render, publish kind 1111, profile tab)
Introduces a published kind (1111, only as a reply to an externally-rooted
comment). The hermetic suites cover kind selection and tag shape
(`ComposeReplyKindTests`, `Nip22CommentTests`); §7.13's live write is
Seth's device pass below.

**Frozen at this commit.** App code is frozen at **b6b3b20**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.
Rebased onto main at 4d89593 (#120). The MacBook Air is the gate machine
until the Mac Studio lands; the box block below is the standard form.

## What changed since the last gate run
- Rebased onto main 4d89593. Two conflicts with main's NIP-09 deletion
  PR (#116), both the same shape — each side added a kind to the same
  list — resolved as the union: `EventStore.persistedKinds` gains 5 and
  1111; `ThreadViewModel`'s reply subscription asks for kinds
  [1, 5, 1111] and keeps the deletion intercept ahead of the reply guard.
- `Nip22.swift` moved from the repo root to `wisp/Nip22.swift` (own
  commit) so the synchronized folder registers it; the
  `project.pbxproj` diff is gone.
- Copilot review fixes (one commit): `CommentsTabView` uses
  `FeedEventNavigationLink` and triggers `MediaLookaheadPrefetcher` like
  the other list tabs; the `nip22ReplyTags` doc no longer says "computed
  once"; the `Nip22` header says the app composes kind 1111 and names
  `ExternalRef` correctly. No test delta.

- Warning fix (b6b3b20): the Air's first serial run at 9d4aac3 (1097/2/21 of 1120, baseline pair only) flagged one warning on an added line — `await self?.flushCommentsPending()` in `ProfileViewModel.enqueueComment`, a no-op await on a synchronous MainActor method. Dropped the `await`; re-run below.

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at b6b3b20: **1097 passed / 2 failed / 21 skipped / 1120** — exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone; `RecipeComposeViewModelTests` passed in this run and in the 9d4aac3 run). +19 tests over main. Zero warnings on lines this branch adds (verified by intersecting the compiler's warning lines with the branch's added hunks). Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial, 490 s of tests.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand): open a profile with NIP-22 comments → Comments tab
  lists them with the source page card on top-level ones; reply to one
  → the published event is kind 1111 with `I`/`K` root tags (check in
  another client); a kind-1 reply to a normal note is unchanged.

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
