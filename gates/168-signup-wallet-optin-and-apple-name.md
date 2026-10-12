# GATE — concern/signup-wallet-optin-and-apple-name (PR #168: Apple name pre-fill; Lightning wallet opt-in)

Branch cut from main at b621e73 (#167). Three code commits, kept apart so
each can be cited alone:
- **aa6a90c**: sign-up pre-fills the display name with the name Apple
  shares (Guideline 4).
- **9025364**: the sign-up Lightning wallet is opt-in, off by default
  (evidence for the 3.1.1 / 3.2.1(vii) appeal).
- **7587f20**: turning the wallet toggle back off deletes the seed it
  saved (`discardSignupWallet`), so Delete Account doesn't offer "Export
  wallet recovery phrase" for an account that opted out.

**Code frozen at 7587f20.** This file supersedes the gate file at aa0ac3d
(frozen at 9025364). It's the only commit after 7587f20, and it is the
HEAD commit. A review fix breaks the freeze: push a fresh gate file last.

No test publishes anything or starts Breez. The wallet tests drive
`preparedProfileEvent()` (the kind-0 `finishProfileStep` signs),
`deriveSignupWallet()` (the seed-saving half of `startWalletSetup`, without
the connect), `discardSignupWallet()` and `finishSignup()` (the view-model
half of the wizard's `finish()`).

## Gate 1: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.0, iPhone 18 Pro, at 7587f20: **TEST BUILD
SUCCEEDED**. No warnings on any changed line. The warnings in touched files
are all main's lines, moved down:
- `AppleAuthViewModel.swift` decoy fetch (6)
- `SignUpFlowView.swift` `uploading`
- `SignUpViewModel.swift` `signupLog` and `writeRelaysByAuthor`
- `ContentView.swift` `LoadingView` trailing closure
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```
Result, parsed from the bundle: **1547 passed / 3 failed / 22 skipped /
1572 total**. The parser says **PASS**: the failure set is exactly the
known set (#4, #117, #134). +7 tests over main:
- `SignUpAppleNameTests/suggestedName_formatsApplesName_andIsNilWhenThereIsNone`
- `SignUpAppleNameTests/wizard_prefillsTheDisplayName_andLeavesItEditable`
- `SignUpWalletOptInTests/toggleOff_profileHasNoLightningAddress_andNoWalletMode`
- `SignUpWalletOptInTests/toggleOn_registrationFails_profileStillShipsBare`
- `SignUpWalletOptInTests/toggleOnThenOff_leavesNoSeed`
- `SignUpWalletOptInTests/optedIn_finishingTheWizard_keepsTheSeed`
- `SignUpWalletOptInTests/toggleOnOffOn_endsWithTheSameSeed`

**The trap test was proven by mutation.** With
`deleteSparkMnemonic` temporarily added to `tearDownSignupWallet()` (which
`finish()` runs for every user), `optedIn_finishingTheWizard_keepsTheSeed`
failed and the other four passed. Reverted before commit; the gate run
above is the clean tree.

### Breez on-disk store: why toggle-off leaves it
Breez 0.23.1 `crates/breez-sdk/core/src/persist/path.rs`
(`default_storage_path`) stores each wallet at
`spark_data/<network>/<first 8 hex of sha256(identity pubkey)>/`. The
`spark_data` root is shared; the store inside it is per wallet. Another
account derives another seed, so a different identity and a different
folder; it never opens the leftover. The only wallet that would is this
account's own default wallet set up later. It re-derives the same seed
and reuses the folder as its sync cache; the seed in the keychain stays
the source of truth.

## Gate 2: way back in (verified in code before any UI was written)
With the toggle off, `WalletMode` is never written. It's saved only inside
`registerSparkLightningAddressIfReady`, after a successful registration.
So `WalletStore.mode` is nil and `startIfConfigured` returns at its guard.
- **Drawer:** non-watch-only accounts get `SidebarMiniWalletView`, which
  reads **Set up wallet** when `mode == nil`. It opens `.wallet`.
- **Wallet screen:** `mode == nil` → `WalletModeSelectionView` ("Connect a
  wallet") → **Spark wallet** → `SparkSetupView` (incl. "Use my default
  wallet", which derives the same nsec-based wallet sign-up would have),
  or **Nostr Wallet Connect** → `NwcSetupView`.

Wallet is drawer-only (`BottomTab.wallet` stays out of the bar for
review). That's why the toggle copy says "from the menu", not "the Wallet
tab".

## Gate 3: BY HAND (Seth) — filming

### Film: toggle off (the appeal screenshot)
Fresh install, or log out of every account.
1. Splash → **Create a new account** (or Continue with Nostr → Create).
2. Profile step: add a name (and a photo if you like). **Show the
   "Lightning wallet" toggle, off**, with its copy in frame: "Create a
   wallet so people can zap your posts. This adds a public Lightning
   address to your profile. You can set one up later from the menu
   instead." Leave it off.
3. **Continue** → follows → topics → skip the intro note → the app.
4. Drawer → **My Profile**. **PASS — screenshot this:** name and bio, and
   **no ⚡ Lightning address line** under the bio. (`ProfileView` draws
   the ⚡ row only when kind-0 has `lud16`.)
5. Open the drawer. **PASS:** the wallet stripe reads **Set up wallet**,
   showing nothing was set up. Tap it → "Connect a wallet" picker. Close
   it without choosing.

### Toggle on (optional, shows it still works)
6. New account, toggle **on**, finish. **PASS:** My Profile shows a ⚡
   `{color}{animal}{number}@…` address; the drawer stripe shows a balance.

### Toggle on, then off (optional, the seed fix)
7. New account: toggle **on**, wait a moment, toggle **off**, finish.
   **PASS:** no ⚡ address and **Set up wallet** in the drawer, as in the
   film. Then Settings → **Account** → Delete Account. **PASS:** "Save
   first" offers **Export private key (nsec)** only, with no "Export
   wallet recovery phrase". Back out without deleting.

### Apple name pre-fill
Apple returns the name only on the first authorization for this Apple ID
and app. To film it, first remove the app from Settings → [your name] →
Sign-In & Security → Sign in with Apple → Zap Cooking → **Stop Using
Apple ID**.
8. Splash → **Continue with Apple**. On Apple's sheet, share your name →
   set a PIN.
9. **PASS:** the wizard's Display name field is already filled with that
   name, and it's editable.
10. *Expected, not a bug:* a later Continue with Apple → create another
   account reaches the wizard with the field empty, because Apple returns
   no name after the first authorization.

## Gate 4: no pbxproj diff (three-dot)
```
git diff --stat origin/main...HEAD -- wisp.xcodeproj/project.pbxproj
```
Empty. The two new files are under `wispTests/`.

## Gate 5: commits 1 and 2 untouched
```
git diff aa0ac3d 7587f20 --stat
```
Only `SignUpFlowView.swift`, `SignUpViewModel.swift` and
`wispTests/SignUpWalletOptInTests.swift`, all from 7587f20. aa6a90c and
9025364 are unchanged on the branch.
