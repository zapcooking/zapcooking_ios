# FINDINGS — Concern C-F (3.5): Nourish

Branch `concern-3.5/nourish` at `2be233f` (`#49` is in the log:
`fix(3.1b): hidden-coordinate unsave consults resolved list, not memory;
harden save-toggle tests (#49)`). Remote is
`https://github.com/zapcooking/zapcooking_ios.git`.

Sources: Android at `/Users/sethsager/Projects/zap_cooking_android`
(behavioral contract), member-relay at `/Users/sethsager/Projects/member-relay`
(`relay/main.go`), frontend at `/Users/sethsager/Projects/zapcooking`,
iOS worktree, `ZAPCOOKING_IOS_BUILD.md` §2 / §7 / §8.

**No stop condition hit.** Android's pantry read is the pinned public
shape (authors + kinds `[30078]`); extra `#d` / `#l` / `limit` are
narrowing and allowed. Compute is `POST /api/nourish` on the frontend.
The client publishes no Nourish events. `GroupRelayPool` is not needed.

---

## Scope fork (read this first)

Android has **three** Nourish surfaces. This prompt says "My Kitchen tab
slot"; the build doc §8 3.5 describes the recipe-detail card; 3.2's iOS
placeholder already names Explore as C-F's job. They are not the same
feature.

| Surface | What it does | Compute? | Key? |
|---|---|---|---|
| **My Kitchen › Nourish tab** | Entry card only. Navigation. No REQ. | No | No (`CookbookSubTab.NOURISH(false)`) |
| **Nourish Explore** (pushed route) | Pantry 30078 corpus + 30023 resolve, ranked/filtered grid | No | No |
| **Recipe detail** | One 30078 by `#d`; miss → offer `POST /api/nourish` | Yes | Read: no. Compute: signing key |

iOS 3.2 already ported the kitchen entry card, button disabled, with an
explicit hand-off: "Concern C-F wires the Nourish explore route"
(`wisp/NourishPlaceholderView.swift:3–6`).

**Recommendation for Step 2 — ship read first:**

1. Enable the kitchen CTA → Explore (Android kitchen-tab contract).
2. Port pantry read + parser + Explore UI (what the CTA opens).
3. Port recipe-detail `NourishCard` as a **read-only** miss-is-quiet
   section (build-doc 3.5; otherwise tapping an Explore tile loses the
   profile).
4. **Defer compute** (`POST /api/nourish`, members-only, Computing /
   NotScored) to the follow-up the build doc already calls "15. Nourish
   compute + Nourish Explore" — Explore itself is read-only; compute
   lives on recipe detail. Frontend endpoint exists; this is a split of
   *surface*, not a missing API.

If Step 2 is forced to include compute in the same PR it is feasible
(finding 3), but it is a second Android concern (2.4b) on a second
screen. Ship read first.

---

## 1. Android's Nourish data model

**Kind / author.** Kind **30078** (NIP-78 app data), authored by a
fixed service pubkey — not the viewing user, not the recipe author:

```
fdd263f69f9e95a2a0a58ec3e7e8053011214fa66007d93b26d2f4717d31917b
```

Android `NourishParser.SERVICE_PUBKEY` / `KIND`
(`NourishParser.kt:84–87`); frontend `NOURISH_SERVICE_PUBKEY`
(`src/lib/nourish/types.ts:12`); member-relay `nourishServicePubkey`
(`relay/main.go:668–677`). All three match.

**Keyed to the recipe, not the user.** `#d` is
`nourish:30023:<recipeAuthor>:<recipeDTag>` (`NourishParser.kt:104–105`,
frontend `buildNourishDTag` in `nourishRelay.ts:54–56`). An `a` tag
holds the same coordinate (`30023:<pubkey>:<dTag>`). Explore parses
rows from the `a` tag (`NourishDiscovery.kt:188–193`); a missing /
unparseable `a` is skipped.

**Content JSON** (server publishes this; clients parse, never
recompute `overall` — `NourishParser.kt:67–70`):

- 8 dimensions, display order: Real Food, Gut, Protein,
  Anti-Inflammatory, Blood Sugar, Immune, Brain, Heart
  (`NourishParser.kt:90–99`). Each is `{score, label}`; missing dims
  default to **0** (legacy).
