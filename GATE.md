# GATE — concern-c-j/dewisp-seed
Concern C-J: de-Wisp every user-visible surface (commit 1) + food-first
sign-up seed (commit 2). Own branch off main at cd36144 (after #59/#60/#61).
Local build only on Seth's MacBook Air; gates run on the MacinCloud box by hand.

**Frozen at this commit.** App code is frozen at **30480f8** (the Copilot
review fix: explicit `@MainActor`, cached seed sanitized on read). The only
commit between 30480f8 and this file is **30d74be** — `ci_scripts/gate.sh` and
`ZAPCOOKING_IOS_BUILD.md` only; `git diff 30480f8 30d74be --stat -- '*.swift'
Info.plist` is empty. This GATE.md is the HEAD commit; `gate.sh` refuses to run
otherwise. The previous gate file (f371c5e) was superseded because a review
fix landed after it — review fixes re-open the freeze.

Why this outranks the parity table: a reviewer opening "Zap Cooking" and reading
"Wisp" in the Photos permission dialog, the share sheet, or an invoice memo
reads as a repackaged app. Cheap to fix, expensive to have raised.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build` (iPhone 17 / OS 26.2): **green** at 30480f8. First attempt hit the
  stale `breez_sdk_sparkFFI` .pcm (main's #60 bumped the SDK under the cached
  module); evicting `SwiftExplicitPrecompiledModules/breez_sdk_sparkFFI-*.pcm`
  and rebuilding is the fix. No project or flag change.
- Warnings in touched files: zero new. The six that print are all on lines
  the branch does not touch and whose blame commit is on origin/main:
  `ShareViewController.swift:92`, `SignUpFlowView.swift:186`,
  `SignUpViewModel.swift:374,619`, `SparkWallet.swift:182,558`.
- Targeted local run of the two new suites only (serial, Air form,
  `-only-testing:wispTests/FoodSeedRepositoryTests -only-testing:wispTests/FoodTopicsTests`),
  2026-09-03: **12 tests in 2 suites passed** (8 + 4; 9 of them new on this
  branch). Proves the new files compile and register via the synchronized
  `wispTests` group. The same log shows `Executed 0 tests` from the XCTest
  portion — the exact line the old gate.sh was reading.
- pbxproj: no diff (three-dot). New files: `wisp/FoodSeedRepository.swift`,
  `wispTests/FoodSeedRepositoryTests.swift`.

## Gate 1 — hermetic, serial (MacinCloud)
First, replace the box script once from this branch (it now judges the
`.xcresult`, fails loudly on a zero total, and refuses a broken freeze or a
wrong checkout):
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout concern-c-j/dewisp-seed && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh concern-c-j/dewisp-seed
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on concern-c-j/dewisp-seed @ <this commit>`, with the four known
failures listed (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`
plus the three `SafetyTests`, issue #57) and no `NEW` line.

**Count.** This branch has **731** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main has 722; the delta is the
**+9** new tests (`FoodSeedRepositoryTests` 8, `FoodTopicsTests` +1). The
earlier run reported 701/4/16 = 721 total, which is main's count minus one and
this branch's minus ten, and 721 is exactly the declaration count of
`concern-c-e/cheffy` at 95e3715. Before trusting any number, judge the bundle
that run actually wrote — xcodebuild always writes one under DerivedData even
without `-resultBundlePath`:
```sh
~/gate.sh --parse "$(ls -td ~/Library/Developer/Xcode/DerivedData/wisp-*/Logs/Test/*.xcresult | head -1)"
grep -c 'FoodSeedRepositoryTests' ~/gate-concern-c-j-dewisp-seed.log   # >0 if the new suite ran
git -C ~/Development/zapcooking_ios log -1 --format='%h %D'             # what tree that run was on
```
If the parsed total is 721 the run was on a stale tree; the new script's
branch assertion makes that a hard stop. No live sentinel — the curator
kind-3 fetch is live and is not exercised by the hermetic run.

## Gate 2 — zero user-facing "Wisp"; internal identifiers untouched
```sh
# user-facing string literals — must print nothing
grep -rn '"[^"]*Wisp[^"]*"' --include='*.swift' --include='*.plist' . \
  | grep -v 'wispTests\|wispUITests\|Notification.Name\|wisp.xcodeproj'
grep -rn 'Image("WispLogo")' --include='*.swift' . | grep -v Tests
grep -n 'Wisp' Info.plist ShareExtension/Info.plist
# internal identifiers — must still be present, unchanged
grep -rl '"com.wisp.nostr"' --include='*.swift' . | grep -v Tests   # NostrKey, WalletKeychain, KeychainBackupService, AppDataWipe
grep -n '"wisp-spark-wallet-v1"' SparkWallet.swift
grep -n '<string>wisp</string>' Info.plist            # wisp://share handoff scheme
```
Expected: the first three greps are empty; the last three hit. The full
internal list (target/scheme/module `wisp`, `com.wisp.nostr`,
`com.wisp.apple-backup`, `wisp_accounts`, `wisp_settings_*`, `wisp.emoji.state.*`,
`wisp_bk_`, `wisp-google-backup`/`wisp-apple-backup`/`wisp-spark-wallet-v1`
salts, `Application Support/wisp`, `model-wisp.json`,
`EntityInfo-wisp.generated.swift`, `wisp_avatars`/`wisp_emojis`,
`wisp-profile://`/`wisp-note://`/`wisp-hashtag://`/`wisp-group://`/`wisp://share`,
`Notification.Name` constants, `wisp-apple-*` sub ids, `wisp-out-` temp
prefix, `wispLinkURL`/`wispMentionPill`, `WispPillLayoutManager`,
`wisp_sendAction`, `Color.wisp*`, `WispTopHeader`) is enumerated in the PR body.

## Gate 3 — photo-library permission dialog (simulator, by hand, screenshot)
Fresh install (or Settings ▸ Privacy ▸ Photos ▸ reset), signed in.
1. Open any post with an image. Tap the image → fullscreen viewer → tap the
   save icon (`square.and.arrow.down`, bottom bar), or long-press an inline
   image → **Save to Photos**.
2. iOS shows the add-only Photos prompt. Title names **"Zap Cooking"**; the
   body line is exactly
   `Zap Cooking saves images and videos from posts to your Photos library.`
3. Screenshot it. Deny once and confirm the in-app alert reads
   "Allow Zap Cooking to add to Photos in Settings to save images."

## Gate 4 — fresh sign-up seeds food, not bitcoin (simulator, by hand)
Splash → **Create new account** → profile step → Continue.
1. Step "Follow cooks & creators", subtitle "Follow at least 5 accounts to
   fill your feed with food". Section **Meet the creators** / "Chefs and cooks
   curated by Zap Cooking": a horizontally scrolling row, **Zap Cooking first
   and pre-selected**, followed by the curator account's follows (cap 24),
   each labelled "Food creator". If the kind-3 fetch fails the row still shows
   the Zap Cooking card alone (fallback profile). Section **Active in the
   kitchen** / "N people posting about food". **No "News sources" section.**
2. Step "What do you like to cook?" / "Pick a few food topics so your feed is
   full of the dishes you love." Ten emoji-titled sections from `FoodTopics`
   (🍽️ Why are you cooking? … 🌐 Beyond food, with its note). No "Popular
   topics", no trending fetch, no #nostr / #bitcoin / #memes chips outside the
   opt-in "Beyond food" section. Typing in the search field suggests taxonomy
   hashtags; a custom word still adds via the + button.
3. Pick ≥1 topic, Continue. Profile ▸ Hashtag Sets shows an "Interests" set
   with the normalized hashtags (e.g. Gluten Free → `#glutenfree`).
4. Intro step body reads "…how you found Zap Cooking is plenty."

## Gate 5 — the eight brand surfaces (simulator, by hand)
Each shows the Zap Cooking mark (orange disc, white bolt), never the mascot:
1. Loading screen after launch (96pt).
2. Drawer footer: "Zap Cooking v1.x" beside a 16pt mark at 30% opacity.
3. Existing-user onboarding "Welcome back" (import an nsec) (96pt).
4. Auth header on the Apple sign-in / PIN screens (96pt, shadowed).
5. Add-account login sheet (drawer ▸ switcher ▸ add) (LoginView).
6. Settings ▸ Keys ▸ QR: centre badge when the account has no avatar.
7. Drawer ▸ QR (profile): centre badge, no-avatar account.
8. Wallet ▸ Receive / lightning-address QR: centre badge, no-avatar account.
Known cosmetic gap to eyeball, not a stop: the mark's white magnifier ring
and handle only show on dark grounds; on the white QR centres and the
light-theme drawer footer it reads as disc + bolt. Seth decides on device
whether a ring-free variant is worth producing.

## Gate 6 — pbxproj (three-dot)
```sh
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Expected: empty.

## Results
Gate 1 first run (old script, before this file): reported 701 / 4 / 16 with
the four known failures, script printed 0/0/0 — see the Count note above;
rerun with the new script. Gates 2–6 pending — recorded in the PR
description after Seth's run.
