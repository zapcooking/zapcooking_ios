# Carry upstream Wisp iOS fixes into Zap Cooking

## Context

`zapcooking/zapcooking_ios` is a fork of `barrydeen/wisp-ios` (MIT, © Barry Deen).
The fork base is upstream commit **`d51f260` (2026-07-28, upstream PR #425)** — established by
tree-hash comparison, not by the fork's own dates (the fork's root commit `7e84e06` is dated
2026-08-29 but carries upstream code as of 2026-07-28).

Since that base upstream merged **39 PRs / 59 non-merge commits** through `4e8a5d3` (2026-09-16).
The fork re-derived three of them independently (poll tally re-query `#80`, Spark failed-payment
`#17`, login Cancel corner) but the rest was never reviewed. Verification against the fork's
working tree shows the fork is carrying the **pre-fix code verbatim** in the areas that matter
most for a reading client, including two subsystems that are absent outright.

Headline findings, by the areas asked about:

- **Note reading — the largest gap.** Every content-rendering fix since the fork is missing:
  Unicode hashtags don't tokenize, blank lines around image/quote/invoice cards aren't trimmed,
  3+ newline runs render as real empty lines, an npub inside a URL gets rewritten into a mention
  on publish. Long-form articles render mentions as raw `nprofile1q…`, drop the `summary` tag,
  mis-parse a trailing `#hashtag` as a Markdown heading, and have no tappable hashtags/mentions.
- **Mute lists — nothing to carry.** This is the clean result. `Nip51Mute.swift` is **byte-identical**
  to upstream; `MuteRepository.swift` differs only by the fork's own `ReportedContent` plumbing.
  Upstream has shipped **no mute-list bug fixes** since the fork diverged. The only mute-adjacent
  item is a one-line confirmation-copy change.
- **Deletions — a real hole at the same chokepoint as mute.** Upstream's `SafetyFilter.shouldDrop`
  opens with `DeletionTracker.shared.isDeleted(event.id)`. The fork **replaced** that line with its
  own reported-content checks (`SafetyFilter.swift:83-95`) and never added `DeletionTracker.swift`.
  A note its author retracted via NIP-09 stays visible in feed, thread, search, profile and quote
  cards, forever. The fork's own `DeletionSender` publishes kind-5s it then ignores locally.
- **Threading — frozen at the fork base.** No NIP-22 support of any kind (`grep -rn "Nip22"` returns
  zero hits fork-wide), so replies to kind-1111 comments publish spec-violating kind-1s. The sticky
  reply bar still targets whatever row `onAppear`/`onDisappear` last called visible rather than the
  opened note.
- **Compose/publish reliability.** `ComposeViewModel.topWriteRelays()` (`:1880`) returns the entire
  relay scoreboard uncapped and unfiltered — upstream measured 480 entries including `.onion`
  addresses and malformed URLs, stamped into every poll's `relay` tags (a 21.5 KB kind-1068 that
  size-limited relays reject) and opened on every draft save. A post no relay accepts loses its text.

Goal: land everything except the one behaviour-changing routing rewrite, one concern per PR per
`AGENTS.md` §6, and record the remainder in `ZAPCOOKING_IOS_BUILD.md` so it isn't lost.

Upstream is cloned read-only at `/home/user/barrydeen/wisp-ios` (full history) for reference during
the port. Every SHA below is an upstream SHA.

---

## Before starting: the test baseline is currently dirty

