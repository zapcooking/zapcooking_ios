# Concern 2.5 — Sous Chef URL import — Step 1 findings

Sources examined: frontend `~/projects/ZapCooking` (souschef page + server routes),
Android `~/projects/zap_cooking_android` (SousChefScreen/ViewModel/ZapCookingApi),
this repo at `origin/main` (d40b106). File:line cites below are against those trees.

**Headline:** the URL import is **anonymous and ungated** — no NIP-98, no
membership, per-IP rate limit only. The response is a **structured object,
not markdown**. Android's flow is a **preview screen with direct Publish /
Save / Edit**, and every publish-side piece it uses already exists on iOS
(`RecipePublisher`'s single-image "Sous Chef Publish path",
`RecipeComposeSession.prefillMarkdown`). One scope decision is flagged in §4.

---

## 1. The endpoint

**Web Sous Chef page** (`src/routes/souschef/+page.svelte:422`):
`POST /api/extract-recipe` (same-origin relative path), body
`{ type: 'url', pubkey, url }` — and for URL mode it sends **no Authorization
header at all** (`+page.svelte:414-420`: NIP-98 is attached only for
`image`/`text`). `pubkey` is sent but not load-bearing for URL
(server docstring `src/routes/api/extract-recipe/+server.ts:23-27`).

**Server route** (`src/routes/api/extract-recipe/+server.ts`): only
`image`/`text` enter the NIP-98 + membership gate (`:90-143`); the `url`
branch (`:158-189`) has **no auth** and a per-IP rate limit —
`URL_PER_HOUR = 8`, `URL_PER_DAY = 30` (`:43-44`), KV scope `extract-url`.

**Sibling** `POST /api/extract-recipe/public`
(`src/routes/api/extract-recipe/public/+server.ts`): URL-only, body
`{ url }`, same 8/hr·30/day scope, used by the anonymous landing hero
(`src/components/LandingImportHero.svelte:131-135`) — **and by Android**:
`api/ZapCookingApi.kt:187-193` posts `{"url": …}` (DTO
`ExtractUrlRequest(val url: String)`, `:795-796`) to `/api/extract-recipe/public`
with no auth, on `HttpClientFactory.getComputeClient()` (10 s connect / 75 s
read, `relay/HttpClientFactory.kt:116-121`).

**Response shape — structured object, no markdown.** Success envelope
`{ success: true, recipe: NormalizedRecipe }`
(`+server.ts:200-208`); `NormalizedRecipe`
(`src/lib/parseRecipe.server.ts:69-80`, client mirror
`src/lib/anonImport.ts:20-42`, Android DTO validated live at
`ZapCookingApi.kt:886-899`):

```
title, summary, chefsnotes, preptime, cooktime, servings: String  (default "")
ingredients, directions, tags, imageUrls: [String]                (default [])
```

`imageUrls` is up to 5 URLs, og:image/schema.org image first
(`parseRecipe.server.ts:132-144`). Canonical markdown never crosses the
wire — the web assembles it client-side at publish (`+page.svelte:562-570`),
Android assembles it only for the Edit handoff (§4).

Failure envelope: `{ success: false, error, code }` where `code` is one of
**11** values (`src/lib/extractErrors.ts:26-37`): `INVALID_REQUEST`,
`INVALID_URL`, `UNSUPPORTED_URL`, `TEXT_TOO_LONG`, `SOURCE_BLOCKED`,
`SOURCE_NOT_FOUND`, `SOURCE_UNAVAILABLE`, `SOURCE_TOO_LARGE`,
`TOO_MANY_REDIRECTS`, `AI_UNAVAILABLE`, `INTERNAL`. Exception: the **429
rate-limit body has no `code`** — it is
`{ error: 'rate_limited', retryAfter, scope }`
(`+server.ts:186`, `src/lib/ipRateLimit.server.ts:118,128`). Our 0.7a
taxonomy already handles that via the status-429 fallback →
`.rateLimited(retryAfter:)`… **except `retryAfter` only decodes if the
envelope carries it — it does; `ErrorEnvelope` in `wisp/ZapCookingApi.swift:295-299`
already has the field.** The web souschef page itself mishandles this (shows
the literal string `rate_limited`); the taxonomy on iOS does better.

