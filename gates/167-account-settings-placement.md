# GATE — concern/account-settings-placement (PR #167: Delete Account on its own Settings → Account screen)

Branch cut from main at 83e87a0 (#166). **Code frozen at f434c1b.** This
file is the only commit after it, and it is the HEAD commit. A review fix
breaks the freeze: push a fresh gate file last.

Placement only. No test publishes anything; the branch adds no network
calls. `AccountDeletion.swift`, `DeleteAccountView.swift` and
`ICloudBackupIndex.swift` are untouched (three-dot diff below).

## What was wrong
Guideline 5.1.1(v) asks that account deletion be easy to find. Delete
Account was a section on Settings → About, below the policy links: the
last row under Settings, then the second card on its screen.

## The fix
- `wisp/AccountSettingsView.swift` (new): "Account" screen, Delete Account
  row → `DeleteAccountView`, the `Account` payload struct moved from About
  with the same field names. Identifier `account-delete-account`.
- `wisp/SettingsCardSection.swift` (new): About's titled card as a shared
  view, used by both screens.
- `SidebarDrawerView.swift`: an indented **Account** row
  (`person.crop.circle`, `drawer-account`), first in `settingsItems`, with
  an `onOpenAccount` callback.
- `MainView.swift`: `showAccount` sheet with the same `onDeleted` branch
  the About sheet had; About's sheet is a bare `AboutView()`.
- `wisp/AboutView.swift`: Account section, `Account` struct and `account`
  property removed; doc comment repointed. Policies + version string only.

Test and UI test sweep: nothing in `wispUITests/` reached deletion through
About, and nothing referenced `about-delete-account`. The path in
`AccountDeletionTests`' doc comment is updated (comment only).

## Gate 1: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.0, iPhone 18 Pro, at f434c1b: **TEST BUILD
SUCCEEDED**, no warnings in any file the branch touches.
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```
Result, parsed from the bundle: **1540 passed / 3 failed / 22 skipped /
1565 total**. The parser says **PASS**: the failure set is exactly the
known set (#4, #117, #134). No new tests; the change is view wiring.

## Gate 2: BY HAND (Seth)
1. Open the drawer → tap **Settings**. **PASS:** **Account** is the first
   indented row, above Interface.
2. Tap **Account**. **PASS:** a sheet titled "Account" with one ACCOUNT
   card holding **Delete Account** in red with a chevron. The card looks
   like About's Policies card (header, surface, corners).
3. Tap **Delete Account**. **PASS:** the deletion flow's first screen
   ("What gets deleted"). Back returns to Account.
4. Drawer → Settings → **About**. **PASS:** Policies card and the version
   string only; no Account card.
5. Deletion still lands where it did. With two accounts on the device,
   delete one from Settings → Account. **PASS:** the sheet closes and the
   app switches to the other account. With one account: **PASS:** the sheet
   closes and the app returns to the splash.

## Gate 3: no pbxproj diff, deletion flow untouched (three-dot)
```
git diff --stat origin/main...HEAD -- wisp.xcodeproj/project.pbxproj \
  wisp/AccountDeletion.swift wisp/DeleteAccountView.swift wisp/ICloudBackupIndex.swift
```
Empty. Both new files are under `wisp/`.