`ci_scripts/gate.sh` passes only when the failure set is *exactly* `GATE_KNOWN_FAILURES`
(`gate.sh:36` — issue #4 plus three `SafetyTests`). Issue #88 reports that #85 left three OnlyFood
structural-cap tests failing on `main`. **Resolve #88 or extend `GATE_KNOWN_FAILURES` first** —
otherwise every PR below reports a red gate for a reason that has nothing to do with it.

Current fork baseline: **899 `@Test` declarations** across 93 files in `wispTests/`
(`git grep -cE '^[[:space:]]*@Test' -- 'wispTests/*.swift'`). Upstream has 406. Upstream's new test
files can be taken verbatim where the ported code matches; each PR below states its expected delta.

---

## Phase 1 — port now, 13 concerns

Ordered by dependency, then by value. Each is one branch + one PR. Three new **root-level** Swift
files land here (`DeletionTracker.swift`, `Nip22.swift`, `QuoteGraph.swift`) — every one needs an
explicit `PBXFileReference` in `wisp.xcodeproj/project.pbxproj` (`AGENTS.md` §6, "`project.pbxproj`
is a trap"). Files under `wispTests/` are in a synchronized group and need no registration.

### 1. NIP-09 deletion tracking — `9fed5e0`
The single highest-value port. New `DeletionTracker.swift` (upstream 259 lines at HEAD; 98 at
`9fed5e0`) — a process-wide id set behind an `NSLock`, persisted to `UserDefaults`, debounced.

- `SafetyFilter.swift:83` — restore `if DeletionTracker.shared.isDeleted(event.id) { return true }`
  as the first check in `shouldDrop`, **above** the fork's `reportedEventIds`/`reportedPubkeys`
  gates. The two features are orthogonal and coexist without conflict; keep both.
- `EventStore.swift:12` — add `5` to `persistedKinds`; add `loadDeletionEvents()`.
- `FeedViewModel.swift:1273` — add `Nip09.kindDeletion` to the follows-feed kinds
  (`[1, 6, 20, Nip88.kindPoll, Nip69.kindZapPoll]`); intercept kind-5 in the consumer loops at
  `:979` and `:1294`; seed the tracker from disk in `start()`.
- `ThreadViewModel.swift:966` — kind 5 rides the existing `#e` reply subscription, no extra round-trip.
- `ProfileViewModel.swift:181-186` — add `loadDeletions()` to the header task group.
- `SearchViewModel.swift:395` — non-blocking background kind-5 lookup after a note match.
- `DeletionSender.swift:46,92` — restore the two `DeletionTracker.shared.ingest(event)` calls the
  fork dropped. Keep the fork's relay-fallback list (it deliberately drops `relay.damus.io`).
- `AppDataWipe.swift` — add `DeletionTracker.shared.clear()` alongside the existing `.clear()` calls.

Also fold in `e48da50`'s debounce (full-set `UserDefaults` writes per deletion stall the main thread).
New tests: upstream `wispTests/DeletionTests.swift` (168 lines) — port with `@Suite(.serialized)`
(that is what `4978f97` fixed).

### 2. Deleted-quote placeholder + quote recovery — `27232e7`, `8beaa80`, `8496f7d`
Stacked on #1. A retracted quoted note currently renders as "Note hidden by your safety filters"
(blaming the reader) or "Quoted note not found" (inviting a retry that can't work).

- `Nip09.swift` — restore the read side the fork stripped: `deletionFilter(eventId:authors:)` and
  `deletedEventIds(_:)` (+26 lines; fork's file is 18 lines vs upstream's 44).
- `DeletionTracker.swift` — `isDeleted(eventId:author:)` (signer-verified, distinct from the app-wide
  gate), on-demand `check(eventId:author:relayHints:)`.
- `ContentParser.swift:36` — `case nostrNote(eventId:relayHints:author:)`; thread the new param
  through `RichContentView.swift:420`.
- `QuotedNoteView.swift` — `deletedCard` checked ahead of `safetyHiddenCard` (`:266`) and
  `missingCard` (`:281`); one-level quote-stack recovery.
- New `QuoteGraph.swift` (138 lines, verbatim-portable, `Foundation` only) + `q`-tag edge recording
  in `EventStore.persist` + `QuoteGraph.shared.clear()` in `AppDataWipe`.
- `QuotedNoteCache.fetch/refetch/runFetch/relayList` gain an `author:` param so an unresolvable quote
  falls back to the quoted author's own write relays via `RelayListRepository`.

### 3. ContentParser blank-line handling — `a66e105` then `865ead2`
Order matters; `865ead2`'s Pass 6 is written to sit after `a66e105`'s rewritten Pass 5.

- `ContentParser.swift:339-359` — replace the current Pass 5 (trailing-trim only, keeps one newline,
  leaves whitespace-only text segments that still render a spaced row) with the `isBlock(_:)` helper
  + `pruned` two-sided trim.
- Add `blankLineRunRegex` / `leadingBlankLinesRegex` / `trailingBlankLinesRegex` near the other
  pattern statics (~`:97`) and a new Pass 6, guarded by the `trimBlankLines` flag the fork already
  has at `:144,198`.
- New tests: `ContentParserBlockSpacingTests.swift` (121 lines), `ContentParserBlankLineTests.swift`
  (102 lines).

### 4. Unicode hashtags — `91ddbcc`
One line. `ContentParser.swift:83` — `#([a-zA-Z0-9_][a-zA-Z0-9_-]*)` →
`#([\p{L}0-9_][\p{L}0-9_-]*)`. Today `#Kreuzworträtsel` stops matching at the `ä`.

### 5. Compose correctness — `a0e6ced`, `08ad5b8`, `4f25b14`
Three small, independent fixes; ship together as one compose concern.

- **Trailing blank lines** (`a0e6ced`): add `nonisolated static func trimTrailingBlankLines(_:)` to
  `ComposeViewModel.swift`, call it in `bodyForPublish` (`:1381-1388`) and `runPrivateReplyPipeline`
  (`:1310-1312`). The parser-side collapse in #3 only helps Wisp's own renderer; this fixes what
  every other client sees.
- **npub inside a URL** (`08ad5b8`): `ComposeView.swift:536` and `ComposeViewModel.swift:1767` —
  add the `(?!\.[a-zA-Z])` lookahead and make both helpers `static`. A Blossom URL like
  `npub1….blossom.band/…` currently gets its subdomain rewritten into a mention on publish.
- **Relay cap** (`4f25b14`): `ComposeViewModel.swift:1880-1886` — filter by
  `RelayUrlValidator.isConnectable` and `.prefix(5)`, matching the copy in `DraftsViewModel` that
  already caps correctly. Highest value-per-line in the whole plan.

### 6. Draft survives a rejected publish — `5fe05c5`
`wisp/PostPublisher.swift:175` `fail(_:)` only marks the pill failed and auto-dismisses after 4s;
the autosave bucket was already cleared at hand-off, so the text is gone. Snapshot the cleared
bucket into `PreparedDraft` (`:225-240`), write it back on `fail()`/mining-cancel, stop the
auto-dismiss, add Retry to `wisp/PostStatusPill.swift` re-stamping `created_at` (PoW commits the
timestamp into the event id). ~300 lines across 4 files + 2 upstream test files (188 lines).

### 7. Feed scroll-to-top lockup — `a985951`
- `FeedViewModel.swift:814-819` — wrap `flushPendingInserts()` in `Task { @MainActor in … }`.
  It is called from `MainView.swift:1871-1876`'s `.onScrollGeometryChange` action, and mutating
  `events` synchronously inside that callback corrupts SwiftUI's scroll-offset bookkeeping.
- `MainView.swift` (feed `ScrollView`, ~`:1269` upstream) — add `.defaultScrollAnchor(.top)`.

`FeedViewModel.swift` is 1341 lines vs upstream's 1347 but 416 lines differ (OnlyFood / unified-feed
work). Locate the equivalent call sites by hand rather than applying the patch.

### 8. Hashtag route on every tab — `e6d5962`
`MainView.swift` — only `feedPath`'s stack registers
`.navigationDestination(for: HashtagFeedRoute.self)` (`:800`); `recipesPath` (`:874`),
`kitchenPath` (`:949`), `searchPath` (`:1011`) and `notificationsPath` (`:1040`) don't, and their
`onHashtagTap` closures are literal no-ops (`:898, :962, :1019, :1080`). Parameterize
`hashtagFeedView(for:)` (`:2050`) to `hashtagFeedView(for:path:)` as upstream did. The fork has two
more tabs than upstream, so this covers more call sites than the original diff.

### 9. NIP-22 external-content comments — `dd05780` + `a0a1e7e`, then `65d342e`, `91f30df`, `bdeaaf5`
The whole chain, as one concern. Build the external-content card in its **final** (post-`a0a1e7e`)
position — above the comment text — rather than landing the wrong order and re-patching.

- New `Nip22.swift` (104 lines): `kindComment`, `ExternalRef`, `isComment`, `externalRoot(of:)`,
  `externalParent(of:)`, `buildReplyTags(to:relayHint:)`.
- Ingest: `EventStore.persistedKinds` + the feed/thread query kind unions; `FeedViewModel`
  `relayFeedKinds` and `isFeedRenderable` (comments stay **out** of the home timeline by design);
  `SearchViewModel.handleNoteResults`.
- Render: `PostCardView` `externalContentCard(_:)` + `externalKindLabel(_:)`, and `91f30df`'s gate so
  the source card shows only on top-level comments.
- Publish (`65d342e`): `ComposeViewModel.determineKind()` (`:1363-1376`) currently always returns `1`
  for a non-poll reply; `buildBaseTags()` `.reply` (`:1600-1621`) emits only NIP-10 `e`/`p`. Add the
  kind-1111 branch and `I`/`K` root-scope tags. Same gap in `PrivateReplyPublisher.swift`.
- Profile tab (`bdeaaf5`): `ProfileTabs.swift:3-8` `enum ProfileTab` gains `.comments`.
- New tests: `Nip22CommentTests.swift` (123), `ComposeReplyKindTests.swift`, `ArticleCommentFilterTests.swift`.

### 10. Long-form article reading — `ddc05a5`, `62f47ea`, `953f3ee`
Depends on #9 (`953f3ee`'s missing-comments fix needs `Nip22.kindComment`). Closes issue #64.

- **Mentions** (`ddc05a5`): add `MarkdownBlocks.profilePubkey(from:)` / `.profileMentions(in:)`
  (~38 lines); thread `profiles: [String: ProfileData]` through `ArticleInlineText` →
  `ArticleInlineTextRepresentable` → `ArticleInlineFormatter.build`; call `hydrateProfiles(for:)`
  in `ArticleViewModel.load()`. Today `wisp/ArticleView.swift:960-967` unconditionally shortens
  every entity to `@nprofile1q…`.
- **Quoted article as a card** (`62f47ea`): 9 lines. `QuotedNoteView.swift:334-336` branches only on
  kind 9735; add `else if event.kind == 30023 { ArticleFeedPreview(event:relayHints:) }`. The fork
  already has `ArticleFeedPreview.swift` and `relayHints` is already a stored property (`:145`).
- **`953f3ee`** (five sub-fixes): `summary` tag never read; comment query is `kinds = [1]` with
  lowercase-only `aTags`/`eTags` (`ArticleViewModel.swift:101-106`) — needs kind 1111 plus
  `capitalATags`/`capitalETags` on `NostrFilter`; `MarkdownBlocks.swift:86-92` treats a trailing
  `#hashtag` as a heading (needs an `atxHeading(_:)` helper requiring whitespace after `#`);
  body hashtags/mentions aren't tappable (`ArticleInlineTextRepresentable.makeUIView:661` builds a
  bare `UITextView`, needs `ContentSizingTextView` + `wisp-profile://`/`wisp-hashtag://`); no
  share/copy overflow menu or zap row. ~340 lines in `wisp/ArticleView.swift`. The largest single
  item — consider splitting sub-fix 5 (overflow menu) into its own PR if the diff gets unwieldy.

### 11. Notifications default-expanded — `8e639f0`, `5d88efd`
`AppSettings.swift` gains `NotificationFeedStyle`; `NotificationsViewModel.swift:18` swaps the
single-open `expandedItemId` accordion for `collapsedItemIds` + per-row override;
`wisp/NotificationRowView.swift:21,558`; toggle button in `NotificationsView.swift`; row in
`InterfaceSettingsView.swift`. ~140 lines + `NotificationFeedStyleTests.swift` (105 lines).

### 12. Polls and zap comments — `4226105` + `77bb2d2`, `1b83a7f`, `a9a4fc8`
- **Duration presets** (`4226105`, with `77bb2d2` folded in): `PollOptionsEditor.swift:11,106` —
  replace the `showEndDatePicker` toggle + `DatePicker` with a `PollDurationPreset` chip row
  (1h/6h/12h/1d/3d/7d/∞, default 1d) plus a custom-date toggle; add `pollOptions:` +
  `pollPreview(options:)` to `ComposerPreviewCard.swift`, placing the call **after**
  `RichContentView` (that is what `77bb2d2` corrected).
- **Tally leak** (`1b83a7f`): `PostCardView.swift:2244` `pollVotesSection` shows the full split
  unconditionally, bypassing the `hasVoted || ended || isAuthor` gate the body enforces at
  `PollSection.swift:83-86` and `:185-187`. Add `mayRevealVotes(_:)` (~10 lines).
- **Zap comment images** (`a9a4fc8`): new `ContentParser.splitImages` (+51) so an image-only zap
  comment renders inline in the details drawer instead of as a raw URL; `PostCardView` (+86).

### 13. Small correctness batch — `25d5946`, `778276a`, `73df2ff`, `6be7bb0`/`edd93b1`, `e48da50`, `32f4b0c` (scoped down)
- **NIP-05 `_`** (`25d5946`): add a `nip05DisplayString` helper and route 14 call sites through it.
  `Nip05Badge.swift:48` strips `_@` to a bare domain with no `@`; `SearchView.swift:322`,
  `TrendingFeedView.swift:243`, `SidebarDrawerView.swift:68` and `ProfileTabs.swift:561` render the
  raw string, so they show a literal `_@sidecar.top`.
- **Mute copy** (`778276a`): `PostCardView.swift:814` — "Their posts will be hidden from your feed
  and replaced with a placeholder in threads." → "Their posts will be hidden."
- **Onboarding dead-end** (`73df2ff`): `OnboardingView.swift:170-177` — Continue is unconditionally
  `.disabled(!didLongPress)` with no escape. Anyone whose long-press doesn't register (Touch
  Accommodations, AssistiveTouch, motor impairment) is stuck before the account is usable. Add a
  conditional Skip button.
