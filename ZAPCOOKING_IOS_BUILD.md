# Zap Cooking — iOS Build Spec

Single running doc that owns the adaptation of the `zapcooking/zapcooking_ios`
Wisp fork into the **Zap Cooking** iOS app. Same role as
`ZAPCOOKING_ANDROID_BUILD.md` in the Android repo: agents read this first,
execute **one concern per PR**, stop at gates for confirmation, and keep this
doc current as state evolves.

**Premise:** the fork already ships a production-grade SwiftUI Nostr client
(~86.6k LOC): Spark wallet, NIP-57 zaps, NIP-17 DMs, NIP-65 outbox routing,
NIP-42 relay AUTH, NIP-23 article rendering, encrypted drafts, scheduled posts,
on-device LightGBM spam filter, ObjectBox cache, Apple key recovery (iCloud Keychain).
Zap Cooking is a food-first layer on top. We do **not** rebuild Nostr plumbing
and we do **not** port all 40+ web routes.

**Backend-as-API rule:** AI and membership are server-side on `zap.cooking`.
The app NEVER holds OpenAI/Strike/Stripe keys. It calls HTTPS endpoints; it
does not reimplement them in Swift.

**Android-is-the-reference rule:** where a feature exists on Android, the
Android implementation is the spec — including its bug fixes. Port behavior,
not just shape. §7 lists the fixes that were paid for once and must not be
re-earned.

> Verified against `zapcooking/zapcooking_ios` @ `d51f260` and
> `zapcooking/zap_cooking_android` @ `4389530` (v1.3.6) on 2026-08-04.
> Where this doc and the fork's `AGENTS.md`/`README.md` disagree, this doc
> wins — those still describe upstream Wisp.

---

## 0. Fork state — verified, not assumed

The iOS repo is an **untouched fork**. Nothing has been done yet. Specifically:

| Check | State |
|---|---|
| Zap Cooking commits | **Zero.** Latest commit is upstream `barrydeen/wisp` PR #425 |
| `zapcooking` string in Swift source | **2 matches**, both incidental (a spec doc + a comment) |
| Bundle identifier | `cooking.zap.app` (Concern 0.1; ShareExtension `cooking.zap.app.ShareExtension`) |
| Development team | `Z26TJQZZWC` (Concern 0.1) |
| Product name / README | "Wisp" throughout |
| `relay.wisp.talk` / `chat.wisp.talk` | **Removed** (Concern B) — default group relay is `wss://pantry.zap.cooking`; share URLs are `zap.cooking` shapes |
| `relay.damus.io` | **35 Swift files** — and that relay **shut down end of July 2026** |
| Deployment target | iOS **18.0** (Gate 0-C answered; macOS/visionOS targets unchanged) |
| NIP-98 | **Present** (Concern 0.6) — `Nip98.swift` + `Nip98HeaderCache.swift` |
| NIP-22 | **Absent** — no comments |
| Recipe / food domain | **Absent entirely** |

Two of those are live breakage, not cosmetics: **damus is a dead relay in 41
files**, and **the app phones home to Barry's relay infrastructure**. Both are
Phase 0, before any feature work.

### Build commands (headless / CI)

Open `wisp.xcodeproj` in Xcode, or use `xcodebuild`. On Sequoia the eligible
simulator SDK is currently **26.2** (Xcode **26.3** ceiling).

```
xcodebuild -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
```

`-skipPackagePluginValidation` is required for headless/`xcodebuild` and CI:
`swift-secp256k1` ships a `SharedSourcesPlugin` that fails SwiftPM plugin
validation outside Xcode's interactive trust prompt. Xcode GUI builds that
have already accepted the plugin do not need the flag.

**Test baseline (post Concern 0.6):** default hermetic suite is **194 pass /
1 fail**. The single failure is pre-existing `#4`
(`FeedRenderableTests.mentionTaggedNoteFollowsReplyGate`). That is the prior
174/1 plus the 20 NIP-98 goldens; the live NIP-98 round-trip is opt-in and
**skipped** in the default run (so it does not add a pass or a network
dependency). When the live round-trip is deliberately enabled and green, the
run is **195 pass / 1 fail**. Future gate reports compare against **194/1**
for the default suite, not 174/1.

Default `xcodebuild test` (no network dependency — the live NIP-98 round-trip
is opt-in via `.enabled(if:)` and stays skipped unless deliberately enabled):

```
xcodebuild -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES test
```

**Live NIP-98 round-trip** (opt-in; hits `https://zap.cooking`). Uses an
ephemeral keypair — never a real nsec. Touch the sentinel, run only that
suite, then remove the sentinel:

```
touch wispTests/.nip98_live_enable
xcodebuild -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -only-testing:wispTests/Nip98LiveRoundTripTests \
  test
rm -f wispTests/.nip98_live_enable
```

**Acceptance signal is `owner: true` in the JSON body, NOT bare HTTP 200.**
`POST /api/membership/check-status` silently degrades to the public response
shape on a missing/invalid/mismatched NIP-98 signature rather than returning
401 — so a 200 with no `owner` field means the byte contract is wrong. A
verified ephemeral non-member gets `{"found":false,"owner":true}`.

---

## 1. The audit — inherited free vs net-new

This is the number that should drive scheduling. The Android Zap Cooking delta
is **~28,300 LOC across 117 Kotlin files**. Not all of it ports (Android-only
concerns like Amber/NIP-55 drop out), and iOS inherits more of the plumbing
than Android did — but plan against that order of magnitude, not against
"it's just a recipe screen."

### Inherited free from the Wisp iOS fork (do NOT rebuild)

| Capability | Swift symbol | Why it matters here |
|---|---|---|
| Kind-30023 article load + render | `ArticleViewModel`, `ArticleView`, `ArticleRoute`, `ArticleCache` | Recipe detail branches from this, exactly as Android branched `ArticleScreen` |
| **NIP-42 relay AUTH with `auth-required` retry** | `Nip42.buildAuthEvent`, `RelayPool.query` (L274, L593), `GroupRelayPool.publishWithAuthRetry` | **Big win.** Pantry reads (Nourish) work day one. Android had to build `AuthedRelayReader` from scratch after a multi-day debugging cycle |
| Outbox/inbox routing | `RelayScoreBoard`, `RelayPool`, `GroupRelayPool` | Recipe reads fan out over an articles-relay union; publish goes to write relays |
| Blossom media upload | `BlossomClient.upload`, `GifBlossomUploader` | Recipe cover images |
| Signing | `Signer.sign`, `Schnorr`, `NostrEvent.sign` | Local-key only — see Gate 0-D |
| Zaps / Lightning | `ZapSender`, `Nip57`, `WalletStore`, `SparkWallet`, `NwcWallet`, `Bolt11`, `LnurlResolver` | Also the biggest App Store risk — §4 |
| Lists (NIP-51) | `Nip51Lists`, `Nip51UserLists`, `NoteListRepository` | Saved recipes + cookbooks ride on this |
| Encrypted app data | `Nip78Backup`, `Nip44` | Meal planner + grocery lists are NIP-44 self-encrypted |
| Mute / safety / spam | `SafetyFilter`, `MuteRepository`, `SpamScorer`, `NSpam*` | OnlyFood filtering is mute-only (§7.3) |
| Hashtag feeds | `HashtagFeedViewModel`, `Nip51Hashtags` | OnlyFood feed is a hashtag feed with a curated tag set |
| Deletion | `Nip09`, `DeletionSender` | Recipe delete/tombstone |
| **Apple** sign-in (key recovery) | `AppleSignInManager`, `KeychainBackupService` | Google Sign-In removed (Concern 0.2); SIWA retained for iCloud Keychain nsec backup |
| Drafts + **scheduled posts** | `Nip37`, `DraftsViewModel`, `ScheduleSheet`, `DraftsScheduledView` | iOS is *ahead* of Android here |

### Net-new for iOS (the actual work)

Grouped by phase. Kotlin source → Swift target in §8.

- **Protocol:** `Nip98.swift` (+ header cache), `Nip22.swift`, `RecipeParser`,
  `RecipeSerializer`, `RecipeFormat`/`RecipeFormats` registry, `IngredientScaler`,
  `NourishParser`, `FoodHashtags`, `FoodTopics`, `FoodContentScorer`,
  `RecipeTagCatalog`, `HiddenRecipes`, `RecipeShare`, `RecipeDeletion`,
  `GroceryEvents`, `MealPlanEvents`, `Noffer`
- **API client:** `ZapCookingApi.swift` (~983 LOC on Android; the single
  highest-leverage file in the port)
- **Repos:** Recipe, RecipeBookmark, RecipePack, Nourish, Grocery, Planner,
  RecipePublisher, RecipeTrendCache, NoteReview*
- **UI:** Recipe feed / detail / compose / tag feed, RecipeCard, RecipeBody,
  Cook mode + timers, OnlyFood feed, My Kitchen (Saved / Published / Grocery /
  Planner / Nourish), Sous Chef, Cheffy (+ `CheffyIcon`), NourishCard,
  Nourish Explore, cookbook cards, food onboarding

---

## 2. Protocol & API contracts (source of truth)

Identical to Android — this section is the contract, not a summary of it.
**Corrections to the Android doc are marked ⚠️; the doc there has drifted from
its own code and the Swift port must follow the code.**

### Recipes (Nostr)