### §2 doc comparison (ZAPCOOKING_IOS_BUILD.md:294-316) — differences to correct in this PR

1. **`:302` is incomplete:** `POST /api/extract-recipe` is not
   image/text-only — it also accepts `type: 'url'` **with no auth** (that is
   what the signed-in web page uses). `/public` (`:301`) is the URL-only
   sibling used by the anon hero and by Android. Both rows are individually
   correct; the table implies URL *must* go through `/public`, which is false.
2. **Response shape is undocumented.** Add: structured `NormalizedRecipe`
   (fields above), never markdown; `{success:false,error,code}` failures;
   **429 carries no `code`** (status fallback required, `retryAfter` present).
3. **Error-code vocabulary:** §2/0.7a pin only 4 extract codes
   (`wispTests/ZapCookingApiTests.swift:146`); the live union is 11 (list
   above). All pass through `apiRejected` today — additive, nothing breaks —
   but the doc should carry the full list and the per-code user copy source.
4. Phase 2.5 line (`:1022`) says "structured preview via the shared recipe
   body → Save routes into 2.4" — confirmed accurate against Android.

## 2. Gating

**URL import: open.** Not entitlement-gated, not credit-metered; IP rate
limit only. No credit ledger exists anywhere in the extract path
(`parseRecipe.server.ts` — flat OpenAI `gpt-4o-mini` call, `:385-397`).
Image/text are Cook+-gated — and are **P2, out of scope here**
(ZAPCOOKING_IOS_BUILD.md:1024).

- Frontend gate (image/text only): `souschef/+page.svelte:384-388` redirects
  non-members to `/membership` client-side; the server enforces via NIP-98 +
  `hasActiveMembership` (`+server.ts:122-142`, fails **open** on membership-API
  errors). The page uses the **public batch** membership store
  (`GET /api/membership?pubkeys=`, `src/lib/stores/membershipStatus.ts:77`) —
  it never calls `check-status` and never reads `owner`. Same on Android
  (`SousChefViewModel.kt:77-101`).
- The web page requires login to *view* (`+page.svelte:370-373`), but the
  endpoint itself is anonymous; Android runs URL import with no signer at
  all — works for READ_ONLY accounts.