- `overall: {score, label}` — **required**; absent → parse returns
  null.
- `improvements`: ≤5 non-blank strings.
- Additive `macros` (prompt v4): `perServing.{kcal,protein_g,carbs_g,fat_g}`,
  `servingsUsed`, `servingsParsed`, `confidence` ∈ {`estimate`,`rough`},
  `method`. Malformed → null row, scores still parse.
- Ignored extras: `promptVersion`, `cacheVersion`, `ingredient_signals`,
  `audience` / `audience_scores`, `labels`, `summary`, `createdAt`.

**Versioning** lives on tags + content, not as a client schema gate.
Frontend today: `NOURISH_CACHE_VERSION = '2.0'`,
`NOURISH_PROMPT_VERSION = '4'` (`types.ts:1–2`). Tags include
`nourish_version`, `prompt_version`, `content_hash`, per-dim
`nourish_*` scores, optional NIP-32 `L`/`l` under namespace
`cooking.zap.nourish` (`nourishPublisher.server.ts:113–150`).
Android's parser never requires those tags; labels are Explore-only.

**How many are read.**

- Single-recipe: `limit = 1` (`NourishRepository.kt:56–61`).
- Explore: `limit = 200` (`NourishDiscovery.kt:162–168`); ranked
  display takes 40 (`NourishExploreViewModel.kt:167–170`).

**Local cache (session only — not ObjectBox, not UserDefaults).**

- Score cache: `ConcurrentHashMap<author:dTag, NourishScore>`
  (`NourishRepository.kt:40, 53–54, 386–388`).
- Explore: 5-minute SWR discovery cache + recipe-event cache
  (`NourishDiscovery.kt:16, 86–87, 221–266`). Never-clobber empty
  revalidate (`NourishDiscovery.kt:147–154`). `clear()` on account
  switch.

---

## 2. The read filter Android sends

### Explore unfiltered (the kitchen-tab destination's first REQ)

`NourishDiscovery.buildNourishAnalysisFilter(null)` at
`NourishDiscovery.kt:162–168` → `NourishRepository.kt:218–219`:

```
kinds   = [30078]
authors = [<SERVICE_PUBKEY>]
limit   = 200
```

No `#d`, no `#l`, no `#t`. This **is** the pinned public shape from
this morning's C-B probe, plus `limit` (narrowing).

### Explore filtered (chip AND)

Same authors/kinds/limit, plus `#l = [<most-selective label>]`
(`NourishDiscovery.kt:164–167`). Remaining labels are client-side
intersect (`NourishDiscovery.kt:181–186`). Extra `#l` is **allowed**
by policy (below).

### Single-recipe (recipe detail, not the kitchen tab)

`NourishRepository.fetchScore` at `NourishRepository.kt:56–61`:

```
kinds   = [30078]
authors = [<SERVICE_PUBKEY>]
#d      = ["nourish:30023:<author>:<dTag>"]
limit   = 1
```

Extra `#d` is **allowed** by policy. Frontend
`queryNourishEvent` (`nourishRelay.ts:105–109`) sends the same
authors/kinds/`#d` without a limit.

### Policy vs the C-B one-liner

member-relay `isPublicNourishFilter` (`relay/main.go:679–703`):

> filter must pin `authors` to **exactly** `[nourishServicePubkey]`
> AND request kind 30078 **exclusively**. Any `#l`/`#d` / limit /
> since/until further **narrow** and never broaden, so they don't
> affect the decision.

The Go test (`relay/main_test.go:39–54`) explicitly allows
`#l` + `#d` + limit + since + until on that pin. Recipes
(kind 30023) are a separate always-public path
(`relay/main.go:708–711`).

**C-B "one extra tag and the read silently fails" overstates the
policy.** Extra tags on a correctly pinned authors+kinds filter are
fine. What AUTH-gates: missing `authors`, extra authors, kinds-less,
or kinds that aren't exclusively 30078.

Android does **not** rely on AUTH for these reads. Comments at
`NourishRepository.kt:42–45` and `213–216` say anonymous service-key
30078 REQs are public; `hasSigningKey` is unused on the read.
`AuthedRelayReader` still *can* AUTH if a key is present, but the
filter shape is what makes the read public. iOS must use
`RelayPool.query`, not `GroupRelayPool`.

