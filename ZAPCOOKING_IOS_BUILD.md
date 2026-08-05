# Zap Cooking — iOS Build Spec

Single running doc that owns the adaptation of the `zapcooking/zapcooking_ios`
Wisp fork into the **Zap Cooking** iOS app. Same role as
`ZAPCOOKING_ANDROID_BUILD.md` in the Android repo: agents read this first,
execute **one concern per PR**, stop at gates for confirmation, and keep this
doc current as state evolves.

**Premise:** the fork already ships a production-grade SwiftUI Nostr client
(~86.6k LOC): Spark wallet, NIP-57 zaps, NIP-17 DMs, NIP-65 outbox routing,
NIP-42 relay AUTH, NIP-23 article rendering, encrypted drafts, scheduled posts,
on-device LightGBM spam filter, ObjectBox cache, Google + Apple sign-in.
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
| Bundle identifier | `barrydeen.wisp` (`build.xcconfig`) |
| Development team | `G738XL8P49` (Barry's) |
| Product name / README | "Wisp" throughout |
| `relay.wisp.talk` / `chat.wisp.talk` | **10 sites** across 8 files — still on upstream infra |
| `relay.damus.io` | **35 Swift files** — and that relay **shut down end of July 2026** |
| Deployment target | iOS **18.0** (Gate 0-C answered; macOS/visionOS targets unchanged) |
| NIP-98 | **Absent** — the membership linchpin does not exist |
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
| Google + **Apple** sign-in | `GoogleSignInManager`, `AppleSignInManager` | Apple Sign-In already present — Guideline 4.8 satisfied |
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
account cannot read Nourish at all. iOS already has the AUTH retry in
`RelayPool`, but verify it against pantry specifically before building on it
(Android's first three attempts all failed on stale-auth and resync ordering —
§7.1).

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
1. Fork hygiene: bundle ID, team, dead relays, Wisp infra, rebrand
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

- **Sign in with Apple** is required because Google Sign-In is offered
  (Guideline 4.8). `AppleSignInManager` already exists — verify it is wired to
  the same key-backup identity path as Google, and that Drive-backed nsec
  restore has an iCloud-or-equivalent story.
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
| **0-A** | **Bundle identifier.** Records conflict: the Capacitor app was created as `com.zapcooking.app`; the passkey work references `cooking.zap.app` bound to Apple Team `Z26TJQZZWC` in the live AASA file. **Verify in App Store Connect which ID owns the shipped listing.** Reusing it ships the native app as an *update* (keeps ratings, installs, reviews); a new ID means a new listing from zero. | Permanent once shipped. Also drives the AASA/passkey binding. |
| **0-B** | Does the native app **replace** the Capacitor listing, or ship alongside it? | Replacement = a hard cutover plan for existing users |
| **0-C** | **Answered: iOS 18.0.** Measured at 18.0 and 26.0 under Xcode 26.3 / Sequoia: identical breakage class (Swift 6.2.3 type-checker — fixed in Concern 0-C-pre / PR #3); **zero** `@available` in source; **zero** availability errors at 18.0. Hard dependency floor is ObjectBox at iOS 15. Xcode 26.3 is the Sequoia ceiling (cannot ship/build against an iOS 26.4 deployment target here). iPad support retained deliberately (`SUPPORTED_PLATFORMS` unchanged; only `IPHONEOS_DEPLOYMENT_TARGET` lowered; `MACOSX_DEPLOYMENT_TARGET` left alone). | Unblocks addressable-base sizing for every screen after |
| **0-D** | **Read-only accounts.** iOS `Signer` is **local-key only** — no NIP-46 bunker, no NIP-55 (that's Android/Amber). Decide whether iOS supports a watch-only mode at all. Android gates NIP-98, Nourish, and recipe publish on "account has a signing key." | Determines how many `canSign` branches exist |
| **0-E** | **Tab architecture.** Wisp is 5 tabs: home / wallet / search / messages / notifications. Food-first needs Recipes and Kitchen. Proposal: **Recipes / OnlyFood / Search / Kitchen / Notifications**, with Wallet and Messages moving into the sidebar drawer. This also reduces §4.2 zap surface area. | Every route lands somewhere |
| **0-F** | **Zaps-on-posts** ship-or-flag (§4.2) | Kill switch must exist before the flag is needed |
| **0-G** | Apple **release + distribution certs**, and whether the Google Cloud project gets an iOS OAuth client registered for this bundle ID | Google sign-in silently fails otherwise (exactly the Android fork-identity bug) |

---

### Phase 0 — Fork hygiene, rebrand, foundation

**Concern 0.1 — Identity.** `build.xcconfig` bundle ID + team → Zap Cooking
(per Gate 0-A). `local.xcconfig.example` updated. Display name "Zap Cooking".
Xcode scheme/product name left alone for now — renaming the `wisp` target is a
`project.pbxproj` minefield and buys nothing (Android made the same call:
`applicationId` changed, class names didn't).

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
`Nip29.defaultGroupRelay` (`chat.wisp.talk`) → `pantry.zap.cooking`;
`RelayProber` / `SignUpViewModel` drop `relay.wisp.talk`; `ProfileView.shareURL`
and `PostCardView` thread links (`wisp.talk/...`) → `zap.cooking/...`;
group-sheet placeholder copy. **Gate: zero `*.wisp.talk` in source.**

**Concern 0.4 — Relay sets.** Add the role-based sets from §2 as a
`RelayConfig`-style enum alongside `RelayDefaults`: `articles`, `members`
(pantry), `discovery`, `profiles`. Keep `RelayDefaults.indexers` as discovery —
do not merge them (Android's CLAUDE.md is explicit: these sets are not supersets
of each other).

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

**GATE 0:** builds and installs on device; a real NIP-98 round-trip the backend
accepts (`owner: true`); no "Wisp" in UI; zero damus; zero wisp.talk; brand
applied. **Do not proceed to Phase 1 until the NIP-98 round-trip passes on a
physical device** — the JVM/simulator can't prove it.

---

### Phase 1 — Recipe read path (P0)

- **1.1 `RecipeParser.swift`** — byte-faithful port of the Kotlin, which is
  itself a port of the web `parseMarkdownForEditing`. **No UI.** Golden test
  against the real *Tuscan Peposo* event including the missing `published_at`,
  missing `servings`, and the live U+FE0F emoji bytes. Android has 14 tests
  here; port all of them.
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
  pull-to-refresh, cache-seeded first paint.
- **1.6 Tap rewiring** — any kind-30023 opens the *recipe* route when
  `RecipeParser.isRecipe`, else the article route, **with a cache-miss guard**
  (evicted event → article fallback, never a recipe screen with no event).
  Apply at every article-tap site.
- **1.7 `RecipeTagFeedView`** + tag catalog browse.
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
  land in P2).
- 3.3 **OnlyFood feed** — kind-1 feed over the ~85-tag `FoodHashtags` set,
  Global | Following modes, **mute-only filtering** (no spam scorer — §7.3),
  per-mode result cache, pull-to-refresh as the only re-query path.
- 3.4 Food-first onboarding: curated creator starter pack (**Seth owes the
  list** — Android's is still the inherited generic set), food-framed copy,
  topic picker, save-a-recipe first-run step.
- 3.5 Nourish **read**: `NourishParser` + pantry NIP-42 read + `NourishCard`
  (green-island visual: strong ≥7 `#22C55E`, moderate 4–6 `#4ADE80`, light 0–3
  `#86EFAC`; soft language for low scores; no letter grades; "Not medical
  advice" footer). Renders **only when a score comes back** — a miss is quiet
  absence, never an error.

---

### Phase 4 — Compliance + submission (P0, runs parallel from Phase 1)

- 4.1 NIP-56 reporting on posts, recipes, and profiles (**not** just groups)
- 4.2 In-app account deletion path
- 4.3 Privacy policy + child-safety links in-app; **web policy corrected first**
- 4.4 App Privacy nutrition label: OpenAI, Blossom, Giphy, Google Sign-In/Drive,
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

**7.1 — Relay AUTH is per-connection, and stale auth state lies.**
Android's pantry reads failed three ways: `authenticatedRelays` was never
cleared on a transient disconnect (so `isAuthenticated` stayed stale-true and
queries fired onto an unauthed socket), and `resyncSubscriptions` re-sent the
tracked REQ on reconnect *before* the fresh socket's AUTH.
→ **iOS action:** iOS has `auth-required` retry in `RelayPool` and
`GroupRelayPool` already, but verify it clears auth state on disconnect and
that reconnect ordering puts AUTH before resubscribe. Test against pantry
specifically, with a forced disconnect, before Phase 3.5.

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

**7.6 — Fork identity breaks OAuth silently.**
Google validates the *calling app* (bundle ID + signing cert) against the Cloud
project owning the client ID. The Android fork inherited Wisp's client ID, so
every sign-in failed with an unhelpful "cancelled or unavailable."
→ **iOS action:** register an **iOS OAuth client** for the new bundle ID in the
Zap Cooking Cloud project (Gate 0-G) before testing Google sign-in. Drive
`appdata` storage is scoped per project, so this is also what makes
cross-platform nsec restore work at all.

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

1. **Gate 0-A** — which bundle ID owns the shipped App Store listing?
2. **Gate 0-B** — replace or coexist with the Capacitor app?
3. **Gate 0-C** — **answered: iOS 18.0** (see §5 Gate 0 table).
4. **Gate 0-D** — read-only accounts on iOS: supported or not?
5. **Gate 0-E** — tab architecture (proposal in §5)
6. **Gate 0-F** — zaps on posts: ship, or profile-only from day one?
7. **Creator starter pack** — the curated food-creator list is still owed on
   *both* platforms
8. **Privacy policy correction** — the two false retention claims block the
   App Privacy label (§4.4). Web-repo work that gates iOS submission.
9. **Timeline** — is there a target submission date, and does it sit before or
   after the Android mid-August Play push?