- **Following count** (`6be7bb0`): `ProfileViewModel.swift` — seed `followingCount` from
  `FollowsCache` near `:179` before the task group runs, and make the retry repopulate it once
  `targetWriteRelays` resolves. Today every profile shows "Following: 0" first, and sticks there for
  authors whose kind-3 lives only on their own write relays.
- **Profile main-thread stall** (`e48da50`, second half): move the inline `loadContacts()` retry
  (`:583`) into a `retryContactsIfNeeded()` task inside the group at `:189-192`.
- **Login** (`32f4b0c`, **scoped down deliberately**): upstream deletes `LoginView.swift` and folds
  add-account into `SplashView`. The fork's auth has diverged hard since (Apple sign-in,
  `AppleAuthView`, `SignUpFlowView`), so that refactor is a collision, not a port. Take only the
  real bug it fixed: `LoginView.swift:180` passes `nsecInput` to `NostrKey.parseNsec` untrimmed
  while the QR path (`:152`) and `SplashView.swift:439` both trim — so an nsec pasted from a
  password manager with a trailing newline fails on add-account but works on first run. One line.
  Log the full refactor in the backlog instead.

---

## Phase 2 — backlog, appended to `ZAPCOOKING_IOS_BUILD.md`

Add an **"Upstream carry-over (post-fork Wisp iOS)"** subsection under §5 Phase 5 (P2 fast follows),
recording the fork base `d51f260`, the upstream SHA per item, and the ranking below. Cross-reference
existing issues rather than restating them.