- **Recipe:** `kind 30023` (NIP-23 long-form). Feed filter
  `{ kinds: [30023], "#t": ["zapcooking", "nostrcooking"] }`
  (`zapcooking` = current, `nostrcooking` = legacy — support both).
- **Premium:** `kind 35000` + tag `zapcooking-premium`. **Deferred.** Bare
  `kind 35000` is **squatted by an unrelated app** on the public relays. If it
  is ever built, the filter MUST be tag-qualified (`#t: zapcooking-premium`),
  never bare kind.
- Content format is the canonical `# Title` / `## Details` / `## Ingredients` /
  `## Directions` / `## Chef's notes` markdown. `RecipeParser` is a byte-faithful
  port of the web `parseMarkdownForEditing`.
- Known real-world drift already baked into the Android parser contract —
  **port the tolerance, not just the happy path**:
  - `published_at` is **optional** (absent on all new `zapcooking` events,
    present on legacy `nostrcooking`) → fall back to `created_at`
  - `## Details` prep/cook/servings are **all optional and free-text**
    (`"10"`, `"30min"`) → never assume parseable units
  - category t-tags follow `<root>-<category>` (`zapcooking-italian`) plus a
    per-recipe `<root>-<slug>`
  - real d-tags contain `(`, `)`, `/` → **URL-encode at every route boundary**
- `d` tag = `slug(title)`, lowercase + spaces→hyphens ONLY (parens/slashes kept).
  Same title ⇒ same d-tag ⇒ **silently replaces** that author's existing recipe.

### Backend endpoints (base `https://zap.cooking`)

⚠️ **The auth model is mixed and has drifted since the Android doc was written.
Verified against `ZapCookingApi.kt` @ 4389530:**

| Endpoint | Auth | Gate |
|---|---|---|
| `POST /api/extract-recipe/public` | **none** | free, per-IP 8/hr · 30/day |
| `POST /api/extract-recipe` (`type: image`/`text`) | **NIP-98** (`authedPost`) | members; 401 → sign-in, 403 → members-only |
| `POST /api/zappy` (Cheffy) + `/zappy/scan` | **pubkey-in-body** | members; 403 → members-only |
| `POST /api/nourish` + `/nourish/scan` | **pubkey-in-body** | members, fail-closed |
| `GET /api/membership?pubkey=` | none | public batch read |
| `POST /api/membership/check-status` | **NIP-98** | success = `owner: true`; bad sig **silently degrades**, does not 4xx; `403` = server flag off |
| note-review / credit-invoice / credit-status | **NIP-98** | members |
| `GET /api/stats/recipes-by-week` | none | trend pill |

Keep request models auth-agnostic so the remaining pubkey-in-body endpoints are
a one-call swap when the server finishes migrating to NIP-98.

**Timeouts:** every AI endpoint needs a **long-timeout client (~75s)**, not the
general 15s one. Android learned this the hard way on Nourish (LLM + awaited
pantry publish) and Cheffy (whole-response, no streaming). Build
`HttpClientFactory.computeClient` on day one of the API work.

### NIP-98 (the linchpin — net-new on iOS)

Kind 27235. `u` tag, `method` tag, optional `payload` sha256 for POST bodies,
fresh `created_at`, header `Authorization: Nostr <base64(event)>`.

**Match the web verifier's byte reconstruction exactly.** The known footguns,
already paid for on Android:

- the `u` tag is `origin + pathname` **ONLY** — `normalizeUrl` drops the query
  string and fragment and strips a trailing slash on non-root paths
- canonical auth-event JSON is key-ordered `id,pubkey,created_at,kind,tags,content,sig`
  with `created_at` as a **number**, base64'd behind the `Nostr ` prefix
- reference client: frontend `$lib/nip98 signNip98AuthHeader`;
  verifier: `src/lib/nip98.server.ts`

Port Android's `Nip98Test` goldens **verbatim** into `wispTests/` before writing
the implementation. This is the one file where a test-first order is mandatory.

### Nourish (both relay-read AND endpoint-compute)

Read path: **kind 30078**, author = a fixed `NOURISH_SERVICE_PUBKEY`, filter
`#d = "nourish:30023:<author>:<dTag>"`, on **`wss://pantry.zap.cooking`**.
Content is JSON scores; **trust the stored `overall`**, don't recompute.
A miss means the member-gated `POST /api/nourish` computes it and the server
publishes back to pantry for future readers.

Scores are **8 dimensions**: gut, protein, realFood, antiInflammatory,
bloodSugar, immuneSupportive, brainHealth, heartHealth + weighted overall.

⚠️ **Pantry requires NIP-42 AUTH on every read** — even kind 1. A READ_ONLY
account cannot read Nourish at all. The inherited iOS AUTH retry covers
**writes** (`publishWithAuthRetry` / publish-path challenge handling). The
**subscribe / read** path does *not* wait for AUTH — see §7.1 and
https://github.com/zapcooking/zapcooking_ios/issues/6. Hard prerequisite for
Phase 3.5.

### iOS key recovery (Concern 0.2)

Continue with Apple is the cloud recovery path. Architecture:

- **Identity:** `AppleSignInManager` → stable `ASAuthorizationAppleIDCredential.user`.
- **Ciphertext store:** Keychain service `com.wisp.apple-backup`, account
  `wisp_bk_<uuid>`, value = NIP-44 ciphertext of the hex nsec.
- **Sync:** `kSecAttrSynchronizable = true` +
  `kSecAttrAccessibleAfterFirstUnlock` → **iCloud Keychain** (E2E Apple circle
  of trust). Not CloudKit. Not device-only.
- **Local active key:** `NostrKey` / `com.wisp.nostr` uses
  `WhenUnlockedThisDeviceOnly` and is wiped on delete/reinstall; recovery
  re-hydrates from `com.wisp.apple-backup` after SIWA + PIN.
- **KDF:** `BackupCrypto.deriveBackupKey(appleUserID:pin:)` (PBKDF2 600k,
  salt context `wisp-apple-backup`).
- **`AppDataWipe` deliberately does not clear `com.wisp.apple-backup`** — only
  `com.wisp.nostr` — so logout leaves cloud backups intact.
- **Not interchangeable with Android Drive backups.** Android still uses Google
  Drive `appDataFolder` + salt context `wisp-google-backup`. Same PIN on both
  platforms will **not** cross-decrypt. An account created via Android Drive
  cannot be restored on iOS via Continue with Apple (and vice versa). Manual
  nsec export/import remains the cross-platform bridge.

Google Sign-In / `DriveBackupService` / `GIDClientID` were removed from iOS;
Gate 0-G is moot.

### Relays (role-based — do NOT collapse to one set)

- `default`: `nos.lol`, `relay.primal.net`, `relay.nostr.net`
- `members`: `wss://pantry.zap.cooking`
- `discovery`: `nostr.wine`, `relay.primal.net`, `purplepag.es`
- `profiles`: `purplepag.es`
- `articles` (**recipes**): `relay.primal.net`, `nos.lol`, `nostr.wine`,
  `eden.nostr.land`, `relay.noswhere.com`

**Recipes live on the public article relays, not on Pantry.** Adding Pantry as
the members relay is correct; replacing the aggregators breaks recipe loading.
Treat `articles` as a **union** — coverage is uneven (`nostr.wine` has returned
0 on live probes).

`relay.damus.io` is **decommissioned** — delete, don't replace. Sole-relay at
exactly one site (`SearchViewModel.engagementFallbackRelays`), resolved by
collapsing onto `RelayDefaults.fallbacks`. Every other site is co-listed.
`notify.damus.io` does not appear in this codebase — that host is Android-only
(`RelayPool.kt:502`). No preservation needed.

---

## 3. Priority order — what ships in v1

Ranked. The cut line is after P1.

### P0 — Blocking. Nothing ships without these.
1. Fork hygiene: bundle ID + team (**0.1 done**), dead relays, Wisp infra, rebrand
2. Deployment-target decision (Gate 0-C) — **answered: iOS 18.0**
3. App Store payments posture (§4) — decided **before** any UI work, because
   it determines whether the wallet tab survives
