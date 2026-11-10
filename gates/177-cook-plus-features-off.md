# GATE — concern/cook-plus-features-off (PR #177: Cook+ features off for Guideline 2.1(b))

Branch cut from main at 0eafc5e (2.7 bump). One code commit:
- **288fd1a**: `cheffyEnabled`, `noteReviewEnabled`, `altTextAiEnabled` →
  `false`. Test pins are re-cut to match.

**Code frozen at 288fd1a.** This file is the only commit after it and is
the HEAD commit. A review fix breaks the freeze, so push a fresh gate file
last.

Answers App Review's 2.1(b) inquiry of 2026-10-26: the app unlocks **no**
paid features outside IAP. This is a **reversible compliance posture, not a
product decision.** The plan is to turn all three back on for the US
storefront once a region-gated external purchase link ships (permitted on
the US storefront post-Epic). Turning any one back on without that region
gate re-opens 2.1(b). `FeatureFlags.swift` and each pin test say so.

Untouched, verified in the diff: `zapsOnPosts` **true**,
`sousChefImportEnabled` true, `nourishEnabled` true,
`membershipLinkoutEnabled` false, `noteReviewCreditPurchaseEnabled` false.

## Gate 1: every entry point is behind its flag (audited in code before the flip)
No gate was incomplete, and no workaround was written.

### Cheffy: `CheffyGate.entryVisible()` covers both write sites of `showCheffy`
`CheffyView(` is constructed in exactly one place:
`MainView.shellWithCheffyCover` (`MainView.swift:780`), presented by
`$showCheffy`. `showCheffy = true` is written in exactly two places:
- `MainView.swift:950`, the Recipes tab:
  `onCheffy: CheffyGate.entryVisible() ? { showCheffy = true } : nil`.
  `RecipeFeedView` renders the Intelligence atom from that optional. When
  it's nil and Sous Chef is on, the atom is a plain **Sous Chef** button
  (`RecipeFeedView.swift:129`), so there's no menu and no Cheffy row.
- `MainView.swift:1300`, `cheffyButton` in the feed top bar. It's rendered
  only when `FeedTopBarLayout.controls(…, cheffyVisible: CheffyGate.entryVisible())`
  contains `.cheffy` (`MainView.swift:1259–1286`, `FeedTopBar.swift:39`).

No deep link reaches Cheffy: `wispApp.onOpenURL` is share-extension only.

**Correction to the brief:** My Kitchen has **no** Cheffy entry.
`MyKitchenView` has no Cheffy, Zappy, or Intelligence reference; its
header is avatar · title · section tabs. "My Kitchen's Intelligence menu"
in the `MainView.swift:773/1293` doc comments is stale wording for the
Recipes-tab atom above. That's a comment only, left alone under the code
freeze. Nothing is ungated.

### Note Review: `NoteReviewTrigger.isEligible` covers the menu row, the inline slot, and the fallback sheet
Both `NoteReviewSheet(` constructions (`MainView.swift:482` via
`ComposePresenter.openNoteReview`, and `PostCardView.swift:852` via
`activeSheet = .noteReview`) are reached only from
`PostCardView.openNoteReview()`. That has exactly two callers, and both
are conditioned on `noteReviewEligible`, which requires
`NoteReviewTrigger.isEligible(noteContent:)` → `flagEnabled ∧ https image`:
- inline action-row slot: `PostCardView.swift:1217`
- overflow menu row: `PostCardView.swift:1455`

### Alt-text AI: the flag wraps the whole section
`AltTextEditorView.aiSection` (`wisp/AltTextViews.swift:215`) is
`if FeatureFlags.altTextAiEnabled, keypair != nil { … }`. That covers the
button, the "Generate with AI" text, the **Cook+** capsule (227), the
accessibility label (238), and the notice line. `generateWithAI()` is
called only from that button, so its "Cook+ members feature." (272) and
"Sign in … to use Cook+." (280) notices are unreachable too. One gate
serves both hosts: `ComposeView.swift:268` (note composer) and
`RecipeComposeView.swift:191` (recipe composer).

## Gate 2: remaining user-facing "Cook+" strings
```
grep -rnE 'Cook ?\+|Cook Plus|Pro Kitchen|members? (feature|only)|AI credit' --include='*.swift' . | grep -vE '^(\./)?wispTests/'
```
String literals only. Comments (`///`, `//`, `// MARK:`) aren't shown in
the app and aren't listed. `CreateGroupSheet.swift:34/36` ("members only
read/post") match the pattern but are NIP-29 group-chat membership, not
Cook+.
Reachable with the flags off: **only `wisp/DeleteAccountView.swift`**, as
expected: 366, 401, 407, 413, 631, 686, 689. The `checkMembershipStatus`
call at ~103 is kept on purpose: it's account management for an existing
web customer.
Note that 366 and 631 also say "AI credits". They name a record the
deletion request covers, not a feature, and are kept with the rest.

