# GATE — concern-c-e/cheffy @ 8443165
Concern C-E: Cheffy chat (`POST /api/zappy`, NIP-98, member-gated) — chat +
"Surprise me", message-only gate, Save → recipe compose hand-off, Recipes-tab
sparkle → Intelligence menu (Sous Chef → Cheffy), `CheffyIcon`, kill switch.
Local build only on Seth's MacBook Air; gates run on the MacinCloud box by hand.
Frozen at "ready for gates"; results go in the PR description.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build` (iPhone 17 / OS 26.2): green.
- `build-for-testing` (compiles `wispTests`, runs nothing): green.
- Warnings in touched files: zero new. `wisp/ZapCookingApi.swift` carries
  eight pre-existing Swift 6 isolation diagnostics; the same eight appear on a
  clean `origin/main` build with the file touched (stash + touch + rebuild).
  `Cheffy*.swift`, `RecipeFeedView.swift`, `MainView.swift`,
  `FeatureFlags.swift`: none.
- pbxproj: no diff. New files: `wisp/Cheffy.swift`, `wisp/CheffyIcon.swift`,
  `wisp/CheffyService.swift`, `wisp/CheffyViewModel.swift`,
  `wisp/CheffyView.swift`, `wispTests/CheffyTests.swift`,
  `wispTests/CheffyLiveTests.swift`.
- No hermetic run on this machine (wave rule).

## Member key (once, reused by Nourish compute later)
Throwaway keypair minted 2026-09-01 for the Cook+-gated gates. Seth grants it
an active tier on pantry; the nsec lives ONLY in the git-ignored file below
(and on Seth's Air at the same path in the `zc-ios-c-d` worktree). Never
committed, logged, or echoed — the tests read it from the file and never
print it.

- npub: `npub1jdam6jehx54vw46rkpxeuppmgngrcvenuvelpmp4qjwuj53kcqks59reyl`
- hex: `937bbd4b37352ac75743b04d9e043b44d03c3333e333f0ec35049dc95236c02d`
- file on the box: `wispTests/.zc_member_nsec` (mode 600), or env `ZC_MEMBER_NSEC`

Pre-flight — confirm the grant landed before spending a gate on it:
```sh
curl -s 'https://zap.cooking/api/membership?pubkeys=937bbd4b37352ac75743b04d9e043b44d03c3333e333f0ec35049dc95236c02d'
```
Expected: `{"937b…c02d":{"active":true,"tier":"…"}}`. `"active":false` means
the grant has not landed; Gates 2 and 4 and the ungated half of Gate 3 will
skip, not fail.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin
~/gate.sh concern-c-e/cheffy
```
Expected: the box's failure set exactly (#4
`FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the three
`SafetyTests`, issue #57) and +31 new passes: `CheffyTests` (31). The three
`CheffyLiveTests` are skipped without the sentinel (they are not in the
count). A fifth failure is this concern's.

## Gate 2 + Gate 3 + Gate 4 — live against zap.cooking (no relay writes)
Chat is read-only against the backend; nothing here publishes an event, so
§7.13 does not apply. Three tests, one run:

1. `nonMember_isGatedByOwnerCheck_andChatIsBare403` — **Gate 3, gated half.**
   Ephemeral key, in memory only. Proves the owner check says
   `owner:true, isActive:false` → screen gate `.notMember`, and that the chat
   403 carries no `code` → `apiRejected(code:nil)` → the "unavailable"
   bubble (never `.membersOnly`). Runs without the member key.
2. `member_roundTripsAMultiTurnConversation` — **Gate 2 + Gate 3, ungated
   half.** Member key. Owner check `isActive:true` → `.open`; two real turns,
   the second carrying the first as history. Prints
   `[CheffyLive] turn N latency=…s` — **record both latencies in the PR**;
   they are the reason `computeClient` (75 s) exists.
3. `member_hungryReplyIsAStructuredRecipe_thatPrefillsCompose` — **Gate 4,
   hermetic half.** Member key. `mode: hungry` returns the strict
   `# Title / ## Ingredients / ## Directions` format and
   `RecipeComposeViewModel.prefillFromMarkdown` yields a title, ingredients,
   and directions. Prints the hungry latency too.

```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout concern-c-e/cheffy && git pull --ff-only
# member key: paste the nsec into the git-ignored file (or export ZC_MEMBER_NSEC)
umask 077; printf '%s\n' 'nsec1…' > wispTests/.zc_member_nsec
touch wispTests/.cheffy_live_enable
xcodebuild -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/CheffyLiveTests \
  test 2>&1 | tee /tmp/cheffy-live.log | grep -E 'CheffyLive|Test Case|passed|failed|skipped'
rm -f wispTests/.cheffy_live_enable
rm -P wispTests/.zc_member_nsec 2>/dev/null || rm -f wispTests/.zc_member_nsec
git status --short   # must be empty
```
Expected: 3 passed (3 skipped-with-reason if the member key is absent → only
test 1 counts; report that as blocked, not passed). Latency lines present.

## Gate 3 — by hand (simulator): message-only, no purchase surface
Structural check first — nothing in the Cheffy surface links out, prices, or
sells:
```sh
grep -n -i 'membership\|http\|subscribe\|upgrade\|\$' wisp/Cheffy.swift wisp/CheffyView.swift wisp/CheffyViewModel.swift | grep -v '///\|//' 
grep -rn 'FeatureFlags.cheffyEnabled' --include='*.swift' . | grep -v 'CheffyGate\|///\|// '
```
Expected: first grep empty; second grep empty (only the seam reads the flag).

Then, on the simulator:
1. Sign in with an **npub only** (watch-only). Recipes tab → sparkle → menu
   shows **Sous Chef** and **Cheffy** (ids `sous-chef-entry`, `cheffy-entry`).
   Tap Cheffy: the gate screen (`cheffy-gated`) — Cheffy icon,
   "Cheffy is a Pro Kitchen members feature.", "Sign in with a key to cook
   with Cheffy." No composer, no button, no link.
2. Sign in with a **non-member key** (any fresh nsec). Tap Cheffy: the same
   gate screen without the second line. No composer.
3. Sign in with the **member key**. Tap Cheffy: empty state with the four
   prompt chips + "Surprise me 🎲" and the composer. Send a question — a
   pending bubble with a rotating status line (thinking face), then a
   rendered markdown reply. "Start over" clears the thread.

## Gate 4 — by hand (simulator): save-to-recipes renders
Member key. Tap "Surprise me 🎲" (or ask for a full recipe). The reply gets a
**Save to my recipes** button (`cheffy-save-recipe`). Tap it: the existing
recipe compose form opens full-screen, prefilled — title, ingredients,
directions (chef notes / times when Cheffy emitted them). Close it without
publishing (the discard prompt appears if edited) → back on the chat, thread
intact. Publishing from here is the existing 2.4 `RecipePublisher` path; if
you do publish, follow §7.13 (delete with the same key afterwards).

## Gate 5 — kill switch (simulator, by hand)
1. `FeatureFlags.cheffyEnabled = false`. Build, launch. Recipes tab: the
   sparkle is a plain **Sous Chef** button again (`sous-chef-entry`), no menu,
   no Cheffy entry anywhere.
2. Revert. `git diff FeatureFlags.swift` must be empty before Gate 6.

## Gate 6 — pbxproj
`git diff origin/main...HEAD --stat -- wisp.xcodeproj` → empty. (Three-dot: main's
#41 spark fix touched `project.pbxproj` / `Package.resolved` after this branch
forked, so the two-dot form shows main's change, not ours.)

## Results
Pending — recorded in the PR description after Seth's run.
