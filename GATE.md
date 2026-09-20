# GATE — concern/deleted-quote-placeholder (#118: a deleted quoted note gets its own placeholder, #101)
Rebased onto main at fe82f6a (#131) — the PR's `CONFLICTING` on GitHub was
its head sitting on the old #116 base; the rebase is clean. `QuoteGraph.swift`
moved under `wisp/` so the synchronized folder registers it (the PR's
`project.pbxproj` entry is gone; three-dot pbxproj diff is empty). Reads only
add a small on-demand kind-5 query per unrenderable quote; nothing is
published, so §7.13's live-write protocol does not apply. The MacBook Air is
the gate machine until the Mac Studio lands; the box block below is the
standard form for the Studio.

**Frozen at this commit.** App code is frozen at **d175f08**. This GATE.md is
the only commit after it and is the HEAD commit — `gate.sh` refuses to run
otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

## What changed since the teammate's last run (PR body's "Verification")
- Copilot review, all three findings fixed (d175f08): `Nip09.deletedEventIds`
  applies the author-hint rule and skips empty ids; `DeletionTracker.ingestBatch`
  builds the id set and the signer map from that one helper; `QuoteGraph`
  keeps every `q` tag of a note (`quotes(by:)`, old single-edge storage
  still loads). +3 tests.
- Zero warnings on the PR's added lines: `Nip09.deletionFilter` is
  `@MainActor` like `NostrFilter` and awaited from the check task;
  `DeletionTracker.check` locks through a sync `withLock` helper;
  `DeletionTests` is `@MainActor`.

## Local (MacBook Air, Xcode 27.0 27A266a, iOS 26.2 sim, iPhone 17, serial, shared DerivedData)
- Full serial `-only-testing:wispTests` at d175f08: **1207 passed / 2 failed / 21 skipped / 1230** — the two are exactly the Air's clean-main set (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; PR #132 re-scopes #117 and is gated separately). +21 tests over main's 1209. Zero warnings on lines this branch adds.
- The three suites alone (DeletionTests, QuoteGraphTests, QuoteOutboxTests):
  31/31 passed; zero warnings in touched files. Wall time is inflated by the
  host app's main-thread stalls under load (the suites are `@MainActor`), not
  by the code.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand) is Seth's device pass, unchanged from the PR body: quote a
  note, delete the quoted note elsewhere, the card reads "Note deleted by its
  author" within a few seconds — not the safety or not-found card.

## Gate 1 — hermetic, serial (Mac Studio / box form)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests
```
Pass = main's failure set on that machine and nothing else; judge the
`.xcresult` via `sh ci_scripts/gate.sh --parse <bundle>`. Expect +20 tests
over main (17 from the PR, 3 from the review fixes).

## Gate 2 — the concern's suites alone
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/DeletionTests \
  -only-testing:wispTests/QuoteGraphTests \
  -only-testing:wispTests/QuoteOutboxTests \
  -only-testing:wispTests/SafetyTests
```

## Gate 6 — project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Must print nothing.
