# GATE — concern/onboarding-slides (PR #160: onboarding slides on every sign-in)

Branch cut from main at 9dba7ad (2.6). **Code frozen at d3c2f2a.** This
file is the only commit after it, and it is the HEAD commit. A review fix
breaks the freeze: push a fresh gate file last.

No test publishes anything. The branch adds no network calls; it removes
screens and changes when one flag is set.

## What was wrong
Signing in with a key showed Welcome back → "Your network, your relays" →
"Quick follow" → "Zaps" → "You're all set!" before the app.

**Who saw it.** Only existing keys: Continue with Nostr (pasting a key),
Continue with Apple restoring an account, and Add Account for a pubkey new
to the device. New accounts never saw it: `SignUpFlowView` marks
`onboarding_done_` itself and goes straight to `MainView`. The one group
that needs no teaching was the only group taught, under "Welcome back".

**Why "every sign-in".** The gate is `onboarding_done_<pubkey>`, and two
things defeated it:
- Logout clears it. Single account: `AppDataWipe.wipeEverything()` removes
  the whole UserDefaults domain. Multi-account: `NostrKey.deleteAccount`
  removes the key by name. Sign out, sign back in → slides again.
  **Left as is**: the wipe is correct, and the returning user now sees
  only the waiting screen.
- The no-follows exit (`OnboardingViewModel.swift:76`) never set it, so an
  account following nobody — or one whose relay query timed out — ran the
  slides on every cold launch.

## The fix
- `OnboardingView.swift`: Welcome, Outbox, Quick follow and Zaps steps
  deleted, with their shared layout. An existing key goes straight to the
  waiting screen (avatar ring, rotating copy, then "You're all set / Let's
  go"). Watch-only keeps its own screen. The screen's slide transition into
  the app is unchanged.
- `OnboardingViewModel.swift`: the no-follows exit marks the account done
  **only when the relays answered** (the kind-0/3 query returned anything).
  A total timeout stays unmarked and retries next launch, because nothing
  else in the app rebuilds the relay scoreboard — marking it would leave
  the follows feed empty until logout.
- `wisp/ContentView.swift:45`: stale comment claiming watch-only keys are
  marked done in the login sheet. Nothing does that; they take the same
  route and get the watch-only screen.

**What the waiting screen is for — why it stays.** It holds the app until
`startOutboxBuilding` has built the relay scoreboard. Without one,
`FeedViewModel.loadFeed` returns early and the Feed tab is empty. The slides
used to overlap that build; now the wait is visible: up to ~30 s for a large
follow list (kind-10002 lookups in batches of 150 at 15 s each). Follow-up
**#159** removes the screen: the app opens on Recipes, which never reads
the scoreboard, so the build can run in the background with one loading
state on the Feed tab.

Skipped by decision: a "long-press to follow" tip card. Profiles have a
Follow button; long-press is a shortcut.

## Gate 1: build green; hermetic run at the known set, serial
On the Mac Studio, Xcode 27.0, iPhone 18 Pro, at d3c2f2a (tree identical
apart from an unrelated uncommitted edit to `DeleteAccountView.swift` that
is not in the branch): **TEST BUILD SUCCEEDED**. No warnings on any line the
branch changes. `ContentView.swift:96` (the `LoadingView` trailing closure)
is unchanged and warns on main too (line 95 there; the comment fix added a
line).
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```
46 s end to end. Result, parsed from the bundle: **1362 passed / 3 failed /
21 skipped / 1386 total**. The parser says **PASS**: the failure set is
exactly the known set (#4, #117, #134).

No new test. `OnboardingViewModel` queries live indexer relays through the
static `RelayPool.query`, with no seam to inject a timeout, and
`OnboardingView` has no logic left to unit-test. The device pass below is
the check.

## Gate 2: BY HAND (Seth)
1. Log out (single account). **Continue with Nostr**, paste an existing key
   with follows. **PASS:** no slides; the waiting screen, then "You're all
   set! Following N people across M relays", then **Let's go** → Recipes.
   The Feed tab shows follows.
2. Swipe the app away, cold launch. **PASS:** straight in (loading splash),
   no waiting screen.
3. Log out, sign back in with the same key. **PASS:** waiting screen only,
   no slides.
4. **Continue with Apple** restoring an existing account → same as 1.
5. Account switcher → Add Account with a second existing key → same as 1.
   Switch back to the first account → no waiting screen.
6. **Create new account** → the sign-up wizard, unchanged, no slides.
7. *Optional, timeout path:* airplane mode, paste a key. **PASS:** the
   waiting screen ends at "You're all set!" with no follow count. Turn the
   network on, cold launch: the waiting screen runs again and this time
   shows the follow count.

## Gate 3: no pbxproj diff (three-dot)
```
git diff --stat origin/main...HEAD -- wisp.xcodeproj/project.pbxproj
```
Empty. No files added.