Present in source but **unreachable** with the flags off (behind the gates
in Gate 1):
- `AltTextViews.swift` 227, 238, 272, 280
- `Cheffy.swift` 129 and 142: "Pro Kitchen" member copy, shown only
  inside `CheffyView`

`FeatureFlags.swift:7` is a doc comment. `ZapCookingApi.getPublicMembership`
has no app caller, so there is no membership badge anywhere. There are no
bugs to report.

## Gate 3: build green; hermetic at the known set, serial
Mac Studio, Xcode 27.0, iPhone 18 Pro, at 288fd1a: **TEST BUILD
SUCCEEDED**, with no warnings in the four touched files.
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-studio \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```
Result, parsed from the bundle: **1549 passed / 3 failed / 22 skipped /
1574 total**. The parser says **PASS**: the failure set is exactly the
known set (#4, #117, #134). That's +2 over main's 1572.

### Test changes
These were re-pinned on Seth's call, not inverted to fit:
- `CheffyTests/killSwitch_offHidesEntry_defaultIsOn` asserted two things:
  off hides / on shows, and the default is on. Split into
  `killSwitch_offHidesEntry_onShowsIt` (unchanged behaviour assertions,
  flag passed explicitly) and `killSwitch_shipsOff_guideline2_1b`
  (`!FeatureFlags.cheffyEnabled`, `!CheffyGate.entryVisible()`).
- `NoteReviewTriggerTests/killSwitchDefaultsOn` could only pass by
  asserting the opposite of its name, so it was reported, not edited.
  Replaced with `killSwitch_shipsOff_guideline2_1b`
  (`!FeatureFlags.noteReviewEnabled`, and an https-image note is not
  eligible under the shipped flag).
- New: `AltTextImetaTests/altTextAi_shipsOff_guideline2_1b`, so all
  three are pinned the same way. It follows the `ZapGateTests.sellNothingFlagsStayOff`
  shape.

Every "on shows it" test still asserts that, with `flagEnabled: true`
(`NoteReviewTriggerTests` matrix, `FeedTopBarPolishTests`, `CheffyTests`).
`SousChefTests/killSwitch_offHidesEntry_defaultIsOn` is still there and
correct: that flag stays on.

## Gate 4: no pbxproj diff (three-dot)
```
git diff --stat origin/main...HEAD -- wisp.xcodeproj/project.pbxproj
```
Empty. No new files except this one.

## Gate 5: BY HAND (Seth): reviewer walkthrough, confirming the negative
Use a signed-in (non-watch-only) account, so every gate other than the
flag would pass. On a device ≥ 390 pt wide (any Pro / Pro Max), the
inline Note Review slot would have shown. **Each step PASSES when the
named control is absent.**

1. **Recipes tab.** In the top bar, the atom glyph is a plain button. Tap
   it: Sous Chef opens directly, with **no menu** and **no "Cheffy" row**.
   Close it.
2. **Feed top bar** (Home, on every picker kind: Following, OnlyFood,
   etc.). Trailing shows the Gadgets cup **only**, with **no Cheffy
   mascot button** beside it.
3. **My Kitchen** (drawer → My Kitchen). Check the header, then the
   Saved / Published / Nourish sections. There is **no Cheffy, Note
   Review, or AI control** anywhere. (There never was one; this confirms
   it.)
4. **A note with a photo.** Find a kind-1 note with an https image in
   the Home feed.
   - Action row: **no Cheffy icon** between bookmark and expand.
   - "…" overflow menu: **no "Ask Cheffy about this photo"** row.
   - Repeat on the same note opened in its thread view.
5. **Composer alt-text editor.** Compose → attach a photo → tap the
   **"+ ALT"** chip. The editor shows the preview, explainer, field, and
   Save/Clear. There is **no "Generate with AI" button** and **no Cook+
   capsule**. With VoiceOver on, nothing reads "Generate description with
   AI, Cook+ feature". Repeat in the **recipe composer** (Recipes → + →
   add a photo → ALT).
6. **Still there (sanity):** a post's ⚡ zap affordance (`zapsOnPosts`
   is on), Nourish in My Kitchen, and Settings → Account → Delete Account,
   which shows its "Cook+ is separate" section for a member account only.
