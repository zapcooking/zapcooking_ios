# Zap Cooking iOS — Port Roadmap & Feature Comparison

**Living document.** Current as of 2026-08-11 against
`zapcooking_ios` @ `fb1a41f`, `zap_cooking_android` @ `83a77935` (v1.3.6),
and `wisp-ios` @ `6df1471`.

**Companion to `ZAPCOOKING_IOS_BUILD.md`** — that file is the system of
record for protocol/API contracts, event kinds, relay sets, App Store
constraints, and the original phase/concern breakdown. This file holds
what that doc does not: (a) current port **status**, (b) the
**Android↔iOS feature comparison**, (c) a **refreshed sequence** against
today's reality. Where the two overlap on a contract, the build spec
wins. Where this doc says a concern is done/stub/absent, it reflects the
code today, not the spec's original §0 snapshot (which predates any Zap
Cooking commits).

---

## 1. The three codebases

| Repo | HEAD | Size | Role |
|---|---|---|---|
| `zap_cooking_android` | `83a77935` (v1.3.6) | 405 Kotlin files, ~132k LOC | **The reference.** "Port behavior, not just shape" (build spec §premise). |
| `zapcooking_ios` (this repo) | `fb1a41f` | ~86.7k LOC | The port target. Phase 0 ~half done; Phase 1+ is scaffolding only. |
| `wisp-ios` (upstream) | `6df1471` | ~286 root Swift files | Forked at `d51f260` (PR #425, 2026-07-28). One commit ahead; negligible merge debt. |

## 2. Scope reality — most of "Android" is inherited, not ported

Both apps are forks of Wisp. The feed, profile, thread, search, DMs
(NIP-17), groups (NIP-29), notifications, live streams (NIP-53), social
graph, wallet (Spark + NWC), zaps (NIP-57), Blossom, NSpam,
drafts/scheduled posts, account switcher, and Apple iCloud Keychain
recovery are **inherited plumbing already present on iOS** — iOS forked
from the same parent. iOS is even *ahead* of Android on drafts/scheduled
posts.

The real work is the **food delta: ~28k LOC across ~117 Kotlin files**,
plus iOS-specific App Store and platform adaptation. A slice of the
delta **must not be ported** (§6).

---

## 3. Decisions locked

- **Gate 0-E — Tab architecture (DECIDED 2026-08-11): the Spec
  proposal.** Five tabs: **Recipes / OnlyFood / Search / Kitchen /
  Notifications**, with **Wallet and Messages moved into the sidebar
  drawer.** Rationale: food-first, and it minimizes zap surface area for
  App Store review (build spec §4.2). Wallet can be promoted back to a
  tab after approval. This diverges from Android's layout
  (Feed/Recipes/Wallet/Messages/Notifications) — an intentional,
  documented divergence, not a port bug.

## 4. Open decisions (still Seth's)

- **Gate 0-D — Read-only accounts.** Android ships full `READ_ONLY`
  mode (no key, `ReadOnlyBottomBar`, gates all signing). iOS `Signer` is
  local-key only. Cheapest v1 is to *not* support watch-only, at the
  cost of a parity gap and no external-key story.
- **External signing (NIP-46).** Android uses NIP-55 (Amber), an
  Android-only path it explicitly does *not* implement as NIP-46. iOS
  has no external signer. NIP-46 is the only cross-platform
  bunker-signer NIP and would be net-new (Android lacks it). Likely
  **post-v1**. (Per global guidance, use Amber/Primal as NIP-46
  examples; do not reference nsec.app.)
- **Gate 0-F — Kill switches.** No `FeatureFlags` type exists yet.
  Needed before zap UI. Small but prerequisite.

---

## 5. Current port status (Phase 0 is ~half done)

9 Zap Cooking commits since the fork point (`d51f260`). Working tree
clean.

| Concern | Status | Evidence |
|---|---|---|
| 0.1 Identity | ✅ Done | `cooking.zap.app` / team `Z26TJQZZWC` / App Group `group.cooking.zap.app` in build.xcconfig + pbxproj + entitlements |
| 0.2 Dead relay (`relay.damus.io`) | ✅ Done — gate passes | production Swift grep clean; tests retain hostname (allowed) |
| 0.3 Wisp sovereignty | ✅ Done | zero `*.wisp.talk`; `pantry.zap.cooking` default group relay; `zap.cooking` share URLs |
| 0.4 Relay role sets (articles/members/discovery/profiles) | ❌ Not started | `RelayDefaults` has only `indexers/fallbacks/onboarding`; no role sets |
| 0.5 Branding (#ec4700, NIP-89 "Zap Cooking", UA, seed npub, splash) | ❌ Not started | theme still Wisp orange `#D9730D`; UA still `Wisp/1.0`; splash renders `Text("wisp")`; README "Wisp" ×14 |
| 0.6 NIP-98 | ✅ Done — high quality | `Nip98.swift` + `Nip98HeaderCache.swift` real; 20 offline + 1 opt-in live golden |
| 0.7 `ZapCookingApi.swift` | ❌ Not started | file absent; no `computeClient` (~75s) tier in `HttpClientFactory` |
| 0-C Deployment target iOS 18.0 | ✅ Done | |
| 0-D Read-only accounts | Open | `Signer` local-key only |
| **0-E Tab architecture** | ✅ **Decided** (this doc §3) | code not yet changed — `MainView.BottomTab` still Wisp's 5 tabs |
| 0-F Zaps kill switch | ❌ Not started | no `FeatureFlags` |
| 0-G Google Sign-In | ✅ Struck moot | removed in `bfa3ea3` |

**Recipe "stubs" (commit `fb1a41f`) are contract-only scaffolding.** Six
files — `RecipeParser`, `RecipeSerializer`, `IngredientScaler`,
`RecipeFormat`, `RecipeFormats`, `Nip23RecipeFormat` — plus six matching
*empty* test shells. Every function body is `fatalError("unimplemented")`.
The doc-comment contracts are thorough and define the API surface; there
is zero executable behavior. No recipe repository, UI, feed, card,
compose, cook mode, Sous Chef, Nourish, OnlyFood, Cheffy, grocery,
planner, or NIP-22 file exists. The inherited `ArticleView` /
`ArticleViewModel` / `ArticleCache` (the branch point for
`RecipeDetailView`) are present and ready.

---

## 6. Feature gap matrix

Legend: ✅ inherited/ready · 🟡 stub only · ❌ absent · 🚫 do-not-port
(App Store) · LOC = Kotlin source size (port effort signal).

### Tier 1 — Recipe core (P0/P1: the app's reason to exist)

| Feature | Android LOC | iOS | Phase |
|---|---|---|---|
| RecipeParser (byte-faithful) | 419 | 🟡 `fatalError` stub | 1.1 |
| RecipeRepository (articles-union reads, dedupe by `kind:author:dTag`) | 1174 | ❌ | 1.2 |
| RecipeDetailView + VM (branch `ArticleView`) | 590 + 182 | ❌ (ArticleView ✅ base) | 1.3 |
| IngredientScaler (½×/1×/2×/3×; unicode + mixed + ASCII fractions, ranges) | 188 | 🟡 stub | 1.4 |
| RecipeFeedView + RecipeCard | 1243 + 158 | ❌ | 1.5 |
| Tap rewiring (recipe route vs article route + cache-miss guard) | — | ❌ | 1.6 |
| RecipeTagFeed + tag catalog (30 categories) | 280 | ❌ | 1.7 |
| Cook mode + timers (keep-screen-on, step paging, **iOS Live Activity**) | 476 | ❌ | 1.8 |
| RecipeSerializer (round-trip; `mergeForEdit` preserves unknown tags) | 169 | 🟡 stub | 2.1 |
| RecipeFormat seam (registry: `RecipeFormat` + `Nip23` + `Nip333` stub) | 374 | 🟡 stubs | 2.2 |
| RecipePublisher (Blossom re-host + broadcast to write ∪ articles relays) | 390 | ❌ | 2.3 |
| RecipeComposeView + VM | 996 | ❌ | 2.4 |
| Sous Chef (URL/image/text import → preview → save) | 1172 | ❌ | 2.5 |
| RecipeDeletion (blanked replacement + kind-5 tombstone) / Share / HiddenRecipes | ~210 | ❌ | 2.1–2.3 |

### Tier 2 — Food identity & social (P1)

| Feature | Android LOC | iOS | Phase |
|---|---|---|---|
| **`ZapCookingApi` (the API client — prereq for ALL AI features)** | 985 | ❌ (no `computeClient` tier) | **0.7** |
| RecipeBookmarkRepository (Saved; kind 30001; cold-session guard) | 985 | ❌ (Nip51Lists ✅ inherited) | 3.1 |
| My Kitchen hub (Saved/Published/Grocery/Planner/Nourish sub-tabs) | inside RecipeFeed | ❌ | 3.2 |
| OnlyFood feed (~85 food hashtags; Global/Following; mute-only; per-mode cache) | 1136 + 277 | ❌ (HashtagFeedVM ✅ inherited) | 3.3 |
| Food onboarding (topics, creator starter pack, save-a-recipe) | — | ❌ | 3.4 |
| Nourish read + NourishCard (8-dim scores; green-island visual) | 639 + 442 | ❌ — **blocked on issue #6** | 3.5 |

### Tier 3 — P2 fast-follows (after approval)

| Feature | Android LOC | iOS | Phase |
|---|---|---|---|
| Cheffy chat + CheffyIcon (brand SVG port) | 804 | ❌ | 5 |
| Nourish compute + Explore (6 filter chips, label-namespace ranking) | +267 | ❌ | 5 |
| Grocery lists (NIP-44 self-encrypted, kind 30078) | 1550 | ❌ | 5 |
| Meal planner (7 days × 4 slots) | (in 1550) | ❌ | 5 |
| NIP-22 comments (kind 1111) | 169 | ❌ | 5 |
| Recipe trend pill + 6h cache | 460 | ❌ | 5 |
| Recipe packs / cookbooks (kind 30003) | 570 | ❌ | 5 |
| Memories | screen | ❓ verify inheritance from Wisp | 5 |
| Gadgets sheet (unit converter + timer modal) | modal | ❌ (timer partly in 1.8) | nice-to-have |

### Tier 4 — 🚫 App Store landmines (do NOT port as-is)

| Android feature | Why it stays off iOS v1 |
|---|---|
| **Note Review credit purchase** (21-sat Lightning pay-per-use LLM; ~1.3k LOC) | Clearest Guideline 3.1.1 violation in the codebase. Build spec §4.3: must not ship. |
| **CLINK / Noffer** (`noffer1` native pay; kind 21001) | P3, deferred |
| **Premium recipes** (kind 35000) | Squatted kind; blocked on real events existing |
| **Membership link-out** to `zap.cooking/membership` | iOS ships *no* link (external-link entitlement risk outside US) |
| **Zaps on posts** | Ship, but behind `FeatureFlags.zapsOnPosts` kill switch (profile-level zaps allowed) |

### Already inherited (no port work)

Feed, profile, thread, search, DMs, groups, notifications, live streams,
social graph, custom emojis, drafts/scheduled posts, **Spark + NWC
wallet**, NIP-57 zaps, Blossom upload, NSpam, themes, account switcher,
**Apple iCloud Keychain recovery** (Google Sign-In already removed),
**NIP-42 publish-path AUTH retry**, outbox routing, **NIP-98** (✅ done).

---

## 7. Gating risks

### 7.1 Issue #6 — subscribe-path NIP-42 AUTH (the big one)

The inherited AUTH retry covers **writes only**
(`GroupRelayPool.publishWithAuthRetry` / `waitForAuthIfNeeded`). The
**read/subscribe** path fires REQs onto unauthed sockets, so **pantry
reads silently return empty** — Nourish, groups, and any members-relay
feature is broken until fixed. The build spec calls this a "Phase 3.5
hard prerequisite," but because it lives in the shared relay layer every
food feature leans on, **schedule it early (alongside Phase 1), not
late.** Specific gaps from the build spec §7.1: `subscribe` has no
`waitForAuthIfNeeded`; CLOSED `auth-required` sleeps 2s and replays once
instead of awaiting AUTH; `isAuthenticated` flips on *send* not
*accept*; reconnect clears auth then re-REQs before AUTH. Reference fix:
Android `collectAuthCompleted` re-fire. Watch-only accounts can never
AUTH (no keypair) → silent empty rooms regardless.

### 7.2 Two concrete plumbing gaps not in the per-concern list

- **ObjectBox `persistedKinds`.** iOS `EventStore.persistedKinds` =
  `{0,1,6,7,9735,20,21,22}`. Android persists **30023 (recipes) and 1111
  (NIP-22 comments)** as well (also 1068/6969/30004). Add 30023 for
  cache-seeded recipe feeds; add 1111 when NIP-22 lands.
- **NIP-56 reporting.** Wired into group rooms only on *both* platforms
  — a known Wisp gap. iOS needs Report on **feed posts, recipes, and
  profiles from day one** (UGC review requirement, build spec §4.4).

### 7.3 `project.pbxproj` trap

New **root-level** Swift files are not auto-picked-up — they need an
explicit `PBXFileReference`. Files under `wisp/`, `wispTests/`,
`wispUITests/` are synchronized folders and are exempt. Every recipe
file added at the repo root must be registered in `project.pbxproj` or
the build silently can't find it.

---

## 8. Recommended sequence (refreshed)

The phase plan in `ZAPCOOKING_IOS_BUILD.md` §5 is sound — this is
sequencing against current state, not a redesign.

1. **Finish Phase 0** (the missing half):
   0.4 relay role sets → 0.7 `ZapCookingApi` (start with the two
   membership endpoints + `computeClient`) → 0.5 branding → **rework
   `MainView.BottomTab` to the locked Spec-proposal layout** (§3) → add
   `FeatureFlags`. Cherry-pick the wisp lightning-address prompt (`6df1471`)
   in passing.
2. **Fix issue #6** (subscribe-path AUTH) — alongside Phase 1, before
   Phase 3.5.
3. **Phase 1** (recipe read path) — flesh out the six stubs into real,
   test-driven code. Parser first (byte-faithful; port Android's 14
   goldens). The stubs already define the contract surface, so this is
   "fill the bodies," not "design the API."
4. **Phase 2** (create/import) → **Phase 3** (food identity) → **Phase 4**
   (compliance, runs parallel from Phase 1) → **v1 submission (P0+P1)**.
5. **Phase 5** (P2) lands as post-approval updates.

**v1 scope (P0+P1) ≈ 12.7k LOC of Kotlin → ~14–16k LOC of Swift.** P2/P3
adds another ~10–15k.

### Effort signal by phase (Kotlin LOC of the food delta)

| Phase | ~Kotlin LOC | Key items |
|---|---|---|
| 0 (remainder) | ~1.2k | ZapCookingApi 985 + FeatureFlags/relay sets/branding |
| 1 | ~4.5k | parser, repository, detail, scaler, feed+card, tag feed, cook mode |
| 2 | ~3.1k | serializer, format seam, publisher, compose, Sous Chef |
| 3 | ~3.5k | bookmarks, My Kitchen, OnlyFood, onboarding, Nourish read |
| 4 | ~0.4k+ | NIP-56 reporting surface + App Store compliance |
| 5 (P2) | ~10–15k | Cheffy, Nourish Explore, grocery, planner, NIP-22, trend, packs |

---

## 9. Merge debt / upstream (`wisp-ios`)

- **Fork is ~2 weeks old** (`d51f260`, PR #425, 2026-07-28).
- **One upstream commit since the fork:** `6df1471` — "set up your
  lightning address" prompt on the wallet balance screen. ~58 lines
  across `WalletView.swift` + `wisp/WalletSettingsView.swift`. **Clean
  cherry-pick, zero conflict**, on-mission for a zap-centric client.
  **Take it now** while it's free.
- Deep shared infra (`RelayPool`, `EventStore`, `ContentView`,
  `FeedViewModel`) is **byte-identical** between fork and upstream — all
  divergence is concentrated at the branding/auth/wallet surface and is
  intentional. Forward-looking conflict hotspots to watch: `WalletView`
  (wallet UX), `PostCardView` (share URLs), `SignUpViewModel`/`Relay*`
  (relay-sovereignty policy — semantic, needs a human not a merge tool).

---

## 10. Conventions (carry from build spec §6)

- **One concern per PR.** Investigate first, surgical diffs, no stacking.
- View models: `@Observable @MainActor final class` (Observation, not Combine).
- Storage/collectors: `actor`s. CPU-bound work (parsing, scaling, ML) on
  `Task.detached(priority: .utility)`; mark recipe parsing `nonisolated`
  (project defaults to `MainActor` isolation).
- New NIPs: standalone root-level `NipXX.swift`.
- Tests: Swift Testing (`import Testing`, `@Test`) under `wispTests/`.
- Never hand-edit `model-wisp.json`; regenerate
  `EntityInfo-wisp.generated.swift` into **both** `generated/` and the
  repo root when entities change.
- Secrets: gitignored bundled resources in `wisp/Resources/` — no
  xcconfig+Info.plist injection.
- Project defaults to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the
  `Int64(_:UInt64)` ObjectBox collision under MemberImportVisibility
  means use `Int64(exactly:)!`, never `import ObjectBox` into
  non-storage files (build spec §7.12).
