# GATE — concern-c-g/compliance @ c9e5907
Concern C-G: Phase 4 compliance surface — 4.3 in-app policy links, 4.5 export
compliance key, 4.8 kill-switch verification (`ZapGate`), 4.2 investigated only.
Local build only on Seth's MacBook Air; gates run on the MacinCloud box by hand.
Frozen at "ready for gates"; results go in the PR description.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build` (iPhone 17 / OS 26.2): green, flag `true` (shipped) and flag `false`
  (flip demonstration, reverted before commit).
- Warnings in touched files: zero new. `LiveStreamView.swift:284` ("captured
  var self") is byte-identical on origin/main and above every C-G edit.
- Step 0 (serial hermetic from this primary checkout, existing DerivedData):
  680 tests / 77 suites, 1 failure = #4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`.
  All of `SafetyTests` passed, including the three box failures and the local
  #43 one.
- pbxproj: no diff. New files: `wisp/ZapGate.swift`, `wisp/AboutView.swift`,
  `wispTests/ZapGateTests.swift`, `wispTests/PolicyLinksTests.swift`.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin
~/gate.sh concern-c-g/compliance
```
Expected: main's failure set exactly (#4 FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
plus the three SafetyTests) and +8 new passes: ZapGateTests (4), PolicyLinksTests (4).
No live sentinel this concern — nothing here touches a relay.

## Gate 2 — policy links reachable and opening (simulator, by hand)
1. Launch signed in. Swipe the drawer open → Settings → **About** (last row
   under Settings, `info.circle`).
2. Sheet titled "About", section "Policies", three rows in this order:
   Privacy Policy, Terms of Service, Child Safety Standards
   (accessibility ids `policy-link-privacy`, `policy-link-terms`,
   `policy-link-child-safety`). Version line below.
3. Tap each: Safari opens `https://zap.cooking/privacy`, `/terms`,
   `/child-safety` — the same pages Android's About → Policies opens. No web
   view inside the app.

## Gate 3 — export compliance key
```sh
plutil -p Info.plist | grep ITSAppUsesNonExemptEncryption
plutil -p ShareExtension/Info.plist | grep ITSAppUsesNonExemptEncryption
```
Expected: `"ITSAppUsesNonExemptEncryption" => 1` in both. Reasoning:
ZAPCOOKING_IOS_BUILD.md §4.4 "Encryption export compliance".

## Gate 4 — kill switch demonstrated (simulator, by hand)
Structural check first — every post-level zap affordance branches on the seam,
and nothing reads the flag directly except the seam and its doc comment:
```sh
grep -n "ZapGate.postZapVisible" PostCardView.swift PollSection.swift \
  wisp/ArticleView.swift wisp/RecipeDetailView.swift wisp/Live/LiveStreamView.swift
grep -rn "FeatureFlags.zapsOnPosts" --include='*.swift' . | grep -v "ZapGate\|///\|// "
```
Expected: six hits in the first grep (card action bar, poll vote rows,
article bar default, recipe detail, stream host zap, chat-message zap); the
second grep is empty.

Then the flip:
1. In `FeatureFlags.swift` set `zapsOnPosts = false`. Build, launch, sign in
   with a key that has a wallet configured (Wallet drawer row).
2. Home / OnlyFood card action bar: reply, heart, repost, bookmark, chevron —
   **no bolt**, and a long-press where it sat does nothing (quick zap is gone
   with it).
3. Recipe detail engagement bar and an article: **no bolt**.
4. A NIP-69 zap poll (Global feed, kind 6969): options render as result bars,
   no bolt vote rows.
5. A live stream (if one is up): no "Zap" pill on the info bar, no "Zap" in a
   chat message's context menu.
6. Someone else's profile: lightning-address tap / zap button **still opens
   the zap sheet** (`eventId: nil`). This is the Damus split.
7. Revert the flag to `true`. `git diff FeatureFlags.swift` must be empty
   before Gate 5.

## Gate 5 — pbxproj
`git diff origin/main --stat -- wisp.xcodeproj` → empty.

## Results
Pending — recorded in the PR description after Seth's run.
