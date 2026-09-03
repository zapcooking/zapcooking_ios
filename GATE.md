# GATE — concern-c-j/dewisp-seed
Concern C-J: de-Wisp every user-visible surface (commit 1) + food-first
sign-up seed (commit 2). Own branch off main at cd36144 (after #59/#60/#61).
Local build only on Seth's MacBook Air; gates run on the MacinCloud box by hand.
Frozen at "ready for gates"; results go in the PR description.

Why this outranks the parity table: a reviewer opening "Zap Cooking" and reading
"Wisp" in the Photos permission dialog, the share sheet, or an invoice memo
reads as a repackaged app. Cheap to fix, expensive to have raised.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build` (iPhone 17 / OS 26.2): **green** at commit 2. First attempt hit the
  stale `breez_sdk_sparkFFI` .pcm (main's #60 bumped the SDK under the cached
  module); evicting `SwiftExplicitPrecompiledModules/breez_sdk_sparkFFI-*.pcm`
  and rebuilding is the fix. No project or flag change.
- Warnings in touched files: zero new. The six that print are all on lines
  the branch does not touch and whose blame commit is on origin/main:
  `ShareViewController.swift:92`, `SignUpFlowView.swift:186`,
  `SignUpViewModel.swift:374,619`, `SparkWallet.swift:182,558`.
- pbxproj: no diff. New files: `wisp/FoodSeedRepository.swift`,
  `wispTests/FoodSeedRepositoryTests.swift`.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin
~/gate.sh concern-c-j/dewisp-seed
```
Expected: main's failure set exactly (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`
plus the three `SafetyTests`, issue #57) and **+9 new passes**:
`FoodSeedRepositoryTests` (8), `FoodTopicsTests/allHashtags_isNormalized_dedupedAndCoversEverySection` (1).
(Was +7 at the gate commit; the Copilot review added two cache-sanitizing tests.)
No live sentinel — the curator kind-3 fetch is live and is not exercised by
the hermetic run.

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
Expected: the first three greps are empty; the last two hit. The full
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
Pending — recorded in the PR description after Seth's run.