---

## 3. Compute: client or backend?

**Backend.** Android does not derive scores on-device from ingredients.

| | |
|---|---|
| Path | `POST https://zap.cooking/api/nourish` |
| Client | long-timeout compute client (~75 s) — `ZapCookingApi.kt:271–308` |
| Auth | **pubkey-in-body, not NIP-98** (`ZapCookingApi.kt:272–273`). iOS `ZapCookingApi.swift:20–22` already documents this. |
| Gate | `requireMembership` fail-closed (`frontend src/routes/api/nourish/membershipCheck.ts:13–59`). `MEMBERSHIP_ENABLED` off → no gate. |
| Non-member | HTTP **403**, body `{ success: false, error: "Premium membership required for Nourish" }` — **no `code` field** (`membershipCheck.ts:46–49`). Android maps **any** 403 → `MembersOnly` (`ZapCookingApi.kt:289`). |
| Success | `{ success, scores, improvements, macros?, … }`. Client parses with `NourishParser.parseScores` + top-level macros; **no pantry re-read**. Server publishes the 30078 to pantry (+ public relays) for everyone else (`+server.ts:94–120`). |
| Frontend twin | `NourishModal.svelte:226–240` — same path, same pubkey-in-body JSON. |

**Not used from Nourish Explore or the kitchen tab.** Compute is
recipe-detail only (`RecipeDetailViewModel.computeNourish`,
`RecipeDetailViewModel.kt:147–180`).

**iOS 0.7a vs Android 403:** `ZapCookingApi.throwErrorIfNeeded`
(`wisp/ZapCookingApi.swift:213–218`) maps a **bare 403 with no
`code`** to `apiRejected`, not `membersOnly`. Nourish's real
non-member body has no `code`. If compute ships, this endpoint needs
an Android-shaped 403 → members-only mapping **without** treating
every 403 in the app as membership denial. Copy must be
`"Nourish scoring is a Zap Cooking members feature."` — never the
server's "Premium membership required" string (purchase-adjacent,
§4.3).

`HttpClientFactory.computeClient` already exists (0.7b). No new
endpoint. NIP-98 is **not** required.

---

## 4. States Android shows (verbatim)

### A. My Kitchen › Nourish tab (`NourishEntrySection`,
`RecipeFeedScreen.kt:1005–1034`, `strings.xml:947–949`)

No loading / empty / member / error. Always the same card, signed-out
included (`CookbookSubTab.NOURISH(false)`, `RecipeFeedScreen.kt:125`):

- emoji **🥦**
- title **Nourish**
- body **See how recipes nourish you — explore the catalog by gut health, protein, heart health, and more.**
- CTA **Explore Nourish**

iOS 3.2 already has this, button disabled
(`wisp/NourishPlaceholderView.swift:7–38`).

### B. Nourish Explore (`NourishExploreScreen.kt`, `strings.xml:987–1001`)

| State | Copy |
|---|---|
| Loading | **Finding analyzed recipes…** |
| Error | **Something went wrong. Please try again.** + button **Retry** |
| Empty | **No analyzed recipes yet.** / **Once recipes are analyzed with Nourish, they'll appear here ranked by their nutrition profile.** |
| Degraded (filter miss → unfiltered fallback) | **More recipes being analyzed — showing the full ranked list for now.** |
| Refreshing (SWR) | **Updating…** |
| Footer (filtered) | **%d recipes matching your filters** |
| Footer (all) | **%d recipes with Nourish profiles** |
| Honesty caption | **AI-generated estimates — guidance, not gospel** |
| Title | **Nourish Explore** |

No members-only. No watch-only. No compute.

### C. Recipe detail (`RecipeDetailViewModel.NourishUi`,
`RecipeDetailScreen.kt:286–300`, `NourishSectionPanels.kt`)