**Recommended to pull forward into Phase 1** (two tiny wallet correctness fixes, ~30 lines total —
flagged because they are cheap and the symptom is alarming, but they fall outside the batch chosen):
1. `3abf5d0` — Spark publishes a **fabricated `0` balance** before the first sync and `WalletStore`
   caches it, so a funded wallet renders a confident "0 sats" and reloads it on next cold launch.
   Gate the zero behind `hasSyncedOnce` (set by `.synced` and by `fetchBalance`'s
   `ensureSynced: true` path). 2 lines.
2. `714e6aa` — don't render a zero balance while one is still loading. 24 lines, `WalletView.swift`.

**Ranked backlog:**
3. **Strict inbox-only routing** — `e3b0f79` + `2ad8bc0` (~130 lines across `ThreadViewModel`,
   `NotificationsViewModel`, `ArticleViewModel`). Deliberately excluded from Phase 1: it removes the
   scored/fallback safety nets so a thread or notification with no discoverable NIP-65 list goes
   **cache-only and sends no query at all**. That is the right direction, but it should land after
   the fork's own relay-decommissioning work (`RelayDecommission`, `RelayListRepair`) settles and
   with a measurement of how many food-community authors actually publish kind-10002. `2ad8bc0` is
   not separable — without it engagement ids burn and the spinner never clears.
