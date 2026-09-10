# GATE — fix/article-action-bar-zap
Zapping from a recipe (TestFlight 2.1 (2)) opened the wallet sheet and cycled
open/closed. `ArticleActionBar` hosted `ZapSheet` locally; the keyboard the sheet
raises tore the presenting lazy row down (the 2026-06-07 PostCardView diagnosis).
The bar now routes through `ZapRoute` → `ComposePresenter` → MainView's root
`.sheet(item:)`, and guards `store.mode != nil` (no wallet → setup prompt, never
an empty sheet). Own branch off main at d71868e. Local build only on Seth's
MacBook Air; gates run on the MacinCloud box by hand. This GATE.md replaces PR 7's.

**Frozen at this commit.** App code is frozen at **35c5e47**. This GATE.md is the
only commit after it and is the HEAD commit — `gate.sh` refuses to run otherwise.
A review fix re-opens the freeze: push a fresh GATE.md last.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2): **green** at 35c5e47 (one build, 2026-09-10; `wisp` + `wispTests` compiled, `** TEST BUILD SUCCEEDED **`). Free disk
  15.3 GB before, 14.3 GB after — below the 15 GB floor, so no second build was run; the total warning count (697 lines, all pre-existing Swift 6 diagnostics elsewhere) was not re-baselined against a main build.
- Warnings in touched files (`PostCardView.swift`, `ProfileView.swift`,
  `wisp/ArticleView.swift`, `wisp/RecipeDetailView.swift`, `wisp/ZapRoute.swift`,
  `wispTests/ZapRouteTests.swift`): **zero**.
- pbxproj: no diff (three-dot, `git diff origin/main...HEAD --stat -- wisp.xcodeproj`
  empty). New files `wisp/ZapRoute.swift`, `wispTests/ZapRouteTests.swift` are
  self-registering.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout fix/article-action-bar-zap && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh fix/article-action-bar-zap
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on fix/article-action-bar-zap @ <this commit>`, with the four known
failures (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the
three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **832** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 824; the delta is **+8**
(`ZapRouteTests` 8). If the parsed total is 824 the run was on a stale tree.

## Gate 2 — the brief's three hermetic gates (subset of Gate 1; name-check the bundle)
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)" \
  | grep -E 'ZapRouteTests|ZapGateTests|RecipeSaveToggleTests'
```
- ZapSheet's route is the app-root host for both PostCardView and ArticleActionBar:
  `open_withWallet_handsTheRequestToTheRootHost`,
  `postCardAndArticleBar_useTheRootRoute_notALocalSheet`,
  `zapSheet_isConstructedOnlyByTheRootHost_andAuditedScreenLevelHosts` (source
  scan from `#filePath`; needs the checkout at its compile path — true on the box).
- no-wallet shows the setup prompt, not an empty sheet:
  `open_withoutWallet_promptsSetup_andPresentsNothing`,
  `walletReady_needsAStoreWithAConfiguredMode`.
- watch-only cannot reach the zap control from a recipe:
  `recipeEngagementBar_watchOnly_isBookmarkOnly`.
- gating unchanged: every `ZapGateTests` case still passes.

## Gate 3 — MANUAL on device (TestFlight build from this branch)
With a wallet configured (Spark or NWC), zap from each of the five surfaces. Each
must open a usable sheet that stays open (keyboard up, amount editable, no flicker):
1. a recipe (Recipes tab → recipe detail → bolt in the engagement bar)
2. a feed post (bolt on a kind-1 card)
3. a long-form article (feed → article → bolt)
4. a profile (bolt in the header, and the lightning-address row)
5. a live stream (host zap in the info bar, and a chat-message zap)
Then with NO wallet configured: recipe and feed-post bolts show the
"Set up a wallet to send zaps" prompt; "Set Up Wallet" lands on the Wallet tab.
Then signed in watch-only (npub): recipe detail shows the bookmark-only bar; no bolt.

## Gate 4 — pbxproj
`git diff origin/main...HEAD --stat -- wisp.xcodeproj` → empty.

## Results
Pending — recorded in the PR description after Seth's run.