| State | What renders | Copy |
|---|---|---|
| `Loading` | **nothing** | (quiet) |
| `Hidden` | **nothing** | watch-only / no key **and** no published score |
| `Scored` | `NourishCard` | header **Nourish**, **{n}/10**, affirming label only if overall ≥ 5; **What this meal brings**; macros **Estimated per serving** / **Rough estimate** / ` (servings assumed: N)`; **Nourish Profile**; **Simple upgrades**; footer **Profiles are estimates based on ingredients. Not medical advice.** |
| `NotScored` | compute panel | **Nourish** / **See this recipe's Nourish profile across 8 dimensions.** / button **Get Nourish profile** |
| `Computing` | same panel, spinner | **Scoring… (this can take a moment)** |
| `MembersOnly` | message panel | **Nourish scoring is a Zap Cooking members feature.** |
| `Error` | message panel + Retry | Android's `Couldn't compute the Nourish score (N).` / `No score in the response.` / `Couldn't read the Nourish score.` / `Network error — please try again.` |

Dead string, **not shown anywhere**:
`nourish_signing_required` = "Sign in with a key to fetch Nourish
profiles." (`strings.xml:985`). Watch-only on a miss is Hidden, not a
toast. iOS `RecipeSaveGate.needsKey` applies **only if we ship
compute** (a key-required action). The pantry **read** is anonymous.

Card greens (build doc already has these): strong ≥7 `#22C55E`,
moderate 4–6 `#4ADE80`, light 0–3 `#86EFAC`. Soft labels: score 0 →
**Not a focus here**; ≤2 → **Lightly present**. No letter grades.

---

## 5. Does anything in Nourish write?

**The client publishes no Nourish events.** Kind 30078 is signed by
the service key on the server (`nourishPublisher.server.ts`).

- Kitchen tab: navigation only.
- Explore: REQ only; 30023 resolve on article relays.
- Recipe-detail compute: `POST /api/nourish`. Server awaits pantry
  publish, then returns the score. Android `hasSigningKey` is unused
  on the **read**; compute returns early if `signer?.pubkeyHex` is
  nil (`RecipeDetailViewModel.kt:156`).
- `/api/nourish/flag` and `/api/nourish/scan` exist on the frontend.
  **Zero Android call sites.** Do not invent a write/flag/scan path.

**Split:** treat compute as the write-adjacent follow-up (it causes a
server-side 30078 publish). Ship **read** (Explore + recipe-detail
card) first.

---

## 6. Live-gate feasibility

**Read canary — no key.** Open `wss://pantry.zap.cooking` with a raw
(unauthenticated) WebSocket, send the named pinned REQ:

```
["REQ","nourish-live",{"kinds":[30078],"authors":["fdd263f69f9e95a2a0a58ec3e7e8053011214fa66007d93b26d2f4717d31917b"],"limit":200}]
```

Expect: `EVENT`s (kind 30078, that author) and `EOSE`. Assert **no
`AUTH` frame** and no `CLOSED … auth-required`. Sentinel:
`wispTests/.nourish_live_enable` / `NOURISH_LIVE=1`, same opt-in
pattern as `SousChefLiveTests`. This is also the relay-policy canary.

A second hermetic-enough probe can `#d`-pin a known coordinate
(`limit: 1`) — still public per policy.

Do **not** drive the canary through `RelayPool.query` alone:
`RelayConnectionPool` will AUTH-and-replay if a key happens to be in
process (`RelayPool.swift:603–611`), which would hide a policy
regression. Raw socket, no signer.

**Compute (deferred):** a throwaway key can prove the non-member 403
shape (`MembersOnly` copy, no purchase language). Member path is a
manual checklist (`owner: true` on `/api/membership/check-status`).
Not this PR if we ship read first.

**Unexpected AUTH on the product read path** (policy flipped under
us): `RelayPool.query` currently swallows `CLOSED auth-required` and
waits for AUTH (`RelayPool.swift:590–596`). Watch-only never AUTH →
timeout → empty list, which would look like Explore's empty state.
Step 2 must distinguish that from a genuine empty corpus and show
Explore's **error** copy ("Something went wrong. Please try again."),
not the empty copy. Recipe-detail read stays quiet-absence on miss
(Android), but an AUTH challenge is not a miss — surface error there
too if we ship the card.

Issue **#6 does not block**. `RelayPool.query` already re-issues
every REQ after a successful AUTH (`RelayPool.swift:609–611`). #6 is
the `GroupRelayPool` subscribe path. Nourish must not use that pool.
Correct §2 / §7.1 / §8 3.5 / `RelayDefaults.members` comment.

---

## 7. Files to create or modify

