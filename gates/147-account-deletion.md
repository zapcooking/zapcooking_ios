# GATE — concern/account-deletion (PR #147: in-app Delete Account, Guideline 5.1.1(v))

Branch cut from main at f709ebf (#144). **Code frozen at 4f5e66c** (the Copilot review fix on top of 57e8033). This file
is the only commit after it, and it is the HEAD commit. A review fix breaks
the freeze: push a fresh gate file last.

This is not a §7.13 live-write gate. No test publishes anything or calls the
network. The one network call this branch adds (`POST
/api/account/deletion-request`) runs only in the app during the hand gates.

**Endpoint dependency:** zapcooking/frontend#751 merges the day the deletion
TestFlight goes to testers (Seth's ruling). Until then production answers
404, and every deletion goes "Request not sent → Delete from this device
anyway". Gates 3–5 are written to pass on that path. Gate 3b is the
request-accepted path, and it runs once production answers 202.

## What changed
- `wisp/AccountDeletion.swift` (new): the engine. It matches this account's
  iCloud backups by decrypting them, deletes them, then does the local wipe:
  `AppDataWipe` plus an explicit `active` delete for a single account, or a
  targeted wipe plus hand-off when there are several. Also `CookPlusCancellation`,
  `DeletionRequestReceipt`, `ZapCookingApi.requestAccountDeletion`, and the
  `ICloudBackupStore` / `DeviceWipe` / `DeletionRequestSender` seams.
- `wisp/DeleteAccountView.swift` (new): the flow and its view model.
- `wisp/AboutView.swift`: an Account section with the red Delete Account row.
  `MainView.swift` passes in the keypair and wallet store, and on completion
  switches account or logs out.
- `SidebarDrawerView.swift`: Logout alert copy only (Apple-backed accounts
  do restore).
- `wispTests/AccountDeletionTests.swift` (new): 9 tests.

Review fix (4f5e66c): if the hand-off account named in `wisp_accounts`
has no keychain item, `delete` now throws `HandOffUnavailable` before
anything is deleted. Before, it fell through to the full `AppDataWipe`
and erased every other saved account. The view skips accounts that
can't be loaded when it picks the hand-off.

## Gate 1: build green; hermetic run at the known set, serial
Build on the Mac Studio, Xcode 27.0 (27A266a), `generic/platform=iOS Simulator`:
**BUILD SUCCEEDED** and **TEST BUILD SUCCEEDED** at 57e8033. There are zero
warnings in any file the branch touches. At 4f5e66c the Studio (it has
simulators now, iPhone 18 Pro) gives **TEST BUILD SUCCEEDED**, still with
zero warnings in touched files. Only Gate 2's suite was run there. The full
hermetic run below has not been re-run at 4f5e66c.

Air (Xcode 27.0, iOS 26.2 simulator). Clear the #91 scratch first:
```
find ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/tmp -name 'CFNetworkDownload_*.tmp' -delete
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-eueeqfatbdatzkdydeposrjcguue \
  -only-testing:wispTests
```
Pass means `sh ci_scripts/gate.sh --parse <bundle>` says PASS: the known set
is #4, #117 and #134, and nothing else fails. Expect **+9 tests** over main.

## Gate 2: unit (both keychain services clear for the pubkey; nothing under `com.wisp.nostr`, including `active`)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -skipPackagePluginValidation -parallel-testing-enabled NO \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-eueeqfatbdatzkdydeposrjcguue \
  -only-testing:wispTests/AccountDeletionTests
```
Expect 9/9 (9/9 on the Studio at 4f5e66c). What they cover:
- `singleAccount_clearsBothKeychainServicesIncludingActive`: nothing left
  under `com.wisp.nostr` for the pubkey (`active`, `account_`,
  `spark_seed_`, `nwc_`). The matched backup is gone and another identity's
  backup is kept. The full wipe is stubbed, so this proves the explicit
  clear.
- `multiAccount_removesOnlyThisAccount_andHandsOff`: the other account keeps
  its key, seed, settings and backup. The deleted account's `_<pk>`
  defaults and social-graph db are gone.
- `failedBackupDelete_leavesTheDeviceUntouched`
- `staleHandOff_deletesNothing_andNeverWipesTheDevice`: a listed account
  with no keychain item. No backup is deleted, no wipe runs, and the
  account and `active` stay.
- `request_goesFirst_thenBackups_thenWipe`: order is request → backup →
  wipe, and the key still exists when the request is signed.
- `failedRequest_deletesNothing_untilTheUserChooses`
- `match_findsOnlyThisAccountsBackups`,
  `receipt_decodesTheServerShape`, `cookPlus_cardOnlyForActiveStripeOwner`

## Gate 3: BY HAND, the one that matters (create→restore run backwards)
Device signed in to iCloud with iCloud Keychain on, and a fresh install of
this build.
1. Splash → **Continue with Apple** → set a PIN → finish onboarding. Record
   the npub (Settings → Keys).
2. Drawer → Settings → About → **Delete Account** → Continue. You should see
   "There's 1 Zap Cooking backup…" (or N) → **Continue with Apple** → enter
   the PIN → "Found this account's iCloud backup" → **Delete account
   permanently**.
3. Until #751 is live you get "Request not sent" → **Delete from this device
   anyway**. You should land on the result screen reading "Your key, its
   iCloud backup, …" → **Done** → splash.
4. Delete the app. Reinstall. Splash → **Continue with Apple**.
5. **PASS:** you are NOT offered the recorded npub. With no other Zap Cooking
   backups on this Apple ID you should go straight to "set a PIN" (a new
   account). If other backups exist, the old PIN must not unlock the
   recorded npub. **FAIL** means the recorded npub comes back in any form.

## Gate 3b: BY HAND, the request-accepted path (after #751 answers 202 in production)
Same as Gate 3, except step 3 must go straight to the result screen: "Zap
Cooking has your deletion request…". With the Cook+ member test key, also
check the renewal line. Then `GET /api/account/deletion-request`, signed with
NIP-98 by that key, returns the pending row.

## Gate 4: BY HAND, no auto-login from a leftover `active`
Create an account with **nsec import** (no iCloud backup) → Delete Account →
you should see "There's no Zap Cooking backup…" → type DELETE → delete
(anyway) → Done. Delete the app, reinstall and launch. **PASS:** the splash
screen shows, and there is no auto-login into the deleted account.

## Gate 5: BY HAND, both exports from inside the confirmation
On an account that has a Spark wallet, go to the final confirmation screen:
the typed DELETE screen, or the "Ready to delete" screen after Apple + PIN.
- **Export private key (nsec)** opens Keys. Reveal (Face ID) → Copy shows
  the nsec for the account being deleted.
- **Export wallet recovery phrase** opens Recovery Phrase. Reveal shows the
  12/24 words.
Both sheets close back onto the confirmation screen with nothing deleted.
The "Request not sent" screen offers the same two buttons.

## Gate 6: project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Prints nothing (checked at 4f5e66c).