4. Recipe read path: parser → repository → detail screen
5. Recipe feed + tag browse (the app's reason to exist)
6. Compliance surface: NIP-56 reporting on all content, privacy policy link
   in-app, account deletion link, App Review demo account

### P1 — Must-have for a credible v1 (this is the differentiation)
7. Recipe compose (create from scratch) + publish
8. Sous Chef URL import → preview → save
9. Saved recipes + "My Kitchen" hub (Saved / Published minimum)
10. OnlyFood feed (the foodstr social layer)
11. Nourish **read** (cheap on iOS — NIP-42 already exists — and it is the most
    visible thing that makes this app not-a-generic-Nostr-client)
12. Cook mode + timers
13. Food-first onboarding (topics, creator starter pack, save-a-recipe)

### P2 — Fast follow after approval
14. Cheffy chat (+ save-to-recipes hand-off)
15. Nourish compute + Nourish Explore
16. Grocery lists + meal planner
17. NIP-22 comments on recipes
18. Recipe trend pill, Memories, recipe packs / cookbooks

### P3 — Deferred, tracked so they aren't lost
19. Note Review (Cheffy note critique) + Lightning credit purchase — **this one
    is an App Store landmine, see §4.3**
20. Premium recipes (kind 35000) — blocked on real events existing
21. CLINK / noffer payments
22. Cookbook AI intro — blocked on recipe packs
23. Recipe edit-in-place

**Rationale for the cut line:** the historical App Store rejection was
**Guideline 4.2 (minimum functionality)** against the Capacitor wrapper. The
defense is not feature count — it's *native depth*. A polished recipe reader +
creator + food feed with real native gestures, offline cache, and haptics beats
a broad-but-shallow port of everything. Ship P0+P1, get approved, then land P2
as updates.

---

## 4. App Store constraints — the section Android didn't need

This is the highest-risk part of the project and it shapes the architecture, so
it is decided **before** Phase 1, not at submission time.

### 4.1 Guideline 4.2 — Minimum Functionality (the historical rejection)

The Capacitor build was rejected repeatedly. Native SwiftUI clears 4.2 on its
own, but reviewers look for *app-like* behavior. Concretely, the v1 must have:
native navigation stacks (already there), gesture-driven interactions, haptics,
offline cache behavior (ObjectBox is already there — make it visible: recipes
should render from cache with no network), and no web view carrying the primary
experience. **Do not embed `zap.cooking` in a `WKWebView` for any core feature.**

### 4.2 Guideline 3.1.1 — zaps (the Damus precedent)

In 2023 Apple forced Damus to remove **zaps on posts**, treating tips connected
to digital content as IAP-requiring; zaps at the **profile** level were allowed.

The practical landscape has moved since. <cite index="18-1">Primal ships a built-in non-custodial Lightning wallet on iOS and its zap support is central to the app</cite>, and <cite index="20-1">Primal v3.0 in March 2026 added zap-based poll voting and NIP-47 NWC wallet support</cite> — so post-level zaps are evidently being approved in practice today. But that is precedent-by-observation, not a written guideline change, and review is uneven.

**Ruling: ship zaps, but behind a kill switch.** Mirror Android's
`MEMBERSHIP_LINKOUT_ENABLED` pattern with a compile-time flag
(`FeatureFlags.zapsOnPosts`) that collapses post-level zap affordances to
profile-level only. If review pushes back, the fix is a flag flip and a
resubmit, not a refactor. Budget one rejection round.

### 4.3 Guideline 3.1.1 / 3.1.3(b) — selling Cook+ and AI credits

Seth's stated target architecture is already the safest one available:
**the app sells nothing.** Users buy Cook+ on the web; the app reads the
pubkey-keyed entitlement server-side and unlocks Cheffy / Sous Chef / Nourish.
That is the Guideline 3.1.3(b) multiplatform-services shape.

Rules that follow from it, and are **not negotiable in v1**:
- **No purchase UI, no checkout, no price displayed in-app.**
- **No link-out to `zap.cooking/membership`.** US-storefront link-outs became
  permissible without an entitlement in May 2025, but <cite index="7-1">outside the US, linking out to your own web checkout for digital goods generally still requires the StoreKit External Purchase Link Entitlement</cite>, and <cite index="5-1">shipping external-link UI without a region check fails review for non-US regions and can get the entitlement revoked</cite>. The situation is also unsettled — the Supreme Court took the Epic contempt question in June 2026. A global app with no link at all has zero exposure. **Ship no link.**
- Gated features show a **message only** — "Cook+ members feature" — with no
  CTA. This is exactly the Android `MembersOnly` message-only pattern; reuse
  the copy.
- **`requestCreditInvoice` / `checkCreditStatus` (Lightning pay-per-use for
  Note Review) must NOT ship on iOS in v1.** Paying Lightning in-app to unlock
  an in-app AI feature is the single clearest 3.1.1 violation in the whole
  Android codebase. It is P3 for a reason. If it ever ships, it ships as IAP.

### 4.4 Other iOS-specific requirements

- **Sign in with Apple** is **no longer required by Guideline 4.8** — Google
  Sign-In was removed (Concern 0.2), so no third-party login remains. SIWA is
  **retained as the key-recovery path** (iCloud Keychain + PIN); see §2
  "iOS key recovery".
- **Account deletion in-app** (Guideline 5.1.1(v)). `zap.cooking/delete-account`
  is live and is the Android answer; iOS needs it reachable *in-app*, not just
  as a policy link.
- **Content reporting + blocking** (Guideline 1.2, UGC). Android's NIP-56
  reporting is wired only into group rooms — **do not repeat that gap.** iOS
  needs Report on feed posts, recipes, and profiles from day one. UGC apps get
  rejected for this routinely.
- **Privacy policy link in-app** and an accurate **App Privacy nutrition label**.
  ⚠️ The published privacy policy has two known-false claims about not
  retaining user content on centralized servers, contradicted by the OpenAI
  forwarding paths and the pubkey-keyed membership/credit records. **The policy
  must be corrected before the App Privacy label is filled out**, or the label
  will be wrong too. This is a web-repo task that blocks iOS submission.
- **Age rating**: the Market is 18+ gated on web; the stated app floor is 13+.
  Confirm the rating matches what the app actually exposes.
- **Encryption export compliance**: the app ships secp256k1, NIP-44, ChaCha20.
  `ITSAppUsesNonExemptEncryption` must be set correctly in `Info.plist`.

---

## 5. Phases (stop-gated; one concern per PR)

### Gate 0 — decisions Seth owns, before any code

| # | Decision | Why it blocks |
|---|---|---|
| **0-A** | **Answered: `cooking.zap.app` / team `Z26TJQZZWC`.** Matches the live AASA/passkey binding. There is no shipped App Store listing (Capacitor never passed review); an orphaned ASC draft will be reused — not a migration. | Permanent once shipped. Also drives the AASA/passkey binding. |
| **0-B** | **Answered / moot.** Capacitor never passed review, so there is no live listing to replace or coexist with. Native app reuses the orphaned ASC draft under `cooking.zap.app`. | No cutover plan required |
| **0-C** | **Answered: iOS 18.0.** Measured at 18.0 and 26.0 under Xcode 26.3 / Sequoia: identical breakage class (Swift 6.2.3 type-checker — fixed in Concern 0-C-pre / PR #3); **zero** `@available` in source; **zero** availability errors at 18.0. Hard dependency floor is ObjectBox at iOS 15. Xcode 26.3 is the Sequoia ceiling (cannot ship/build against an iOS 26.4 deployment target here). iPad support retained deliberately (`SUPPORTED_PLATFORMS` unchanged; only `IPHONEOS_DEPLOYMENT_TARGET` lowered; `MACOSX_DEPLOYMENT_TARGET` left alone). | Unblocks addressable-base sizing for every screen after |
| **0-D** | **Read-only accounts.** iOS `Signer` is **local-key only** — no NIP-46 bunker, no NIP-55 (that's Android/Amber). Decide whether iOS supports a watch-only mode at all. Android gates NIP-98, Nourish, and recipe publish on "account has a signing key." | Determines how many `canSign` branches exist |
| **0-E** | **Tab architecture.** Wisp is 5 tabs: home / wallet / search / messages / notifications. Food-first needs Recipes and Kitchen. Proposal: **Recipes / OnlyFood / Search / Kitchen / Notifications**, with Wallet and Messages moving into the sidebar drawer. This also reduces §4.2 zap surface area. | Every route lands somewhere |
| **0-F** | **Zaps-on-posts** ship-or-flag (§4.2) | Kill switch must exist before the flag is needed |
| **0-G** | **Moot / struck.** Google Sign-In was removed from iOS (Concern 0.2), so no Google Cloud iOS OAuth client is needed. Remaining open piece under this number if reused later: Apple **release + distribution certs** only. | — |
| **0-H** | ✅ **RULED (Seth, Aug 9): *"DMs should be open to any relay."*** Resolves all three parts — **(a) no**, we do not publish a kind-10050 on a member's behalf; **(b) moot**, there is no default value because there is no default list; **(c) moot**, nothing to reschedule. Publishing a kind-10050 *is* the act of narrowing a member's DM delivery to a named relay set, so "open to any relay" is the state of not having one. The member keeps the capability — `RelaySettingsView` already adds and broadcasts DM relays on their instruction (`:286`) — we simply stop guessing on their behalf. **Build spec: Concern 0.8.** *Reading note, correct me in one word if wrong:* the ruling could instead have meant "widen our DM read subscription to every relay." I did not take that reading — `MessagesViewModel:113-119` documents why the read set is bounded (an unbounded `kind:1059` REQ pinned open on every relay floods the main actor and starves the shared connection pool), and the ruling answers the seeding question that was on the table. **The definition and evidence below stand as the record of why.** ⤵<br><br>This is **not** a client-side constant. The app **signs and publishes a replaceable kind-10050 into the member's own account**, once per account, from `RelaySettingsRepository.ensureDmRelayList` (`:113-153`), reached at every launch via `MainView.swift:343` → `bootstrap`. A kind-10050 is cross-client and supersedes by `created_at`, so whatever we write there is where **every** Nostr client that member uses will route their DMs. Current value is the inherited Wisp constant `RelaySettingsRepository.defaultDmRelay = "wss://auth.nostr1.com"` (`:44`); its own NIP-11 (probed Aug 9) reads `auth_required: true`, `payment_required: false`, operator `7cc328a0…`, and describes itself as *"a 'DM Inbox Relay' running alpha software. By using it you can help us test the functionality."* **Three decisions, not one:** (a) do we publish a 10050 on the member's behalf **at all**, given DMs appear nowhere in §3's P0–P3 list; (b) if yes, **what value**; (c) **when** — at launch, as today, or at first use of Messages. **Prep's recommendation: (a) yes, (b) keep the inherited value for now, (c) move the seed to first use of Messages.** The record is permanent and cross-client, and today we write it before the member has opened Messages once. Deferring costs nothing until someone actually uses DMs, which is the moment it becomes true for them. **Pantry is not an available answer:** `rejectEventPolicy` falls through to "membership required" for kind 1059 (`member-relay relay/main.go:511-514` @ `06e70c8`), and the sender of a gift wrap AUTHs as an ephemeral key that is never a member — inbound DMs would be rejected. Two existing safeguards are sound and should survive any ruling: the seed runs at most once per account, and only on a **connectivity-confirmed** absence (`relaysResponded > 0`), so it cannot supersede a real list we merely failed to fetch. Watch-only accounts are already skipped (`:116`) — ties to **0-D**.<br><br>**Two publish paths, not one** *(Chief, Aug 9; verified).* `SignUpViewModel.finishProfileStep:357-360` also calls `addDmRelay(defaultDmRelay:)` during account creation. `addDmRelay` (`RelaySettingsRepository:237-243`) guards only on `normalize` and already-present — no once-flag, no connectivity check, no `dmRelays.isEmpty` gate — then publishes. It hits **every new account**, whereas `ensureDmRelayList` only fires for accounts that arrive without a 10050 (mostly imported keys). The silent-data-loss risk is nil on the signup path (a fresh key has no prior list), but any (c) ruling has to move **both** paths or it does not reach its own stated goal.<br><br>**The relay requires the *sender* to AUTH** *(Prep, Aug 9; probed).* Live probe of `wss://auth.nostr1.com` with a browser UA: the relay sends `["AUTH",<challenge>]` unprompted on connect, answers a pre-auth `REQ` with `CLOSED … "auth-required: you must auth"`, and answers a pre-auth `EVENT` with `OK false "auth-required: you must auth"` — returned **before** signature validation (the probe event carried an all-zero sig). So writes are gated too: a NIP-17 sender must complete NIP-42 with its **ephemeral** gift-wrap key to deposit into this inbox. **That is a design choice, not a defect** — read-AUTH keeps the member's gift-wrap `#p` index off public view, and write-AUTH is spam control. But it means the value we seed decides *whose client can reach our member*, and the failure is silent (`OK false` is a frame most clients never surface). **This is the substance of decision (b): deliverability vs. DM metadata privacy.** Either way it should not arrive as an inherited constant.<br><br>**Our own read path is not the exposure** *(Prep, Aug 9; answers Chief's issue #6 question).* Issue #6's four defects are in `GroupRelayPool`. The DM subscription does not use it — `MessagesViewModel.start:54` opens a persistent `RelayPool.subscribe`, which runs on `RelayConn`, and `RelayConn.receiveLoop` **does** handle NIP-42: it ignores a `CLOSED … auth-required` without tearing the sub down (`RelayPool.swift:593-596`) and re-issues every REQ after signing the challenge (`:603-611`). Against the frame order the probe actually observed — AUTH first, CLOSED second — that recovers. **Member DM reads are therefore not silently empty today, and #6's blast radius does not reach DMs.** Two bounded caveats: `RelayConn` shares #6's defect 2 in weaker form (recovery depends on the relay *volunteering* an AUTH frame, because the `auth-required` CLOSED branch waits rather than requesting one), and a watch-only account never AUTHs, so its DM subscription closes silently — ties to **0-D**. Verified by source read plus relay probe, not by running the app.<br><br>**Publishing nothing is not total unreachability.** `MessagesViewModel.resolveDmSubscriptionRelays:120-134` already unions the member's kind-10050 relays with their NIP-65 **read** relays, precisely so we catch copies a sender deposited in the NIP-65 inbox because they could not find a 10050. On our own read side we lose nothing by not seeding. Both options make reachability a property of the *sender's* client — one needs them to AUTH, the other needs them to fall back to NIP-65 — but only one of them writes a permanent record into the member's account. | ✅ **Closed Aug 9.** Build is **Concern 0.8** — three deletions, two fallbacks, one UI guard and one string; it is *not* a pure deletion (see 0.8). Blocks nothing, but the seed is **live in every build today**, so this lands before first TestFlight alongside issue #1. |

---

### Phase 0 — Fork hygiene, rebrand, foundation

**Concern 0.1 — Identity.** `cooking.zap.app` / team `Z26TJQZZWC` /
display name "Zap Cooking". ShareExtension `cooking.zap.app.ShareExtension`;
tests `cooking.zap.app.Tests` / `cooking.zap.app.UITests`; App Group
`group.cooking.zap.app` (entitlements ×4 + `PendingShareStore`). Applied in
`build.xcconfig`, `local.xcconfig.example`, and the matching
`DEVELOPMENT_TEAM` / `PRODUCT_BUNDLE_IDENTIFIER` / display-name keys in
`project.pbxproj` (target settings override xcconfig — both must move).
Xcode scheme/product/`wisp/` folder names left alone — renaming buys nothing
with no installed base to migrate.

**Concern 0.2 — Kill the dead relay.** Remove `wss://relay.damus.io` from all
35 Swift production files. Mechanical deletion, no replacement at co-listed
sites. Sole-relay at exactly one site
(`SearchViewModel.engagementFallbackRelays`), resolved by collapsing onto
`RelayDefaults.fallbacks`. Every other site is co-listed.
`notify.damus.io` does not appear in this codebase — that host is Android-only
(`RelayPool.kt:502`). No preservation needed.
Grep gate (production Swift only; test fixtures may keep the hostname):
`grep -rn 'relay\.damus\.io' --include=*.swift . | grep -v '^\./wispTests/'`
must return nothing. Also audit for a **persisted-prefs prune** — if any user's
stored relay list can contain damus, it needs a load-time filter, because
Android found onboarding had permanently written a dead relay into some
accounts' prefs. On iOS the blast radius is higher: the dead relay can be
signed into a published kind-10002. Filed separately; do not inherit the bug.

**Concern 0.3 — Relay sovereignty.** Off Wisp infra entirely:
`Nip29.defaultGroupRelay` → `wss://pantry.zap.cooking`; `RelayProber` /
`SignUpViewModel` drop `relay.wisp.talk`; share URLs remapped to real
zap.cooking shapes (`/user/{npub1…}`, `/{nevent1…}` / `/{note1…}` — not a
hostname swap of `/profile/` or `/thread/`); group-sheet placeholder copy.
**Gate: zero `*.wisp.talk` in source.** Groups on pantry require a **signing
account** (watch-only cannot AUTH — #6). Whether the groups UI ships in v1 at
all is still an **open decision**.

**Concern 0.4 — Relay sets.** Add the role-based sets from §2 as a
`RelayConfig`-style enum alongside `RelayDefaults`: `articles`, `members`
(pantry), `discovery`, `profiles`. Keep `RelayDefaults.indexers` as discovery —
do not merge them (Android's CLAUDE.md is explicit: these sets are not supersets
of each other).
**Not blocked on Gate 0-H** (Prep, Aug 9 — overridable). These four are
client-side read-fanout constants. A DM inbox relay is a different kind of
thing: a signed kind-10050 in the *member's* account, not our routing config.
No 0-H outcome changes any of the four values. If a fifth `dm` role is wanted
in the enum it can point at the existing `RelaySettingsRepository.defaultDmRelay`
(`:44`) without knowing the ruling — the enum's shape does not depend on it.
0.4 can start now.

**Concern 0.5 — Branding.** App name, theme (brand primary `#ec4700` /
`#ff5722`, danger `#dc2626`/`#ef4444`, ported from web `src/app.css` and
Android `ui/theme/BrandColors.kt`), app icon + splash from frontend assets,
NIP-89 client tag **"Zap Cooking"** (must match web), User-Agent
`ZapCooking-iOS/1.0`, onboarding seed account → the Zap Cooking npub
(`319ad3e7…`), crash-report recipient likewise. README rebranded with the
MIT / Barry Deen attribution preserved.

**Concern 0.6 — `Nip98.swift`.** Test-first (§2). Port Android's golden tests
verbatim, then implement. Add `Nip98HeaderCache` equivalent.

**Concern 0.7 — `ZapCookingApi.swift`.** The API client, `computeClient` (75s)
vs general client, error mapping (401 → sign-in, 403 → members-only, 429 →
rate limit, `{ok:false}`-on-200 → error), and the response models.
Start with `getPublicMembership` + `checkMembershipStatus` only.

**Concern 0.8 — Stop seeding a DM inbox relay (Gate 0-H).** *Spec Prep, Aug 9,
verified at `654e4e4`; casualty analysis independently re-verified by Chief and
extended, Aug 9. One PR. Lands before first TestFlight, with issue #1.*

Seth ruled DMs open to any relay, so the app stops publishing a kind-10050 on a
member's behalf. **This is not a pure deletion**, and that is the part worth
reading: `dmRelays` is not only the DM inbox — it is also the delivery address
for DIP-03 private zaps and private reactions. `RelaySettingsRepository.shared
.dmRelays` is read at **eleven call sites across nine files** — five on the
send side (`ZapSender:90`, `ZapSheet:171`, `DmReactionPublisher:107`,
`PrivateReplyPublisher:57`, `PrivateReactionPublisher:33`), five on the read
side (`MessagesViewModel:125`, `DmConversationViewModel:123` and `:497`,
`NotificationsViewModel:609` via its own kind-10050 query, `RelaySettingsView
:261`), and one in the repository's own broadcast path (`:402`). Three of the
five send-side consumers already fall back correctly when it is empty and say
so in their own comments; **two do not**, and the seed was hiding that. Delete
the seed without them and two features go dark for every member on the same
commit.

*Delete:*
- `RelaySettingsRepository.ensureDmRelayList` (`:113-153`) and its call from
  `bootstrap` (`:100`); the `dmAutoSeedKey` helper (`:155`) goes with it.
- `SignUpViewModel.finishProfileStep:357-360` — the `addDmRelay` call — and the
  now-unused `wispDmRelay` constant (`:139`).
- `RelaySettingsRepository.defaultDmRelay` (`:44`). Those three were its only
  consumers, so **the app ends up with no default DM relay anywhere**, which is
  the ruling stated as code.

*Keep:* `addDmRelay` (`:296` add path) / `removeDmRelay` (`RelaySettingsView
:296`) / `broadcastDm` (`:305`) — member-initiated. The ruling removes our
guess, not their control. **One of the three needs a UI guard the seed was
providing for free — see "The fourth publish path" below.**

*The fourth publish path — the one the ruling itself opens* (Chief, Aug 9;
re-verified by Prep at source, Aug 9). `publishDm` (`RelaySettingsRepository
:398-409`) has **no empty guard**: `Nip51Lists.buildRelaySetListTags([])` is a
`compactMap` over the input (`:156-158`), so an empty list yields `[]` tags and
the repository **signs and publishes a kind-10050 carrying zero relay tags** at
`max(dmUpdatedAt + 1, now)`. Three callers: `addDmRelay` (non-empty by
construction), `removeDmRelay`, and `broadcastDm:253` — which is the
**"Broadcast DM Relays"** button (`RelaySettingsView:113`, label `:270`, action
`:305`), enabled, sitting on the DM tab. Today the seed guarantees a non-empty
list, so the button cannot do this. **After 0.8, empty is every member's
default state, so the first tap of a button that looks inert publishes a
permanent, superseding, cross-client record saying their DM inbox list is
empty** — the act the ruling forbids, reached through the UI instead of the
bootstrap.

Two things sharpen it, both checked rather than assumed:

- **Where it goes.** `publish(...)` targets `Set(topWriteRelays + Self
  .indexerRelays + extraRelays)` (`:435`). `extraRelays` is `dmRelays` — empty,
  so it contributes nothing — but `RelaySettingsRepository.indexerRelays` is
  `RelayDefaults.onboarding` (`:40`, **not** `RelayDefaults.indexers` despite
  the name), which contains `indexer.coracle.social` and
  `indexer.nostrarchives.com` alongside three high-volume general relays. So the
  empty list lands **on indexer-grade relays** — precisely where another
  client's kind-10050 lookup resolves.
- **Why empty is plausibly worse than absent** (stated as a risk, not a
  certainty). The whole reachability argument is that a sender deposits in the
  NIP-65 inbox *because it could not find a kind-10050*. An empty one **is**
  found. Whether a given client reads that as "no list, fall back" or as an
  explicit empty answer is client-dependent, and it supersedes by `created_at`
  — it cannot be unpublished, only replaced.

**Ruled — hide the Broadcast button on the DM tab when `repo.dmRelays.isEmpty`;
do not disable it.** A disabled control invites the member to work out how to
enable it, and here there is nothing to enable; the same button is enabled one
tab over, so a greyed-out one reads as a defect rather than as an honest
"nothing to broadcast." Nothing is lost by hiding it: `addDmRelay` already
publishes on add (`:243`), so Broadcast only ever re-announces an existing list.
**Scope the hide to the Button at `:113` only — not the Section at `:110`**,
which also contains "Sync Relay List (NIP-65)" (`:120-149`); that one is useful
on every tab in every state, and a sloppy read of this instruction takes it out.

*`removeDmRelay` stays unguarded, and that is deliberate* — a member deleting
their last DM relay is instructing us to publish that. Guarding both is the
tempting symmetric fix and it breaks the one that is correct. Same shape as the
migration ruling: surface it, never rewrite it.

*General / Search / Blocked share the missing `publishXxx` empty guard and stay
out of 0.8* — none of them becomes an everyone-default state, so for those three
an empty list still only arrives by member instruction. Recorded so the
asymmetry reads as a decision rather than an oversight.

*Fallbacks the deletion requires (both make "no kind-10050" a supported state,
which today it only half is):*
- `ZapSheet.privateZapAvailable:171` returns false when `dmRelays.isEmpty`, so
  the `.private` zap type is filtered out of `availableZapTypes` — **private
  zaps would vanish from the UI for everyone.** It also already contradicts
  `ZapSender:87-98`, which explicitly refuses to refuse ("never refuse to send
  when they're empty") and falls back to NIP-65 write + scoreboard. The sheet's
  own doc comment states the premise — *"so the user never selects an option
  that's guaranteed to fail at send time"* — and that premise is **false today,
  before 0.8 touches anything** (Chief, Aug 9). **Delete exactly one line, not
  the guard.** `privateZapAvailable` has four conditions and three are correct
  and load-bearing: `eventId == nil` (`ZapSender:78` really does return
  `.nostrZapsNotSupported` for profile and a-tag stream zaps), `NostrKey.load()`
  failing, and `Hex.decode(privkey) == nil` (remote signer / watch-only — DIP-03
  needs the real privkey to sign the inner kind-9733). Only
  `if RelaySettingsRepository.shared.dmRelays.isEmpty { return false }` comes
  out. The sender is right about relays; the sheet is right about everything
  else.
- `PrivateReactionPublisher:33-34` hard-`guard`s on `!ownRelays.isEmpty` and
  throws `noOwnRelays`, with **no fallback** — unlike its three siblings
  (`PrivateReplyPublisher:57-65`, `DmReactionPublisher:105-110`,
  `ZapSender:90-98`), each of which falls back to NIP-65 write relays and
  carries a comment explaining why. Port the same fallback verbatim — **and
  port the line above it too.** `PrivateReplyPublisher:56` and
  `DmReactionPublisher:106` both call
  `RelaySettingsRepository.shared.ensureLoaded(pubkey:)` before reading
  `dmRelays`; `PrivateReactionPublisher` does not. That is a **second,
  pre-existing defect on the same line**: a member who *has* a kind-10050 list
  can still hit the throw when the repository has not yet loaded from disk.
  Copying only the fallback fixes the 0.8 casualty and leaves that one live.

*Verified NOT casualties (do not "fix" these):* `MessagesViewModel:120-134`
and `DmConversationViewModel.resolveOwnRelays:495-501` already union DM with
NIP-65 read.

`NotificationsViewModel:609-611` is the one that will look like a receive-side
regression and is not — **it is in this list because it is the most plausible
false positive in the change, and someone will "fix" it in six months** (Chief,
Aug 9; verified at source). It gates `subDmZaps` on `!dmRelays.isEmpty`, and
its own comment says the per-event engagement subscription never queries DM
relays, so it reads like the only path by which a member sees an incoming
private zap. Two things have to hold, and both do:

- **Delivery.** `f4` is `kinds:[9735] pTags:[pubkey]` — the same event class as
  `f1` (`:552`), differing only in relay set. After 0.8 a private-zap sender
  hits `ZapSender:86-98` and falls back to the recipient's NIP-65 **read**
  relays, and `notifRelays` (`:331-336`) is built from those same read relays.
  The receipt lands where `f1` is already listening and `subDmZaps` correctly
  goes dormant. **The same fallback chain that makes the ruling work covers the
  receive side.** Same for `fanInZapReceiptToEngagement` (`:627`, called only on
  the `f4` handler): the engagement subscription queries the target author's
  read relays, which is now where the receipt is.
- **Classification**, which "same event class" does *not* by itself buy. `f4`
  ingests with `isFromDmRelay: true` (`:617`), `f1` with `false` (`:559`), and
  that flag feeds `isPrivateZap: isPrivate || isFromDmRelay`
  (`NotificationRepository:550`). It survives because `isPrivate` is decoded
  from the receipt, not inferred from the relay: `classifyZap:532` takes it from
  `Nip57.resolveZapSender(...)`, and our own sender always publishes DIP-03 for
  private zaps (`ZapSender:75-88`). A private zap still renders as private.

*Residue, one line so nobody restores it thinking it still does something:*
`NotificationRepository:527-529` keeps `isFromDmRelay` as a defensive fallback
for **legacy** receipts from the pre-DIP-03 homegrown private-zap path, which
carry no `isPrivate` signal of their own. After 0.8 `dmRelays` is empty by
default, so `f4` never opens and that fallback is structurally dead. Accepted:
the population is non-DIP-03 clients, iOS has not shipped, and such a receipt
would have been deposited on a DM relay we no longer subscribe to anyway.

*Pre-existing, not introduced by 0.8, recorded so it is not discovered as a
surprise* (Chief): `notifRelays = Array(combined.prefix(10)).sorted()` where
`combined` is a **Set** — it takes ten in hash order and *then* sorts, so which
read relays survive the cap is nondeterministic. The coverage argument above
holds in the common case and rests on that cap.

*One string, Growth's — and it is one string serving four surfaces.*
`RelaySettingsView:73` is `Text("No \(tab.rawValue.lowercased()) relays yet")`,
interpolated across **general / dm / search / blocked** (`currentUrls:258-265`).
Rewriting it for the DM case rewrites the other three, so the work is either a
dm-specific branch or copy that reads correctly for all four tabs. After this
ruling the dm empty state is **every member's default state**, not an edge case,
and must not read as though DMs are broken. Two constraints from the surrounding
view, both checkable:

- The add-relay field sits **above** the empty state (`:57`), so the affordance
  already exists — the string does not need to teach the member how to add one.
- That field is `.disabled(keypair.isWatchOnly)` at 0.4 opacity (`:63-64`), so
  **the same empty state renders with and without a usable exit.** Copy that
  says "add one" is false for watch-only accounts. Ties to **0-D**.
- Fixes the lowercased-enum rendering ("No dm relays yet") on the way through.

**Copy delivered (Growth, Aug 9) — split accepted, one clause held.**

*Structure — ruled, build to this.* Branch the DM case out of the shared
interpolation rather than stretching one template over four tabs. Growth's
reason is the right one and it is the same rule the Android settings row came
down on: **general / search / blocked all mean "not set up yet," which is a
correct to-do reading for them; after 0-H, dm empty is the intended steady
state.** One template cannot carry both truths — soften it enough to be honest
for dm and it goes vague for the other three.

- **General / Search / Blocked — unchanged:** `"No \(tab) relays yet"`.
- **DM — static, no interpolation. FINAL, ship this literal:**

```swift
"No DM relays set. We look for your messages on the General relays you read from."
```

*Locked by Growth, Aug 9 (`b9773ad4`), after two amendments it survived. Both
are recorded because each one killed a version that read as finished:*

1. **"regular relays" → "General relays."** `Tab.general` has raw value
   `"General"` (`:18`) and is rendered as a literal segment in the picker two
   lines above the empty state (`:37`). "Regular" is a term that exists nowhere
   in the app; it came from Prep's prose, not from the product.
2. **No reachability claim, and no whole-General-list implication.** *"You're
   still reachable"* is a claim about **other people's clients** — whether a
   NIP-17 sender deposits in the NIP-65 inbox depends on that sender falling
   back when it finds no kind-10050, and some refuse to send at all. We have
   not measured the distribution and must not imply one. The replacement then
   overclaimed one notch narrower: `resolveDmSubscriptionRelays:120-134` unions
   `dmRelays` with `RelayListRepository.getReadRelays(pubkey)` — the
   **read-marked** subset — and its own comment says it deliberately does not
   union the whole general list (an unbounded `kind:1059` REQ pinned open on
   every relay floods the main actor). "Your General relays" is therefore false
   for any relay the member has marked write-only. The shipped wording asserts
   only what **we** do, verifiable at `MessagesViewModel:120-134`, and still
   answers the only question the member is asking ("am I broken?").

*Superseded draft — do not pick this up* (`e98694e7`, 15:56:51, composed before
the resolution and posted after it): *"No DM relays added — your messages
already send fine using your regular relays."* It regresses on both amendments
at once — "already send fine" is the reachability claim, "regular relays" is the
word that was wrong twice. Recorded here because a superseded draft that reads
like a finished recommendation is exactly what gets found six months later.

*Antecedent verified:* the "General relays" referent exists for new accounts —
`SignUpViewModel:402` publishes a kind-10002 at signup.

*Two residues on the string, both accepted, neither a fix* (Prep, Aug 9, at
source):

- **"the General relays you read from" is not the set in one case, and it fails
  in the safe direction.** `getReadRelays:38-43` is not a pure read-marked
  filter — when the read list is empty it **falls back to write relays**
  ("so that anyone who follows them still has a chance"). A member who has
  turned the `read` chip off on every relay (`RelaySettingsView:216-220`,
  reachable from our own UI) therefore reads a sentence naming an empty set
  while we are in fact searching their write relays. It **underclaims** rather
  than overclaims — it never promises coverage we do not have — and the state is
  deliberate and self-inflicted. Not worth a second branch.
- **The chips the sentence points at are on a different tab.** `relayRow` renders
  the read/write chips only when `tab == .general` (`:215`), so a member reading
  the DM empty state has to switch tabs to check the claim. Checkable, one tap
  away, not on-screen.

*Correction to the flagged 0-D edge case — it does not exist as stated.* "A
member with no read-marked general relay has no coverage at all" is false for
the reason above: `getReadRelays` cross-falls back to write. The genuine
zero-coverage account is one with **no kind-10002 at all**, which is degraded in
every direction rather than only in DMs, and is already recorded in the
antecedent note. **Nothing goes to 0-D from this string.** Recorded explicitly
so nobody builds for a hole that isn't there.

*Not in scope, flagged:* accounts that already published a 10050 pointing at
`auth.nostr1.com` keep it. Editing it for them is the same act the ruling
forbids. iOS has not shipped, so the population is test accounts; surface it,
never rewrite it.

**GATE 0:** builds and installs on device; a real NIP-98 round-trip the backend
accepts (`owner: true`); no "Wisp" in UI; zero damus; zero wisp.talk; brand
applied. **Do not proceed to Phase 1 until the NIP-98 round-trip passes.** On
iOS the simulator runs the same Swift and the same crypto over real networking,
so a simulator round-trip is sufficient evidence (the Android "physical device"
requirement was about JVM unit tests vs on-device JNI secp256k1).

---

### Phase 1 — Recipe read path (P0)

- **1.1 `RecipeParser.swift`** — byte-faithful port of the Kotlin, which is
  itself a port of the web `parseMarkdownForEditing`. **No UI.** Golden test
  against the real *Tuscan Peposo* event including the missing `published_at`,
  missing `servings`, and the live U+FE0F emoji bytes. Android has **23** tests
  here; port all 23. Source:
  `app/src/test/kotlin/cooking/zap/app/nostr/RecipeParserTest.kt` at
  `zap_cooking_android` **`4389530`** (the commit this doc is verified against).
  ⚠️ An earlier revision of this line said 14 — that is the count of the block
  *above* the `private fun event(...)` helper at `:199`, which sits mid-file and
  reads like the end of it. Below the helper are **9 more**, all
  `isRecipe_*` / `validate_*`. Those 9 are the ones with downstream teeth:
  `RecipeParser.isRecipe` is the gate **1.6** uses to choose the recipe route
  over the article route, and `isRecipe_rejectsArticleCarryingRecipeTag` is
  exactly the case that otherwise lands a plain article on a recipe screen.
  Port 14 and the gate function ships untested.
- **1.2 `RecipeRepository.swift`** — `{kinds:[30023], #t:[zapcooking,nostrcooking]}`
  fanned out to the **articles union**, deduped by addressable coordinate
  (`kind:author:dTag`) newest-wins with the NIP-01 equal-`created_at`
  lower-id tiebreaker. `requestRecipe(author:dTag:)` resolves cache-first then
  via the same union — **not** the general article path, which routes to the
  wrong relays. The repo **owns** the recipe flow; detail and feed both consume
  it (one shared dedup).
- **1.3 `RecipeDetailView`** — branched from `ArticleView`. Hero, summary,
  prep/cook/servings chips, chef's notes, ingredients, numbered directions.
  Engagement bar reused (zap/react/repost per Gate 0-F). Route
  `recipe/{author}/{dTag}` with the **d-tag URL-encoded** — real d-tags carry
  `(`, `)`, `/`.
- **1.4 `IngredientScaler.swift`** — ½× / 1× / 2× / 3× chips scaling the
  **leading numeric token only** (secondary alt-measures stay unscaled).
  Understands integers, decimals, unicode + mixed + ascii fractions, ranges;
  returns the line **verbatim when unparseable** — never crashes, never mangles.
  Servings chip scales; free-text prep/cook do not.
- **1.5 `RecipeFeedView` + `RecipeCard`** — the Recipes tab. Infinite scroll,
  pull-to-refresh, cache-seeded first paint. **Also flips the default launch
  tab back to `.recipes`** (`MainView.swift`) in the same PR — it is parked on
  `.search` while this tab is a placeholder.
  **Landed:** `RecipeFeedView` / `RecipeCardView` / `RecipeFeedViewModel`;
  `RecipeRepository.load` paints ObjectBox before the union and never wipes
  that paint on an empty answer; default tab is `.recipes`.
- **1.6 Tap rewiring** — any kind-30023 opens the *recipe* route when
  `RecipeParser.isRecipe`, else the article route, **with a cache-miss guard**
  (evicted event → article fallback, never a recipe screen with no event).
  Apply at every article-tap site.
  **Landed:** `ArticleTapRouting` is the single gate (`opensAsRecipe` is
  false on `nil`). Applied at `ArticleFeedPreview`, `ArticleCardView`,
  `QuotedNoteView`, home-feed card tap, `SearchView`, `ProfileTabs`
  (notes / replies / conversation), hashtag / trending / people-list /
  note-list feeds, and the notifications `onNoteTap` choke point.
  `RecipeCardView` already used `RecipeRoute`. No article/recipe URL
  deep-link handler exists (`onOpenURL` is share-extension only).
  Badge (`RECIPE` / `ARTICLE`) uses the same gate so label and
  destination agree; unknown event → `ARTICLE`.
- **1.7 `RecipeTagFeedView`** + tag catalog browse.
  **Landed:** `RecipeTagCatalog` (Android curated list; per-recipe
  `<root>-<slug>` tags are not browse categories), `RecipeTagFeedView` /
  VM over `RecipeRepository.loadTagFeed` (`tagFeedFilter`, cache-first,
  mute-only, own submit path so the mounted Recipes tab is not cancelled).
  Popular chips + More sheet on the Recipes tab; detail category chips
  push the same route. **Gate:** browse at least three categories with
  real results off live relays.
- **1.8 Cook mode** — keep-screen-on (`isIdleTimerDisabled`), step paging,
  inline timers, scaling carried through. Timers need a **Live Activity /
  background story** on iOS that Android didn't need — scope it explicitly.

**GATE 1:** a real recipe off live relays renders correctly on device,
including a legacy `nostrcooking` one and one with a parenthesized d-tag.

---

### Phase 2 — Create + import (P1)

- **2.1 `RecipeSerializer.swift`** — inverse of the parser. `d = slug(title)`,
  `t:zapcooking` + `t:zapcooking-<slug>` + `t:zapcooking-<category>`, image
  tags, **no `published_at`**. **Round-trip tested** (serialize → parse →
  equals) against the real Tuscan Peposo event.
- **2.2 `RecipeFormat` seam** — port the registry abstraction
  (`RecipeFormat` protocol + `Nip23RecipeFormat` thin adapter + `RecipeFormats`
  registry + the `Nip333RecipeFormat` stub). This exists so a future recipe NIP
  plugs in without rewriting screens. Porting it *now* is cheap; retrofitting
  it later is not. ⚠️ Carry the dual-write caveat in the doc comment:
  rank-before-recency can mask a newer low-rank edit.
- **2.3 `RecipePublisher.swift`** — Blossom re-host of the cover image
  (**fallback to source URL so Save never blocks**) → sign kind-30023 → cache
  optimistically → publish to write relays **+ broadcast to the articles
  relays** so it appears in the feed.
- **2.4 `RecipeComposeView`** — dedicated full-screen form (**not** an extension
  of the note composer): title, categories, summary, chef's notes,
  prep/cook/servings, add/remove ingredient & direction rows, multi-image
  picker, additional resources. Images upload to Blossom **as picked**;
  publish is **blocked while any upload is pending or failed**. Validation
  shows the **reason** on the button — never a silent disable.
- **2.5 Sous Chef** — URL field → free anon `/api/extract-recipe/public` →
  structured preview via the shared recipe body → Save routes into 2.4.
  Image/text import is NIP-98 + member-gated (P2).

**GATE 2:** publish a recipe from the device, confirm it renders on
`zap.cooking` web and in the Android app.

---

### Phase 3 — Food identity + My Kitchen (P1)

- 3.1 Saved recipes (NIP-51 bookmark sets over `RecipeBookmarkRepository`
  semantics) — ⚠️ port the **first-save cold-session guard**: a cold session
  must not overwrite an existing saved-recipe collection (Android 1.3.5 fix).
- 3.2 My Kitchen hub: Saved / Published tabs (Grocery / Planner / Nourish
  land in P2). Retires the `.kitchen` placeholder; the tab becomes a valid
  launch/deep-link destination in the same PR.
- 3.3 **OnlyFood feed** — kind-1 feed over the ~85-tag `FoodHashtags` set,
  Global | Following modes, **mute-only filtering** (no spam scorer — §7.3),
  per-mode result cache, pull-to-refresh as the only re-query path. Retires
  the `.onlyfood` placeholder; the tab becomes a valid launch/deep-link
  destination in the same PR.
- 3.4 Food-first onboarding: curated creator starter pack (**Seth owes the
  list** — Android's is still the inherited generic set), food-framed copy,
  topic picker, save-a-recipe first-run step.
- 3.5 Nourish **read**: `NourishParser` + pantry NIP-42 read + `NourishCard`
  (green-island visual: strong ≥7 `#22C55E`, moderate 4–6 `#4ADE80`, light 0–3
  `#86EFAC`; soft language for low scores; no letter grades; "Not medical
  advice" footer). Renders **only when a score comes back** — a miss is quiet
  absence, never an error.
  **Hard prerequisite:** fix
  https://github.com/zapcooking/zapcooking_ios/issues/6 (subscribe path must
  wait for / re-fire after NIP-42 AUTH). Without that, pantry reads silently
  return empty — including Nourish.

---

### Phase 4 — Compliance + submission (P0, runs parallel from Phase 1)

- 4.1 NIP-56 reporting on posts, recipes, and profiles (**not** just groups)
- 4.2 In-app account deletion path
- 4.3 Privacy policy + child-safety links in-app; **web policy corrected first**
- 4.4 App Privacy nutrition label: OpenAI, Blossom, Giphy,
  Cloudflare analytics (IP + coarse location), crash-report DM relays
- 4.5 `ITSAppUsesNonExemptEncryption`; export compliance
- 4.6 App Review demo account (a seeded npub with recipes + an active Cook+
  entitlement so reviewers can see gated features work)
- 4.7 Screenshots, description, keywords, age rating
- 4.8 Kill switches verified: zaps-on-posts flag flips cleanly; no membership
  link-out anywhere; credit-purchase code not compiled in

---

### Phase 5 — P2 fast follows

Cheffy (+ `CheffyIcon` ported from the web SVG, brand copy pools, save-to-recipes
hand-off), Nourish compute + Explore, grocery lists + meal planner (NIP-44
self-encrypted, `GroceryEvents`/`MealPlanEvents`), NIP-22 comments, trend pill,
Memories, recipe packs.

---

## 6. Conventions for agents

- **One concern per PR.** Investigate first, surgical diffs, no stacking.
- **`project.pbxproj` is a trap.** Files added to the **repo root** are NOT
  picked up automatically — they need an explicit `PBXFileReference` entry.
  Files inside `wisp/`, `wispTests/`, `wispUITests/` are synchronized folders
  and are exempt. **Every new root-level Swift file must be registered.**
  A build that "can't find the type you just wrote" is almost always this.
- New NIPs are standalone root-level `NipXX.swift` objects (matches the fork).
- View models: `@Observable @MainActor final class` (Observation, not Combine).
- Storage and shared collectors are `actor`s.
- CPU-bound work (parsing, scaling, ML) on `Task.detached(priority: .utility)`.
  The project defaults to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so pure
  compute silently pins to main unless marked `nonisolated` — this already
  caused a 5–10s freeze upstream on DM decryption. Mark recipe parsing
  `nonisolated`.
- Tests: Swift Testing (`import Testing`, `@Test`) under `wispTests/`.
- Never hand-edit `model-wisp.json`; regenerate `EntityInfo-wisp.generated.swift`
  into **both** `generated/` and the repo root when entities change.
- Secrets are gitignored bundled resources in `wisp/Resources/` (Breez, Giphy).
  **Do not introduce xcconfig+Info.plist secret injection** — follow the
  existing pattern.
- Any backend-contract change lands in **this doc** before the PR merges.

---

## 7. Lessons carried from the Android fork — do not re-earn these

Each of these cost real debugging time on Android. They are listed with the iOS
action, not just the story.

**7.1 — Relay AUTH is per-connection, and the inherited iOS retry is writes-only.**
Android's pantry reads failed three ways: `authenticatedRelays` was never
cleared on a transient disconnect (so `isAuthenticated` stayed stale-true and
queries fired onto an unauthed socket), and `resyncSubscriptions` re-sent the
tracked REQ on reconnect *before* the fresh socket's AUTH.
→ **iOS finding (Concern B):** `RelayPool` / `GroupRelayPool.publishWithAuthRetry`
cover **writes**. The **subscribe / read** path does not: (1)
`GroupRelayPool.subscribe` has no `waitForAuthIfNeeded`; (2) CLOSED
`auth-required` sleeps 2s and replays once instead of awaiting AUTH; (3)
`isAuthenticated` flips when the AUTH event is *sent*, not accepted; (4)
reconnect clears auth then re-REQs filters before AUTH. Watch-only never AUTH
(missing keypair) → silent empty rooms. Tracked as
https://github.com/zapcooking/zapcooking_ios/issues/6 — **Phase 3.5 blocker**
(Nourish reads pantry on the same path). Reference: Android
`collectAuthCompleted` re-fire.

**7.2 — Subscription IDs must be process-wide unique.**
An instance-scoped counter restarted at 0 per nav back-stack entry, so
re-entering a screen within the previous instance's ~14s teardown let the old
instance's `CLOSE` kill the *new* subscription.
→ **iOS action:** any new subscription ID uses a process-wide atomic sequence.

**7.3 — Do not run the spam scorer inside a feed collector.**
OnlyFood came back empty on device. Root cause was `score()` running inside the
collector: it over-filtered hashtag- and link-heavy food posts at the ≥0.7
threshold, and an exception there could cancel the whole stream.
→ **iOS action:** OnlyFood filtering is **mute-only** in v1. If spam filtering
is added later, it goes in a `try/catch` with keep-on-error, and the threshold
is validated against real food posts first. Also audit any *existing* iOS
`SpamScorer`-inside-collector sites for the same latent cancellation bug.

**7.4 — Search relays rate-limit per connection.**
Identical filter, same connection: 99 events, then 0 events twelve seconds
later. Toggling feed modes re-queried every time, so every toggle after the
first went blank.
→ **iOS action:** OnlyFood keeps a **per-mode result cache**. Switching modes
swaps to the cached results with **no relay query**. A mode is queried once
(marked loaded on completion **regardless of event count**, so a legitimately
empty mode isn't re-throttled). Pull-to-refresh is the only re-query path.

**7.5 — Teardown CLOSE storms cause the throttling.**
Android was sending ~450 stray CLOSE frames per teardown by sweeping a fixed
subId range across all connections.
→ **iOS action:** close **only the subIds actually opened**, on the relays they
were opened on. Serialize load/toggle/pagination through one submit path that
cancels the previous job before issuing the next REQ.

**7.6 — Fork identity breaks OAuth silently (Android lesson; iOS moot).**
Google validates the *calling app* (bundle ID + signing cert) against the Cloud
project owning the client ID. The Android fork inherited Wisp's client ID, so
every sign-in failed with an unhelpful "cancelled or unavailable."
→ **iOS action:** **n/a** — Google Sign-In was removed from iOS (Concern 0.2 /
Gate 0-G struck). Keep this lesson for Android and for any future third-party
OAuth. iOS key recovery is Apple / iCloud Keychain only (see §2).

**7.7 — Optional fields in real data.**
`published_at` absent, `servings` absent, free-text prep/cook times. Live relay
coverage uneven. Real d-tags contain URL-hostile characters.
→ **iOS action:** already folded into §2. Test against **real events**, not
synthesized fixtures.

**7.8 — Same title ⇒ same d-tag ⇒ silent replace.**
→ **iOS action:** mirror the web's "make your title unique" caption. A
collision warning is a known gap, still open on Android.

**7.9 — Deletion must carry the right kind.**
A list fork/editor pushed a cover image onto the source event instead of the
republished one and silently deleted covers; a separate bug built kind-5
tombstones with the wrong `deleteKind`.
→ **iOS action:** derive `deleteKind` from `event.kind`, and include both `a`
and `k` tags on tombstones. Port `RecipeDeletion` behavior, not just its shape.

**7.10 — Sign a release build from the build system, not the IDE.**
Android's signing was Android-Studio-wizard-based, so only one machine could
produce a shippable artifact.
→ **iOS action:** wire signing + archive into `ci_scripts/` / `xcodebuild` with
credentials outside the repo, and **fail loudly** when they're absent.

**7.11 — The README lies after a fork.**
Android's README advertised removed features for weeks. This doc exists so
there's one place that doesn't.
→ **iOS action:** `AGENTS.md` gets a header pointing here as the system of
record, in Concern 0.5.

**7.12 — ObjectBox shadows `Int64(_: UInt64)` under MemberImportVisibility.**
ObjectBox declares `extension Swift.Int64: ObjectBox.UntypedIdBase {
init(_ entityId: ObjectBox.Id) }` with `Id == UInt64`. Under Swift 6
MemberImportVisibility that concrete overload beats the stdlib generic
init, so ANY file doing `Int64(someUInt64)` without `import ObjectBox`
fails to compile. Qualifying `Swift.Int64` does not help — the colliding
init is an extension ON Swift.Int64. Use `Int64(exactly:)!` to preserve
trapping without importing ObjectBox.
→ **iOS action:** never `import ObjectBox` into non-storage files to paper
over this; never substitute `truncatingIfNeeded` (wraps) or `numericCast`
(opaque). Prefer `Int64(exactly:)!`.

---

## 8. Symbol map — Kotlin → Swift

Port targets, roughly in build order. LOC is the Kotlin source size, as a
rough effort signal only.

| Kotlin (Android) | LOC | Swift target | Phase |
|---|---|---|---|
| `nostr/Nip98.kt` + `Nip98HeaderCache.kt` | 245 | `Nip98.swift` | 0.6 |
| `api/ZapCookingApi.kt` | 983 | `ZapCookingApi.swift` | 0.7 |
| `nostr/RecipeParser.kt` | 419 | `RecipeParser.swift` | 1.1 |
| `repo/RecipeRepository.kt` | 1174 | `RecipeRepository.swift` | 1.2 |
| `ui/screen/RecipeDetailScreen.kt` + `ui/component/RecipeBody.kt` | 590 | `RecipeDetailView.swift` (branch `ArticleView`) | 1.3 |
| `viewmodel/RecipeDetailViewModel.kt` | 182 | `RecipeDetailViewModel.swift` | 1.3 |
| `nostr/IngredientScaler.kt` | 188 | `IngredientScaler.swift` | 1.4 |
| `ui/screen/RecipeFeedScreen.kt` + `RecipeCard.kt` | 1243 | `RecipeFeedView.swift`, `RecipeCardView.swift` | 1.5 |
| `viewmodel/RecipeFeedViewModel.kt` | 158 | `RecipeFeedViewModel.swift` | 1.5 |
| `ui/screen/RecipeTagFeedScreen.kt` + `nostr/RecipeTagCatalog.kt` | 280 | `RecipeTagFeedView.swift` | 1.7 |
| `viewmodel/CookingTimerViewModel.kt` + `FloatingTimerBar.kt` + `TimerCompletionOverlay.kt` | 476 | `CookingTimerStore.swift`, `FloatingTimerBar.swift` | 1.8 |
| `nostr/RecipeSerializer.kt` | 169 | `RecipeSerializer.swift` | 2.1 |
| `nostr/RecipeFormat.kt` + `RecipeFormats.kt` + `Nip23RecipeFormat.kt` + `Nip333RecipeFormat.kt` | 374 | `RecipeFormat.swift` … | 2.2 |
| `repo/RecipePublisher.kt` | 390 | `RecipePublisher.swift` | 2.3 |
| `ui/screen/RecipeComposeScreen.kt` + `viewmodel/RecipeComposeViewModel.kt` | 996 | `RecipeComposeView.swift` + VM | 2.4 |
| `ui/screen/SousChefScreen.kt` + `viewmodel/SousChefViewModel.kt` + `souschef/*` | 1172 | `SousChefView.swift` + VM | 2.5 |
| `repo/RecipeBookmarkRepository.kt` | 985 | `RecipeBookmarkRepository.swift` | 3.1 |
| `nostr/FoodHashtags.kt` + `FoodTopics.kt` + `repo/OnlyFoodFilter.kt` | 277 | `FoodHashtags.swift` … | 3.3 |
| `viewmodel/OnlyFoodFeedViewModel.kt` + `ui/screen/OnlyFoodFeedScreen.kt` | 1136 | `OnlyFoodFeedViewModel.swift` + View | 3.3 |
| `nostr/NourishParser.kt` + `repo/NourishRepository.kt` | 639 | `NourishParser.swift`, `NourishRepository.swift` | 3.5 |
| `ui/component/NourishCard.kt` + `NourishSectionPanels.kt` | 442 | `NourishCard.swift` | 3.5 |
| `nostr/Nip56.kt` + `ui/screen/ReportsScreen.kt` | 398 | reporting surface | 4.1 |
| `ui/screen/CheffyScreen.kt` + `viewmodel/CheffyViewModel.kt` + `cheffy/Cheffy.kt` + `CheffyIcon.kt` | 804 | `CheffyView.swift` … | 5 |
| `mealplan/*` + `repo/GroceryRepository.kt` + `PlannerRepository.kt` + `nostr/GroceryEvents.kt` | 1550 | grocery + planner | 5 |
| `nostr/Nip22.kt` | 169 | `Nip22.swift` | 5 |
| `util/RecipeTrend.kt` + `repo/RecipeTrendCache.kt` + `RecipeTrendPill.kt` | 460 | trend pill | 5 |

**Explicitly NOT ported:** `nostr/SignerIntentBridge.kt`,
`RemoteSigner` (NIP-55/Amber is Android-only), the `zapstore`/`play` flavor
machinery, `repo/NofferClient.kt` + CLINK (P3), and
`requestCreditInvoice`/`checkCreditStatus` (§4.3 — must not ship on iOS).

---

## 9. Open questions Seth owns

1. **Gate 0-A** — **answered: `cooking.zap.app` / `Z26TJQZZWC`** (see §5 Gate 0).
2. **Gate 0-B** — **answered / moot** — no live Capacitor listing; reuse orphaned ASC draft.
3. **Gate 0-C** — **answered: iOS 18.0** (see §5 Gate 0 table).
4. **Gate 0-D** — read-only accounts on iOS: supported or not?
5. **Gate 0-E** — tab architecture (proposal in §5)
6. **Gate 0-F** — zaps on posts: ship, or profile-only from day one?
   ⚠️ §4.2 already carries a written ruling (compile-time
   `FeatureFlags.zapsOnPosts` kill switch, budget one rejection round). Confirm
   §4.2 is a ruling and this closes; say it was a proposal and it stays open.
6a. **Gate 0-H** — **CLOSED Aug 9: "DMs should be open to any relay."** We stop
   publishing a kind-10050 on a member's behalf; there is no default DM relay.
   Build is **Concern 0.8** (three deletions + two fallbacks + one UI guard +
   one string — not a pure deletion; private zaps and private reactions ride
   the same list, and the "Broadcast DM Relays" button becomes a fourth publish
   path the moment the seed is gone).
7. **Creator starter pack** — the curated food-creator list is still owed on
   *both* platforms
8. **Privacy policy correction** — the two false retention claims block the
   App Privacy label (§4.4). Web-repo work that gates iOS submission.
9. **Timeline** — is there a target submission date, and does it sit before or
   after the Android mid-August Play push?