New files under `wisp/` / `wispTests/` only — **zero pbxproj**.

### Create

| File | Why |
|---|---|
| `wisp/NourishParser.swift` | Port of `NourishParser.kt` (scores, macros, d-tag, service pubkey, clamp, trust stored `overall`) |
| `wisp/NourishDiscovery.swift` | Port of `NourishDiscovery.kt` (chips, selectivity, `#l` intersect, parseAnalyses, sort, session cache) |
| `wisp/NourishRepository.swift` | `RelayPool.query` on `RelayDefaults.members`; pinned corpus filter; optional `#d` fetchScore; 30023 resolve via existing `RecipeRepository` / article relays |
| `wisp/NourishExploreView.swift` | Port of `NourishExploreScreen.kt` |
| `wisp/NourishExploreViewModel.swift` | Port of `NourishExploreViewModel.kt` |
| `wisp/NourishExploreRecipeCard.swift` | Leaf mark + macros snippet (`NourishExploreComponents.kt`) |
| `wisp/NourishCard.swift` | Green-island card (`NourishCard.kt`) for recipe detail |
| `wispTests/NourishParserTests.swift` | Android `NourishParserTest` goldens verbatim |
| `wispTests/NourishDiscoveryTests.swift` | Android `NourishDiscoveryTest` goldens (filter shape, chips, intersect, cache) |
| `wispTests/NourishFilterShapeTests.swift` | Pinned REQ keys ⊆ {`kinds`,`authors`,`limit`}; fails if a tag is added |
| `wispTests/NourishExploreTests.swift` | Loading / empty / error / degraded / kill switch |
| `wispTests/NourishCardTests.swift` | Quiet miss / scored; AUTH-challenge ≠ empty |
| `wispTests/NourishLiveTests.swift` | Opt-in pantry canary |

### Modify

| File | Why |
|---|---|
| `wisp/NourishPlaceholderView.swift` | Enable CTA; push Explore when `nourishEnabled` |
| `wisp/MyKitchenView.swift` | `navigationDestination` for Explore; hide tab if kill switch off |
| `wisp/RecipeDetailView.swift` | Render `NourishCard` / quiet miss (read-only this PR) |
| `wisp/RecipeDetailViewModel.swift` | Independent pantry `fetchScore`, Android state machine minus compute |
| `FeatureFlags.swift` | `nourishEnabled = true` |
| `NostrEvent.swift` (`NostrFilter`) | Add `lTags` → `"#l"` so Explore chip REQs encode. Existing file; no pbxproj |
| `RelayDefaults.swift` | Drop the "reads REQUIRE issue #6" comment on `members` |
| `ZAPCOOKING_IOS_BUILD.md` | §2 Nourish (AUTH-on-every-read is false; #6 does not block), §7.1, §8 3.5 + 3.2 hand-off, Phase-order item 11/15 |

### Not this PR (compute follow-up)

`wisp/ZapCookingApi.swift` `computeNourish`, `NourishSectionPanels`
compute/members-only UI, `RecipeSaveGate.needsKey` on **Get Nourish
profile**, 0.7a-vs-bare-403 mapping.

### Do not touch

`GroupRelayPool`, wallet/zap, `Nip98` internals, `RecipePublisher`,
`project.pbxproj`, Grocery, Planner.

---

## Plan changes vs the prompt / the doc

1. **Issue #6 no longer blocks Nourish read.** Use `RelayPool.query`.
   Doc §2 / §7.1 / §8 3.5 / `RelayDefaults.members` are stale.
2. **Pantry 30078 with authors=`[service]` + kinds=`[30078]` is public
   without AUTH.** `#d`/`#l`/limit are allowed narrowing, not a
   silent-fail extra. C-B "one extra tag fails" is overstated vs
   `isPublicNourishFilter`.
3. **Kitchen tab does not read or compute.** It navigates to Explore.
   Explore is the pantry corpus read. Compute is recipe-detail +
   `POST /api/nourish` (pubkey-in-body, member-gated, not NIP-98).
4. **Ship read first** (Explore + recipe-detail card). Defer compute.
5. Watch-only does not need a toast on the read path. `needsKey`
   composes only with compute.
6. Unexpected AUTH on a pinned public REQ is an **error**, not empty.