**Consequence for this concern:** there is **no non-member state to build**.
Shipping URL-only means nothing on the screen is gated. Android shows a
banner ("**URL imports are on us.** Image and text imports are a Cook+ and
above feature. View membership.", `SousChefScreen.kt:231-261`) — but that
advertises modes we are not shipping, and with
`FeatureFlags.membershipLinkoutEnabled = false` the link must not render.
**Proposal: omit the banner entirely in v1.** The membership dialog copy
Android uses when link-out is off ("Sous Chef image and text imports are
part of Zap Cooking membership.", `SousChefScreen.kt:155-163`) becomes
relevant only when P2 lands. No purchase UI is required or possible → no
stop condition triggered.

**`owner: true` / check-status is not part of this concern's gate.** The
prompt's hermetic-gate item ("`owner: false` and degraded public shape →
gated") maps to the image/text modes; with URL-only scope there is no gate
logic to test. Noted so the PR description can answer it explicitly.

## 3. Android's Sous Chef flow (behavioral spec)

- **Entry:** the Intelligence menu (purple `AutoAwesome` atom icon) in the
  top bars of Feed and RecipeFeed screens (`ui/component/IntelligenceMenu.kt:63-72`,
  `FeedScreen.kt:838-845`, `RecipeFeedScreen.kt:262-263` →
  `Routes.SOUS_CHEF`). **No share-sheet target** — `AndroidManifest.xml:36-45`
  has no `ACTION_SEND` filter; a URL cannot be shared into the app. The
  drawer item was removed (`WispDrawerContent.kt:433-439`, callback kept for
  call-site stability). So: **paste field only.**
- **Screen** (`SousChefScreen.kt:187-428`): one multiline field, placeholder
  "Paste a recipe URL, paste recipe text, or add a photo…", trailing
  **paste-from-clipboard** icon (`:315-322`); mode auto-detected live
  (`souschef/SousChefDetect.kt:25-32` — trimmed input matching
  `^https?://\S+$` → URL); IME key becomes `Go` in URL mode; CTA
  "🤖 Get Recipe".
- **Loading:** in-button 18 dp spinner + `"Fetching and extracting recipe
  from URL..."` (`SousChefScreen.kt:374-387`, `progressLine` `:432-436`)
  plus a large body spinner (`:403-406`); field/paste/CTA disabled; **no
  cancel** (Back exits and implicitly cancels).
- **Result:** an in-place read-only **preview** rendered by the shared
  `RecipeBody` (`:417-425`) with a serving multiplier, and three actions:
  **Publish** (direct), **Save to my recipes** (bookmark), **Edit** (→
  compose prefill).
- **Partial extraction:** preview opens **regardless** — all fields default
  and blank→nil (`ZapCookingApi.kt:908-930`); missing ingredient/direction
  sections are simply omitted (`RecipeBody.kt:101,120`), **no warning**.
  Missing **title** fails late, at publish: `"This recipe needs a title to
  publish."` (`RecipePublisher.kt:72`). Missing **image** is the one
  pre-publish block: Publish/Save disabled with reason
  `"Add an image to publish — or Edit to attach one."`
  (`SousChefScreen.kt:530-534`, gate `SousChefPublishConfirm.kt:20-21`).
- **Source image:** `imageUrls` → `RecipeParser.Recipe.images`, cover =
  `firstOrNull()`; the **remote source URL satisfies the photo rule**, and
  Blossom re-host happens at publish time with source-URL fallback
  (`RecipePublisher.kt:73-82`, 20 s cap). The **Edit path drops images**
  (markdown handoff carries no image tags), so editing forces a device photo.
- **Error copy, URL mode** (`SousChefViewModel.kt:171-197`), verbatim —
  hardcoded Kotlin, not in strings.xml:
  - `success=false`/null recipe → server `error`, else
    `"Couldn't import a recipe from that link."`
  - HTTP 429 → `"Too many imports right now — try again in a bit."`
  - HTTP 400 → parsed server `error`, else
    `"Couldn't read a recipe from that link."`
  - other HTTP → `"Import failed (<code>)."`
  - timeout (`InterruptedIOException`) →
    `"That site is taking too long — try again in a moment."`
  - other exception →
    `"Network error — check your connection and try again."`
- No kill switch exists on Android; `MEMBERSHIP_LINKOUT_ENABLED` gates only
  the membership link-out.

## 4. Prefill fit — and one scope decision to make

Android maps the structured response into compose by **serializing to
canonical markdown** (`souschef/SousChefComposeHandoff.kt:18-36`:
`"# title\n" + RecipeSerializer.toContent(...)`, with the preview's serving
multiplier applied via `IngredientScaler.scaleLine`) and calling
`prefillFromMarkdown`. iOS has the identical variant:
`RecipeComposeViewModel.prefillFromMarkdown` (`RecipeComposeViewModel.swift:154`)
reached via `RecipeComposeSession.prefillMarkdown`
(`wisp/RecipeComposeView.swift:7-18`, applied at `:203-205`), plus
`RecipeSerializer.toContent` and `IngredientScaler` already ported. **The
mapping is clean; no parser extension is needed. No stop condition.**

Fields with no home in compose via that path (identical on Android/web —
deliberate, not a gap): `summary`, `tags`, `imageUrls` (dropped;
`prefillFromMarkdown` leaves images/categories/summary empty, web parity),
and the **source page URL** (retained nowhere on any platform's normal path).
The **direct-Publish** path keeps tags + first image: Android
`SousChefViewModel.kt:247` (`categories = preview.recipe.hashtags`) →
`RecipePublisher` single-image overload — whose iOS twin already exists and
is documented as the "Sous Chef Publish path"
(`RecipePublisher.swift:80-109`, currently zero callers).

**⚠️ Scope decision.** The prompt's scope line says "recipe lands in
`RecipeComposeView` prefilled → publishes through the existing path", but
Android's primary flow is **preview → direct Publish / Save**, with Edit
(compose prefill) as the third action. Two faithful options:

- **(A) Android parity — recommended.** `SousChefView` = paste field →
  preview (shared recipe rendering) → Publish (existing
  `RecipePublisher.publish` single-image overload — its first caller) /
  Save to my recipes (`RecipeBookmarkRepository`) / Edit (→
  `.prefillMarkdown`). Keeps imported image + tags on the publish path; no
  publisher changes; matches "behavioral spec: Android".
- **(B) Literal scope reading.** URL field → straight into compose via
  `.prefillMarkdown`. Simpler screen, but loses image/tags/summary, the
  user must add a device photo before publish (photo rule), and
  `RecipePublisher`'s Sous Chef overload stays dead code. A worse product
  than Android and than the doc's own Phase 2.5 line ("structured preview …
  Save routes into 2.4").

I'll build **(A)** unless the go-ahead says otherwise. (A serving-multiplier
control can be trimmed from v1 if we want the smallest faithful screen; the
handoff scaling then collapses to multiplier = 1.)

## 5. Photo requirement interaction

Two different answers by path, both already true on iOS:

- **Direct publish (preview):** yes — Android treats the imported source
  image URL as satisfying the requirement **before** re-host
  (`SousChefPublishConfirm.kt:20-21` computes `hasImage` from the remote
  URL; re-host is at publish with fallback, `RecipePublisher.kt:73-82`).
  iOS `RecipePublisher.publish` mirrors this exactly
  (`RecipePublisher.swift:95-100`: guard on `recipe.image`, then
  `reHost(...) ?? sourceImage`).
- **Compose (Edit path):** no — the handoff drops images, and compose's
  `blockReason` demands ≥1 uploaded photo
  (`RecipeComposeViewModel.swift:365`). Deliberate Android/web parity.
  (`addHostedImage(url:)` at `:294` *could* inject the source URL as `.done`,
  but the compose publish path sends URLs as-is with **no re-host**, so a
  third-party URL would land in the event without even a re-host attempt —
  don't do it.)

Under option (A) both behaviors carry over with zero changes to
`RecipePublisher` or the compose VM validation.

## 6. Live-gate feasibility

**The endpoint is not gated, so the throwaway-key problem does not arise** —
no key is needed at all. A live test is feasible today:

- `SousChefLiveTests` (opt-in, same pattern as `Nip98LiveRoundTripTests` —
  sentinel file `wispTests/.souschef_live_enable` or `SOUSCHEF_LIVE=1`,
  `.tags(.liveNetwork)`): one `POST /api/extract-recipe/public` with a
  stable real recipe URL, assert `success == true`, non-empty
  `ingredients`/`directions`, and a decoded `imageUrls`. **No event is
  published, no key is held, no cleanup is owed** (§7.13 does not apply).
- Costs/risks to accept: consumes 1 of the shared per-IP 8/hr budget
  (VM + dev machine may share an egress IP); server-side OpenAI spend;
  dependence on a third-party site staying up and un-blocked → keep it
  opt-in, single-shot, never in the default suite.

**Manual gate** (belt-and-braces, will be written into this file under
"Manual gate" during Step 2): simulator run — paste an AllRecipes URL →
loading copy → preview with image/title/ingredients → Publish blocked only
per rules → (optionally) publish + delete per §7.13 if we exercise the live
publish, otherwise stop at the preview.

## 7. Fixtures

**No recorded HTTP fixtures exist in the frontend** — its tests `vi.mock`
`parseRecipe` with an all-empty `MOCK_RECIPE`
(`src/routes/api/extract-recipe/extract-recipe.server.test.ts:34-45`;
`src/test/fixtures/` is grocery/mealplan only). Provenance for ours:

1. **Hand-built from the typed contract** — `NormalizedRecipe` in
   `parseRecipe.server.ts:69-80` (mirror `anonImport.ts:20-42`), field names
   already validated live by Android (`ZapCookingApi.kt:886-899` doc
   comment: "validated live"). This is the primary source.
2. **One-shot live capture** — `curl` against `/api/extract-recipe/public`
   with a real URL to snapshot a genuine body (spends one rate token; no
   PII in the response). Nice-to-have to cross-check field casing.
3. Error shapes straight from server source: `{success:false,error,code}`
   (`+server.ts:200-208`, codes `extractErrors.ts:26-37`), the code-less
   429 body (`ipRateLimit.server.ts:118,128`), and the `INTERNAL` catch-all
   (`+server.ts:209-217`).

Fixture set (≥3): **clean** (full recipe, multiple imageUrls), **partial**
(empty title + empty ingredients, non-empty directions — exercises
blank→nil and the no-warning preview), **error** (`SOURCE_BLOCKED` with
copy), plus the **429-no-code** body for the taxonomy path.

**Real-site inputs the web version is known to handle** (the UA-fix comment,
`parseRecipe.server.ts:199-206`, names the sites that were specifically
unblocked): `allrecipes.com`, `bonappetit.com`, `cooking.nytimes.com`.
There is no allowlist — any public http(s) URL passes the SSRF guard
(`src/lib/urlGuard.server.ts`).

## 8. Files to create / modify (all new files under `wisp/`/`wispTests/` — zero pbxproj diff expected)

| File | Action | Content |
|---|---|---|
| `wisp/ZapCookingApi.swift` | modify | `extractRecipeFromUrl(url:)` → `POST /api/extract-recipe/public` on `HttpClientFactory.computeClient` through the existing `post(path:body:client:)` + `throwErrorIfNeeded` spine; DTOs `ExtractUrlRequest`, `ExtractRecipeResponse`, `NormalizedRecipe` (all-defaulted, Android parity); `toRecipe()` mapping → `RecipeParser.Recipe` (blank→nil). **No NIP-98 on this call** — Android sends none and the endpoint ignores auth; §2 note updated accordingly. |
| `wisp/SousChefView.swift` | new | §8-named screen: paste field + clipboard button, URL detection, loading state (Android copy), preview via existing recipe rendering, Publish / Save / Edit actions, error text per §3 copy. Entry hidden when kill switch off. |
| `wisp/SousChefViewModel.swift` | new | State machine (idle/loading/preview/error/publishing), error mapping from `ZapCookingApiError` → Android's copy per class (timeout → "That site is taking too long…" — asserts computeClient in play), re-entrancy guard (fixing Android's known gap at `SousChefViewModel.kt:166-169`). |
| `FeatureFlags.swift` | modify | `static let sousChefImportEnabled: Bool = true` (fourth switch). Gating goes through a testable pure helper so "off → hidden" is assertable. |
| `wisp/RecipeFeedView.swift` | modify | Entry point: trailing sparkle button in the Recipes-tab header (`header` HStack has a free trailing slot, `wisp/RecipeFeedView.swift:49-67`) — the iOS stand-in for Android's Intelligence-menu placement on RecipeFeedScreen. |
| `MainView.swift` | modify | Present `SousChefView` (fullScreenCover, same pattern as `showRecipeCompose` at `:787`), route Edit → `RecipeComposeSession.prefillMarkdown`, Publish success → `RecipeRoute` push. |
| `wispTests/SousChefTests.swift` | new | Hermetic: decoding over the ≥3 fixtures + 429-no-code; structured→`RecipeParser.Recipe` mapping (blank→nil); structured→markdown handoff → `prefillFromMarkdown` round-trip; service-uses-computeClient assertion (refactor to `generalClient` fails); kill-switch-off → entry hidden; the 7 not-yet-pinned extract codes through `apiRejected`. |
| `wispTests/SousChefLiveTests.swift` | new | Opt-in live extraction per §6 (no key, no cleanup). |
| `ZAPCOOKING_IOS_BUILD.md` | modify | §2 corrections (§1 above), §8 rows for the new files, 2.5 phase note. |

Not touched (per stop conditions): `RecipePublisher.swift` (its Sous Chef
overload is consumed as-is), `Nip98*`, wallet/zap path, pbxproj.

## Deviations from the prompt's assumptions, called out

1. **"`SousChefImportService` … with NIP-98"** — dropped: the URL endpoint
   takes no auth (Android sends none; server ignores it). The call lives in
   `ZapCookingApi` per §8's 1:1 file mapping. computeClient + 0.7a taxonomy
   + 75 s timeout all apply as specified.
2. **Non-member state / gate logic tests** — vacuous for URL-only scope
   (§2). The `owner:true` machinery stays untouched; gate tests deferred to
   the P2 image/text concern where they become meaningful.
3. **"Paste or share a URL"** — Android has no share-sheet entry; per
   "entry point per Android" this ships paste-only. (iOS's existing
   ShareExtension routes shared URLs to the note composer; retargeting
   recipe URLs to Sous Chef would be new behavior with no Android
   precedent — flagged as a possible follow-up, not built here.)
4. **Preview screen vs straight-to-compose** — §4 decision, recommending
   Android parity (A).
