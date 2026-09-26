# GATE — concern/eula-agreement (PR #154: EULA agreement at sign-up, Guideline 1.2)

Branch cut from main at 8651580 (#153). **Code frozen at c3aa7ee.** This file
is the only commit after it, and it is the HEAD commit. A review fix breaks
the freeze: push a fresh gate file last.

No test publishes anything or calls the network. The branch adds no network
calls.

**Web dependency:** zapcooking/frontend#760 adds the zero-tolerance
statement to /terms Section 4. The in-app sentence already says it, so this
branch doesn't wait on #760. When #760 ships, bump
`TermsAcceptance.currentVersion` to the page's new "Last updated" date.

## What changed
- `wisp/TermsAgreement.swift` (new): `TermsAcceptance` (version and
  timestamp, stored as `terms_accepted_<pubkey>`) and `TermsAgreementRow`
  (the checkbox and the sentence, linking Terms and Privacy).
- `NostrKey.swift`: `save` and `saveWatchOnly` require an acceptance and
  record it before the key is written. `deleteAccount` removes the record.
- `wisp/SplashView.swift`: the row goes above the two Continue buttons,
  which stay disabled until it's ticked. `NostrLoginSheet` takes the
  acceptance.
- `wisp/ContentView.swift`: hands the splash acceptance to the Nostr sheet
  and to Apple auth. `AppScreen.signUp` carries it.
- `LoginView.swift` (account switcher): the same row. Log In, QR and Create
  a new account are disabled until it's ticked.
- `AppleAuthView(Model).swift`, `SignUpFlowView.swift`,
  `SignUpViewModel.swift`: take the acceptance and pass it to `save`.
- `wispTests/TermsAcceptanceTests.swift` (new): 10 tests.
  `AccountDeletionTests` seeds with an acceptance.

## Gate 1: build green; hermetic run at the known set, serial
On the Mac Studio, Xcode 27.0, iPhone 18 Pro, at c3aa7ee:
**TEST BUILD SUCCEEDED**. No warnings in any file the branch touches.
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -only-testing:wispTests
sh ci_scripts/gate.sh --parse <bundle>
```
Result at c3aa7ee: 1344 passed / 3 failed / 21 skipped / 1368 total. The
parser says **PASS**: the failure set is exactly the known set (#4, #117,
#134).

## Gate 2: unit — no key without an acceptance record
```
-only-testing:wispTests/TermsAcceptanceTests \
-only-testing:wispTests/AccountDeletionTests \
-only-testing:wispTests/PolicyLinksTests
```
Result on the Studio: 22/22. `TermsAcceptanceTests` 10/10:
- `signUpAbandonedAfterKeyStored_stillHasRecord`: the wizard saves its
  key when it opens. The test discards the wizard with no step finished,
  and the key is saved and listed, onboarding is not done, and the record
  is present.
- `signUpNeverMounted_leavesNothing`: a wizard that's constructed but
  never shown writes no key and no record.
- `appleNewAccountHandedToWizard_keepsRecord`
- `save_recordsAcceptanceWithTheKey`, `saveWatchOnly_recordsAcceptance`
- `loggingInAgain_recordsTheLatestAgreement`, `deleteAccount_removesRecord`
- `record_roundTripsVersionAndTimestamp`, `now_stampsCurrentVersion`

Not covered by a test: the Apple view model itself (it needs Apple sign-in
and iCloud; it saves through the same `NostrKey.save`), and the
record-before-key order inside `save`.

## Gate 3: BY HAND — splash
Fresh install.
1. Splash: both Continue buttons are dimmed and do nothing when tapped.
2. Tap **Terms of Service** → Safari opens zap.cooking/terms. Tap **Privacy
   Policy** → zap.cooking/privacy.
3. Tick the box → both buttons enable. Untick → both disable again.
4. Tick → Continue with Nostr → Create new account → finish the wizard.
   **PASS:** you reach the feed. In the Xcode debugger,
   `po UserDefaults.standard.dictionary(forKey: "terms_accepted_<hex pubkey>")`
   shows the version and timestamp.
5. Repeat step 4 with Continue with Apple (new account and restore) and
   with nsec import.

## Gate 4: BY HAND — account switcher
Drawer → Add account. Log In, the QR icon and Create a new account are
disabled until the box is ticked. Tick → import an nsec → it works.

## Gate 5: BY HAND — existing accounts aren't re-prompted
Install this build over main with an account already signed in. **PASS:**
the app goes straight to loading and the feed, with no agreement screen.

## Gate 6: project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Prints nothing. The new app file is under `wisp/` (synchronized group).
