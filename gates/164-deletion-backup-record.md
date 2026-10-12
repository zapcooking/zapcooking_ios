# GATE — concern/deletion-backup-mapping (PR #164: Delete Account asks for Apple only when it can help)

Branch cut from main at 6ef3bfa (#161). **Code frozen at cd94484.** This
file is the only commit after it, and it is the HEAD commit. A review fix
or a wording change breaks the freeze: push a fresh gate file last.

Nothing in the tests publishes anything. The deletion request is a fake in
every test; the branch adds no network calls.

## What was wrong
Delete Account asked for Apple sign-in and the PIN whenever any Zap Cooking
backup was in the iCloud account. Backups are `wisp_bk_<uuid>` with no
pubkey, so matching one meant decrypting it. An nsec-imported account with
no backup of its own still had to sign in with Apple to check someone
else's backup.

## The fix
- `wisp/ICloudBackupIndex.swift` (new, self-registers): records which
  backup IDs belong to which pubkey. Device-only keychain item, service
  `com.wisp.apple-backup-index`, never synced. It sits outside
  `com.wisp.nostr` and UserDefaults, so a logout's `AppDataWipe` leaves it,
  the same way logout leaves the backup.
- `KeychainBackupService.uploadBackup` returns the ID it creates.
- `AppleAuthViewModel`: records on create, and on restore records every
  backup that decrypts to the restored account.
- `DeleteAccountViewModel.checkBackups`: recorded backup present → typed
  DELETE with that backup queued, no Apple step. No backups → unchanged.
  Backups present but none recorded → typed DELETE by default, with the
  "iCloud backup" section and the **Check for a backup** button into the
  existing Apple → PIN → match flow; forgot-PIN stays inside it.
- `AccountDeletion.clearKeychain` forgets the record.

## Gate 1: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.0, iPhone 18 Pro, at cd94484: **TEST BUILD
SUCCEEDED**. No warnings on any line the branch changes. The six
`AppleAuthViewModel.swift` warnings (305–381) are main's decoy-fetch lines
303–379, moved down by two lines.
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```
Result: **1539 passed / 4 failed / 22 skipped / 1565 total**. Three are the
known set (#4, #117, #134). The parser says FAIL on the fourth, which
**is not this branch's**:
`LazarusDeltaTests/anUncountedCurrentSideCountsAsAShrink` (#155) fails on
its own at LazarusCoreTests.swift:431 (`!other.shrinks`). It's a pure
function test, deterministic, and the branch touches no Lazarus code. The
test's second half picks an undecryptable version over one with two
counted follows and expects no shrink; the code reports one. Main's
failure, needing its own issue.

`AccountDeletionTests` alone: passed (12 tests, 3 new):
- `recordedBackup_skipsApple_andQueuesOnlyThatBackup`
- `unrecordedAccount_withBackups_defaultsToTyped_andOffersTheCheck`
- `restore_recordsEveryBackupOfTheAccount_andNoOthers`

## Gate 2: BY HAND (Seth) — the 5.1.1(v) recording session
One device, signed in to iCloud with iCloud Keychain on. The order matters:
each scenario leaves the state the next one needs. Before step 0 the
device has no records at all; the index is new in this build.

**0. Setup: a backup made before this build.** Install the 2.6 TestFlight
build. **Continue with Apple** → set a PIN → new account **Z**. Then
install this build over it (same bundle ID and team, so the keychain
carries over). Z's backup exists, and this device has no record of it.

**1. Unrecorded imported account, backups present.** Account switcher →
Add Account → paste a test nsec **Y** that has never been backed up.
Settings → About → Delete Account → Continue.
**PASS:** no Apple prompt. The confirmation shows the **iCloud backup**
section ("…that backup is still in your iCloud and could restore this
identity…", "There's 1 Zap Cooking backup…", **Check for a backup**) above
**Confirm** with the DELETE field.
*Optional, for the film:* tap **Check for a backup** → Continue with Apple
→ PIN → back on the typed confirmation with "None of the backups in this
iCloud account is this account, so none will be removed." Z's backup is
untouched.
Type DELETE → Delete account permanently. **PASS:** "Account deleted" with
"Your key and this account's data are gone from this device" (no backup
line). Done → the app switches to Z.

**2. The opt-in check finds and removes a backup.** As Z: Delete Account →
Continue. **PASS:** same iCloud backup section (Z predates the record).
**Check for a backup** → Continue with Apple → PIN.
**PASS:** "Ready to delete — Found this account's iCloud backup…", one tap.
Delete account permanently. **PASS:** "Your key, its iCloud backup, and
this account's data are gone from this device." Done → splash (Z was the
only account).

**3. Recorded account — the reviewer's path.** **Continue with Apple**.
**PASS:** straight to set-a-PIN, not enter-PIN: no backup left, which
proves step 2 removed Z's. Set a PIN → new account **W**. Delete Account
→ Continue.
**PASS:** no Apple prompt, no iCloud backup section. Confirm reads
"Deleting removes this account's iCloud backup, so Continue with Apple can
no longer restore it…". Type DELETE → delete. **PASS:** the done screen
names the iCloud backup. Then **Continue with Apple** again. **PASS:**
set-a-PIN screen (nothing to restore). Cancel.

## Gate 3: no pbxproj diff (three-dot)
```
git diff --stat origin/main...HEAD -- wisp.xcodeproj/project.pbxproj
```
Empty. The one new file is under `wisp/`.
