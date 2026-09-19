# GATE — concern/note-review (Cheffy Note Review)
Port of the web's Cheffy note photo review (frontend `eb99f009`) with
Android's structure (`NoteReview.kt` / `NoteReviewViewModel.kt` /
`NoteReviewSheet.kt` / `NoteReviewReplyPublisher.kt`) and none of its credit
purchase. Off main at 563e09d (#85). **This concern publishes** (a kind-1
reply), so §7.13 applies to the live gate.

**Machine.** The MacinCloud box is gone; every number here was produced on
Seth's MacBook Air (Xcode 26.3, iPhone 17 simulator on iOS 26.2, shared
DerivedData, `-skipPackagePluginValidation`, serial) from the worktree
`~/Projects/zc-ios-note-review`.

**Frozen at this commit.** App code is frozen at **0d1198d**. This GATE.md is the
only commit after it and is the HEAD commit — `gate.sh` refuses to run
otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

## What landed
- `wisp/NoteReview.swift` — phases `choose · signing · loading · draft ·
  posting · postTimeout · posted · deadEnd · membersOnly · error` (no upsell,
  no paying), `canPost` (draft only), the web copy pools verbatim (dead-end
  register, sign-failed, generic, rate-limited, membership-unavailable,
  post-timeout, publish-failed), sheet copy, disclosure footer + per-mode
  defaults + seed rule, `phaseForResult` (`MEMBERSHIP_UNAVAILABLE` → error,
  never the gate). `NoteReviewResult` typed results.
- `wisp/NoteReviewService.swift` — `POST /api/zappy/note-review` on the
  existing NIP-98 `authedPost` spine and the compute client; request capped
  to 1000 chars of note text before signing; pure response/error mapper.
- `wisp/ImageUrls.swift` — strict parity port of the web detector the server
  validates with. `wisp/NoteReviewTrigger.swift` — eligibility (flag ∧ image)
  and the measured 356pt inline threshold. `FeatureFlags.noteReviewEnabled`.
- `wisp/NoteReviewReplyPublisher.swift` — NIP-10 reply + client tag,
  `ThreadViewModel`'s relay rule; non-empty accept → posted, empty →
  postTimeout HOLDING the signed event (retry re-broadcasts the same id),
  failed only for an empty relay set. `wisp/NoteReviewPreferences.swift` —
  per-account disclosure booleans, nothing else.
- `wisp/NoteReviewViewModel.swift`, `wisp/NoteReviewSheet.swift` — the session
  and the sheet; a verified non-member sees `Cheffy.membersOnlyMessage` and a
  Close button only.
- `PostCardView.swift` — overflow-menu item "Ask Cheffy about this photo"
  whenever the (inner) note carries an image and the account can sign, and
  the adaptive inline slot before the expand chevron above the threshold.
- Issues filed, NOT fixed here: zapcooking_ios #88 (main's #85 left three
  OnlyFood structural-cap tests expecting the old cap) and zap_cooking_android
  #259 (converge on the web copy).

## Gate 1 — build green; hermetic, serial (MacBook Air)
```sh
cd ~/Projects/zc-ios-note-review
git fetch origin && git checkout concern/note-review && git pull --ff-only
xcodebuild build-for-testing -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-eueeqfatbdatzkdydeposrjcguue \
  -skipPackagePluginValidation
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-eueeqfatbdatzkdydeposrjcguue \
  -skipPackagePluginValidation -parallel-testing-enabled NO \
  -only-testing:wispTests -resultBundlePath ~/gate-note-review.xcresult
GATE_KNOWN_FAILURES="FeedRenderableTests/mentionTaggedNoteFollowsReplyGate OnlyFoodIngestParityTests/repost_dropped_whenInnerIsStructuralSpam_orUnparseable OnlyFoodIngestParityTests/poll_isAccepted_andStructuralCapApplies OnlyFoodOwnPublishTests/ownNote_overStructuralCap_isNotInserted" \
  sh ci_scripts/gate.sh --parse ~/gate-note-review.xcresult
```
**Result on the Air, 2026-09-19:** build green (three attempts: a Swift 6.2
frontend crash on a stored-closure default value in the publisher, fixed by an
explicit `init`; then three isolation warnings in new files, fixed).
Warnings in touched files at 0d1198d: **zero**. Full serial run:
**935 passed / 5 failed / 20 skipped / 960 total.** Failures: #4
`FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` (known), the three
OnlyFood structural-cap tests above (main's, #88 — reproduced on a second
serial run), and one `RecipeAuthoredFeedTests/authoredFeed_duplicateCoordinate_newerCreatedAtWins`
"crashed with signal kill" that **passed on rerun** (simulator one-off, not
reproducible). The box's #57 SafetyTests trio passes on the Air, as issue #57
records. The four failures listed in `GATE_KNOWN_FAILURES` above are the
Air's post-#85 baseline; a fifth is this concern's.