4. **On-chain send and receive** — `9a3e067`, `e4e4e09`, plus `5a5fc8a`/`7e526fe`. Already filed as
   issue #63. ~700 lines, 4 new files under `wisp/`. Largest single feature upstream added.
5. **Wallet display correctness** — `978c8ad` (token amounts rendered as sats, +302 lines),
   `57b635c` (conversions mislabelled "Received", +59).
6. **Emoji pack discovery** — `f3dd49b`, `ced9682`, `ec1e088`, `1edf5e1`, `40d4a64` (~500 lines,
   2 new views under `wisp/`). Packs are currently coordinate-pasted only. Includes naddr sharing,
   drifted-relay resolution and a low-quality/offensive filter. Good fit for a food community later;
   no correctness impact.
7. **Feed articles filter** — `c405e5b`. The follows-feed subscription
   (`FeedViewModel.swift:1273`) never requests kind 30023, so articles from follows are invisible,
   and `FeedContentFilter` (`:38-46`) folds articles into `.notes`. Deferred from Phase 1 only
   because `FeedViewModel` is the fork's most-rewritten file (416 lines diverged) and this wants a
   careful reconciliation rather than a patch. Revisit right after #10 lands.
8. **NWC connection-string export** — `64ae96f` (+201-line `wisp/NwcConnectionStringView.swift`).
9. **Lightning-address prompt on the balance screen** — `6df1471` (~26 lines).
10. **Login single-entry refactor** — `32f4b0c` in full (the part scoped out of Phase 1 §13).
    Only worth doing if the fork's auth surface is being reworked anyway.
