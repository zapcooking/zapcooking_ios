# GATE — concern/login-sheet-blank (PR #158: blank sign-in sheet in 2.5, Guideline 2.1)

Branch cut from main at 4f38921 (the 2.5 build). **Code frozen at 08ce223.**
This file is the only commit after it, and it is the HEAD commit. A review
fix breaks the freeze: push a fresh gate file last. Target: 2.6.

No test publishes anything. The branch adds no network calls.

## What was wrong
On the TestFlight 2.5 build, **Continue with Nostr** opened an empty sheet
the first time; dismissing it and tapping again rendered it. This is the
path the review notes tell the reviewer to use.

**The presentation.** It is the splash's sheet, not the account switcher.
`ContentView` presents `NostrLoginSheet` from `.sheet(isPresented:
$showNostrSheet)` on the `.splash` screen. That sheet is reached from
**Continue with Nostr** on the splash in two situations:
- first launch;
- after **Log out**, since `MainView.onLogout` returns to `.splash`.

The account switcher's **Sign in with another account** is a different presentation:
`LoginView` in a full-screen cover.

**Why it was empty the first time.** The tap set two pieces of `@State` in
one action:
```swift
onContinueWithNostr: { acceptance in
    splashAcceptance = acceptance      // TermsAcceptance?
    showNostrSheet = true
}
.sheet(isPresented: $showNostrSheet) {
    if let splashAcceptance { NostrLoginSheet(acceptance: splashAcceptance, …) }
}
```
SwiftUI rendered the sheet's content closure against `splashAcceptance` as
it was *before* the tap, which was `nil`, so the `if let` gave nothing: a
blank sheet. By the second tap the optional was already set (to the first
tap's acceptance), so it rendered. This is the last candidate in the
concern: *"a sheet bound to a boolean while its content depends on separate
state set in the same tap."*

**It's deterministic, not a race.** A hosted probe of exactly this shape
(a Bool and a `TermsAcceptance?` set in one action, with `if let` content)
ran on the Studio simulator. On first presentation it rendered the empty
branch: **content 0, empty 1**. Device speed doesn't change that. It is the
first presentation per `ContentView` lifetime, so every cold launch.

**Which commit introduced it.** **#154 (60a9049)**, not 35dabf0. #154 added
`splashAcceptance` and the `if let` gate inside the sheet. Before #154 the
content was unconditional and couldn't be blank. 35dabf0 changed only how
SplashView produces the acceptance (`.now()` at the tap instead of a
checkbox), and didn't touch `ContentView`. An earlier pass that saw nothing
is consistent with starting the Nostr or Apple flow after another
presentation had already set the optional. That's inferred, not verified.

**The other entry points:**

| Entry point | Shape in 2.5 | What it would do |
|---|---|---|
| Splash → Continue with Nostr | Bool sheet + `if let splashAcceptance` | blank sheet (the report) |
| Splash → Continue with Apple | Bool **full-screen cover** + `if let splashAcceptance` | blank full-screen cover. It can't be swiped away, and the Cancel button is inside the missing content. Same shape, same first-presentation failure. |
| LoginView → Create a new account | Bool full-screen cover + `if let acceptance` | blank full-screen cover, same trap |
| LoginView → QR scanner | Bool full-screen cover, **ungated** content | the scanner renders; its handler does `guard let acceptance else { return }` on the same optional, so a scan could silently do nothing |
| LoginView → Log In | takes `.now()` inside the action | not affected |

A sweep of the whole codebase found 16 other Bool-presented sheets/covers
with `if let` content. None of them sets its optional in the same action
as the Bool: they read a keychain call, a loaded profile, an injected
`walletStore`, or an invoice created earlier. They're not affected.

## The fix: what the ordering is now
There is no ordering left to get wrong. Each of the four flows is
presented with `.sheet(item:)` or `.fullScreenCover(item:)` on a
`PendingAgreement`, which wraps the tap's `TermsAcceptance`. The tap sets
that one value. SwiftUI presents because it's non-nil and hands it to the
content closure as an argument. The flow receives the acceptance from that
argument, never from separate state:

```swift
onContinueWithNostr: { nostrSignIn = PendingAgreement($0) }
.sheet(item: $nostrSignIn) { pending in
    NostrLoginSheet(acceptance: pending.acceptance, …)
}
```
Dismissal sets the value back to `nil`. `PendingAgreement`
(`wisp/TermsAgreement.swift`) documents why the Bool shape is banned.

- `wisp/ContentView.swift`: `nostrSignIn` / `appleSignIn` replace
  `showNostrSheet` / `showAppleAuth` / `splashAcceptance`.
- `LoginView.swift`: `qrScan` / `signUp` replace `showQRScanner` /
  `showSignUp` / `acceptance`. `handleScanned` takes the acceptance as a
  parameter.
- Each tap still records the acceptance at the moment of the tap, as
  35dabf0 intended. It's now carried inside the presentation.

## Gate 1: build green; hermetic run at the known set, serial
On the Mac Studio, Xcode 27.0, iPhone 18 Pro, at 08ce223 (tree identical
apart from an unrelated whitespace edit to `DeleteAccountView.swift` that is
not in the branch): **TEST BUILD SUCCEEDED**. No warnings on any line the
branch changes. `ContentView.swift:95` (the `LoadingView` trailing closure)
is unchanged and warns on main too.
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```
44 s end to end. Result, parsed from the bundle: **1348 passed / 3 failed /
21 skipped / 1372 total**. The parser says **PASS**: the failure set is
exactly the known set (#4, #117, #134).

### Unit: `EntryPresentationTests` (4) plus `TermsAcceptanceTests` (9): 13/13
- `sheet_rendersTheFlowOnFirstPresentation` and
  `fullScreenCover_rendersTheFlowOnFirstPresentation`: a hosted window
  presents the `PendingAgreement` shape on the first tap, and the flow's
  content renders with the acceptance. With the 2.5 shape, the same
  harness rendered the empty branch (the probe above).
- `entryFiles_neverPresentOnABoolWithOptionalContent`: a tripwire over
  `ContentView`, `SplashView` and `LoginView`. It fails if any of them
  regains a Bool-presented sheet or cover whose content opens with
  `if let` / `guard let`. This is the guard against a silent regression.
- `tripwire_catchesThe25Shape`: the tripwire flags both 2.5 splash
  presentations and not the ungated QR one.

Not covered by a test: tapping the real buttons in the real `ContentView`.
The test host exposes no accessibility elements to activate (tried; the
splash reported none), so the device pass below is the end-to-end check.

## Gate 2: BY HAND (Seth) — first presentation renders
1. Delete the app, install the build, **cold launch**, tap **Continue with
   Nostr**. **PASS:** the sheet shows the nsec field, Log In and Create new
   account the first time.
2. Swipe the app away and repeat from cold, **three times**.
3. Cold launch, tap **Continue with Apple**. **PASS:** the Apple screen
   renders, with its Cancel button.
4. Signed in: open the account switcher → **Sign in with another account**. Tap the
   **QR** icon: the scanner renders, and Cancel works. Tap **Create a new
   account**: the wizard renders the first time.
5. Log out → splash → **Continue with Nostr** renders the first time.

## Gate 3: no pbxproj diff (three-dot)
```
git diff --stat origin/main...HEAD -- wisp.xcodeproj/project.pbxproj
```
Empty. The test is in the synced `wispTests/` folder, and
`PendingAgreement` is in the existing `wisp/TermsAgreement.swift`.