**Count.** 960 tests ran (main's last full serial run: 860 `@Test` declarations
at 563e09d); this branch adds **100** (`ImageUrlsTests` 18, `NoteReviewTests`
23, `NoteReviewTriggerTests` 8, `NoteReviewServiceTests` 18,
`NoteReviewViewModelTests` 29, `NoteReviewLiveTests` 3 opt-in, plus the
seven-control width case in `BottomBarAndActionRowTests`).

## Gate 2 — unit coverage
Inside Gate 1: the phase machine (every result → phase, including
`membershipUnavailable` → error and `≠ membersOnly`, `notMember` →
`membersOnly`), the four dead-end lines verbatim + the register check (no
"dish", no "not food") + rotation away from the previous line for every
line and every roll, `canPost` over `Phase.allCases`, the phase set pinned
with no upsell/paying, the disclosure footer/defaults/seed rule, the
per-account preferences; the view model (signing → loading → draft with the
selected image and capped note text, regenerate skips signing, start over,
double-tap posts once, post is a no-op from every non-draft phase,
postTimeout retains the signed event and retry republishes the same id
without a second sign, failed/signRejected keep the draft, footer only at
the hand-off, picker); the response mapper (typed codes, status fallbacks,
bare 403 → error not the gate, 401 → signFailed, `creditsRemaining`
ignored, compute-client pin); the trigger matrix; `ImageUrls` (Android's
17 cases + one). New suites alone: 106/106 in 184 s.

## Gate 3 — no credit / purchase surface
```sh
git grep -n -i -E 'credit-invoice|credit-status|creditInvoice|creditStatus|UPSELL|PAYING|price|purchase|bolt11|21 sat|invoice' -- \
  'wisp/NoteReview*' 'wisp/ImageUrls.swift' 'wispTests/NoteReview*' 'wispTests/ImageUrlsTests.swift'
git diff origin/main...HEAD -- PostCardView.swift FeatureFlags.swift | grep -i -E 'credit|upsell|paying|price|purchase|invoice'
```
Expected: the first prints only comment lines that name what is absent
(`NoteReview.swift` header, `NoteReviewPreferences.swift`, `NoteReviewService.swift`
header, the service test's `creditsRemaining`-is-ignored case); no code
symbol, no phase, no copy. The second prints only `FeatureFlags`' pre-existing
`noteReviewCreditPurchaseEnabled` context (unchanged, still hard `false`,
pinned by `ZapGateTests.sellNothingFlagsStayOff`). Verified at 0d1198d.

## Gate 4 — LIVE, member key: both modes draft
```sh
cd ~/Projects/zc-ios-note-review
curl -s 'https://zap.cooking/api/membership?pubkeys=937bbd4b37352ac75743b04d9e043b44d03c3333e333f0ec35049dc95236c02d'   # must say "active":true
touch wispTests/.note_review_live_enable    # wispTests/.zc_member_nsec is in place (mode 600)
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-eueeqfatbdatzkdydeposrjcguue \
  -skipPackagePluginValidation -parallel-testing-enabled NO \
  -only-testing:wispTests/NoteReviewLiveTests 2>&1 | grep -E 'NoteReview live:|✘|✔'
rm wispTests/.note_review_live_enable
```
**BLOCKED on the Air, 2026-09-19:** the Cook+ test key reads
`{"active":false,"tier":"member"}` — the membership granted on 2026-09-01 has
lapsed. `member_commentAndRecipeModesBothDraft` got `NOT_MEMBER` (13.0 s to
the 403). Re-grant the tier on pantry, then rerun; the test prints
`comment latency=…ms` / `recipe latency=…ms` for the report.

## Gate 5 — LIVE §7.13: publish a drafted reply, verify, delete, key held
Same command as Gate 4 (`publishDraftedReply_verify_delete_keyHeldUntilGone`).
An EPHEMERAL key publishes the parent note and the reply to
`RelayDefaults.defaults`; the member key only signs the NIP-98 draft
request; both events are re-queried, then deleted with the key held until
the ids are gone. **Partial on 2026-09-19:** parent published (accepted by
primal + nos.lol), the draft hit the lapsed-membership gate (685 ms), and
cleanup ran to completion — delete accepted on nos.lol, primal and
nostr.net; re-query of the parent id empty. Nothing leaked. The reply half
runs once Gate 4 is unblocked.

## Gate 6 — BY HAND: non-member sees message-only copy
Seth's device pass. Backed live: `nonMember_isTypedNotMember_andLandsTheMessageOnlyGate`
**PASSED** on the Air (ephemeral key → typed `NOT_MEMBER` in 10.1 s → view
model phase `membersOnly`). The sheet renders `Cheffy.membersOnlyMessage`
and Close, identifier `note-review-gated`; no price, invoice, or link-out.

## Gate 7 — pbxproj
`git diff origin/main...HEAD --stat -- wisp.xcodeproj` → empty at 0d1198d.
All new files are under `wisp/` / `wispTests/`.
