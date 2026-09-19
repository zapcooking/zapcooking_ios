# GATE — concern/cheffy-empty-states
The last Wisp mascot illustration out of the app. C-J moved the eight `WispLogo`
sites to `ZcLogo`; the thread view's "No replies yet" empty state used a
different asset, `NoReplies.imageset` (a dashed Wisp-flame outline, eff92c6),
which that grep could not see. It now draws `CheffyIcon` in the **neutral**
expression at 64 pt through a small `NoRepliesEmptyState` view; both Wisp
imagesets (`NoReplies`, the dead `WispLogo`) are deleted from the catalog. The
sweep of every other empty, placeholder and error state found SF Symbols,
emoji (🍳 📖) and text only — nothing Wisp — so nothing else changes. Own
branch off main at 7c56d93 (2.1 (3)). Local build only on Seth's MacBook Air;
gates run on the MacinCloud box by hand.

**Frozen at this commit.** App code is frozen at **f587687** (c9459c5 plus the Copilot
review fix: the test's colour-to-RGB helper now fails the test instead of reading
black when conversion fails). The previous GATE.md (0280dd9) is superseded. This
GATE.md is the only commit after it and is the HEAD commit — `gate.sh` refuses to run
otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at f587687 and at c9459c5.
  Four builds this session (2026-09-19): the first failed on two compile errors in
  the new test file (a `Comment` wrapper, a `nonisolated` helper); the second was
  green; the incremental `xcodebuild test` builds behind the serial runs below,
  including the one for the review fix, were green. Free disk 15 GB before and after; one transient dip
  to 8.9 GB while the simulator booted, back to 17 GB within a minute; no local
  Time Machine snapshots.
- Warnings in touched files (`wisp/ThreadView.swift`, `wisp/NoRepliesEmptyState.swift`,
  `wispTests/EmptyStateGroundTests.swift`): **zero**. Incremental totals were 402 and 436 lines, all pre-existing
  Swift 6 diagnostics elsewhere (not comparable to the 538-line full-build baseline).
- Serial single-suite run on the Air (the C-G exception form,
  `test-without-building -parallel-testing-enabled NO -only-testing:wispTests/EmptyStateGroundTests`):
  **3/3 pass** at f587687 (and at c9459c5; 1.9 s of test time on the warm run). The run
  also wrote PNGs of the empty state on the default theme's dark and light grounds and
  on Srcery light (the softest face-vs-ground of the 30): neutral face, toque in the
  theme primary, bolt accent, "No replies yet" in tertiary — all readable on each.
- pbxproj: no diff (three-dot, `git diff origin/main...HEAD --stat -- wisp.xcodeproj`
  empty). New files `wisp/NoRepliesEmptyState.swift` and
  `wispTests/EmptyStateGroundTests.swift` are self-registering; the imageset
  deletions are inside the `Assets.xcassets` folder reference.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout concern/cheffy-empty-states && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh concern/cheffy-empty-states
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on concern/cheffy-empty-states @ <this commit>`, with the four known
failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the three
`SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **842** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 839; the delta is **+3**
(`EmptyStateGroundTests` 3). If the parsed total is 839 the run was on a stale tree.

**Rendering on the box.** All three new tests draw through `ImageRenderer` in the
hosted app process (the `FeedTopBarPolishTests/cheffyButton_rendersAtThe44ptTarget`
pattern) and read pixels back; none opens a window or a socket.

## Gate 2 — the brief's hermetic gates (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'EmptyStateGroundTests|CheffyTests'
```
- no Wisp illustration asset in the built app (`NoReplies`, `WispLogo` both absent;
  `ZcLogo` present): `builtApp_carriesNoWispIllustrationAsset`
- the thread empty state is Cheffy, neutral, 64 pt, and its hat (theme primary)
  and ink both land on the canvas on light and dark grounds:
  `noRepliesEmptyState_drawsNeutralCheffy_onLightAndDarkGround`
- the C-J ground check, measured: on all 15 presets × light/dark, Cheffy's face
  sits ≥ 30/255 off the ground, the hat ≥ 60, the ink ≥ 90 off the face
  (softest face-vs-ground is Srcery light at 34): `cheffy_readsOnEveryThemeGround_lightAndDark`
- `CheffyTests` (the SVG parser and copy pools behind `CheffyIcon`): unchanged, all pass.

## Gate 3 — BY HAND on device: four empty states, screenshot each
Light and dark once each (Interface → theme); every state below is a
dead end, so none should show an excited face and none should show the Wisp flame.
1. **Thread, no replies**: open any note with no replies (a fresh post of your own
   is the quickest). Under the focal: Cheffy, neutral face, 64 pt, "No replies yet"
   in tertiary. The face, toque and eyes all read on the ground; there is no ring
   or handle to vanish.
2. **Notifications, empty**: fresh or watch-only account → bell-slash symbol,
   "No notifications". Unchanged; confirms no Wisp there.
3. **DMs, empty**: Messages with no conversations → double-bubble symbol,
   "No messages yet". Unchanged.
4. **OnlyFood, genuine empty** (relay reachable, nothing accepted — e.g. WoT on
   with a fresh graph): 🍳, "No food posts yet". And the relay-miss copy
   ("Couldn't reach the food feed") with the network off. Both unchanged.
Optional fifth: My Kitchen → Saved with no bookmarks → 📖, "Start saving recipes".

## Gate 4 — grep: no Wisp illustration asset referenced
```sh
git grep -nE 'Image\("(NoReplies|WispLogo)"|WispLogo|wisp_logo|no_replies|NoReplies\.imageset' -- . ':!GATE.md'
```
Expect exactly two hits, neither an image reference: the doc comment in
`wisp/NoRepliesEmptyState.swift` naming the deleted asset and C-J's sweep, and the
`["NoReplies", "WispLogo"]` literal in `wispTests/EmptyStateGroundTests.swift` (the
test that asserts both are absent from the bundle). No `Image("…")` hit.
```sh
ls wisp/Assets.xcassets
```
Expect no `NoReplies.imageset`, no `WispLogo.imageset`.

## Gate 5 — pbxproj
`git diff origin/main...HEAD --stat -- wisp.xcodeproj` → empty.

## Results
Pending — recorded in the PR description after Seth's run.