11. **Repost kind 16** — `9de54de`. Upstream only added a `TODO`; both trees still hardcode `kind: 6`
    in `RepostSender.swift:46` for non-kind-1 targets. No gap versus upstream, but it is a real
    NIP-18 violation in both. File as its own bug rather than a carry-over.

**Not carried (fork diverged deliberately, recorded so nobody re-audits them):**
`1dddc3e` client tag `Wisp` → `Wisp iOS` (the fork sets its own); the Google Drive backup surface
(`GoogleAuth*`, `DriveBackupService.swift`) predates the fork base and was removed on purpose;
upstream has no NIP-56 reporting — `ReportSender`/`ReportSheet`/`ReportedContent`/`Nip56.swift` are
fork-only and must be preserved through every port above.

---

## Verification

Per-PR, before pushing (`AGENTS.md` "Build / run / test"):

```sh
xcodebuild -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation build-for-testing
```

Zero new warnings in touched files. For each concern that adds a root-level Swift file, confirm the
build fails *before* the `project.pbxproj` entry is added and succeeds after — that is the cheapest
proof the registration actually took.

Hermetic gate, serial, on the MacinCloud box, per `GATE.md`:

```sh
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh <branch>
```

Expect `gate: PASS — failure set is exactly the known set`, with no `NEW` line. Record the
`@Test` delta per PR against the 899 baseline (e.g. concern 1 adds `DeletionTests`, ~+18).

Targeted checks beyond the gate:

- **Deletion (#1, #2)** — publish a note, delete it from another client, confirm it disappears from
  feed, thread, search and profile without a relaunch; confirm a quote of it shows "Note deleted by
  its author", not the safety-filter or not-found card. Live-relay check, so it belongs in a
  `.enabled(if:)` live suite like `MemoriesLiveTests`, not the hermetic gate.
- **Relay cap (#5)** — create a poll on an account with a populated scoreboard and assert the
  published kind-1068 carries ≤5 `relay` tags. This is the regression that produced a 21.5 KB event.
- **Content rendering (#3, #4)** — unit-testable end to end; take upstream's four test files verbatim.
- **NIP-22 (#9)** — reply to a kind-1111 comment and assert the published event is kind 1111 with
  `I`/`K` root-scope tags, not kind 1 with NIP-10 tags.
- **Scroll lockup (#7)** — device/simulator only: scroll the home feed down past the new-posts
  threshold, back to top, repeat. Not reproducible in a test.
- **Onboarding skip (#13)** — enable Touch Accommodations in Settings → Accessibility and confirm
  the follow step can still be completed.
