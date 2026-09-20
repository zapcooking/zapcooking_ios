# GATE — concern/longform-articles (#126: mentions as names, summary, headings, tappable body, share/zap row, quoted-article cards)
Stacked on #125 (base branch `concern/nip22-comments`); this GATE.md is
for the three longform commits plus their review fix. Nothing new is
published by this concern; the zap row goes through the existing
`ZapRoute` seam.

**Frozen at this commit.** App code is frozen at **2bc6806**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.
Rebased onto main at 4d89593 (#120). The MacBook Air is the gate machine
until the Mac Studio lands; the box block below is the standard form.
Note: the code hash above is the longform review-fix commit; #125's
GATE.md commit sits between the two concerns in the stack.

## What changed since the last gate run
- Rebased onto the rebased #125 (which is on main 4d89593). No
  conflicts. The `project.pbxproj` diff this PR inherited from #125 is
  gone with #125's file move.
- Copilot review fixes (one commit, six findings):
  `ArticleZapRow` is gated by `ZapGate.postZapVisible()` like every
  other post-level zap surface and opens through `ZapRoute.open` (root
  presenter, wallet-setup prompt on no wallet) instead of a local
  `.sheet` inside the article `LazyVStack`; Share / Copy Link use
  `https://zap.cooking/r/{naddr}`; Share presents on the next runloop
  tick; `ArticleFeedPreview` gains `linked: false` and the quoted
  kind-30023 branch uses it (the outer `articleTapOrNoteButton` already
  is the link); `MarkdownBlocks.profilePubkey` strips `nostr:` in any
  casing. +1 test (mixed-case scheme).

- Re-stacked on #125's re-frozen tip 3b389f9 (its one-line no-op-await warning fix, b6b3b20); this branch's commits are unchanged in content, rebased only.

- Warning fix (2bc6806): the Air's first serial run at 492b382 (1121/2/21 of 1144, baseline pair only) flagged one warning on an added line — `atxHeading`'s new call to `String.trimmingLeadingWhitespace()`, a private extension method that was main-actor-isolated by default and already warned at its pre-existing call site on main. Marked the helper `nonisolated`; both sites are clean. Re-run below.

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at 2bc6806: **1121 passed / 2 failed / 21 skipped / 1144** — exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone; `RecipeComposeViewModelTests` passed in this run and in the 492b382 run). +43 tests over main (+24 over #125's 1120). Zero warnings on lines this branch adds (compiler warning lines intersected with the branch's added hunks). Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial, 530 s of tests.
- pbxproj: no diff (three-dot).
- Gate 4 (by hand): open a long article — the zap row under the byline
  opens the root zap sheet (or the wallet prompt), and disappears when
  `FeatureFlags.zapsOnPosts` is off; Share hands off a zap.cooking/r/
  link; a note quoting an article by nevent shows the card and one tap
  opens the reader once.

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
