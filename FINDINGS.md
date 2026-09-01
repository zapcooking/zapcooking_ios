# FINDINGS — Concern C-C: 3.2 My Kitchen hub

Branch `concern-3.2/my-kitchen` at 28a8d34. Sources: Android checkout at
`~/projects/zap_cooking_android` (behavioral contract), iOS worktree,
`ZAPCOOKING_IOS_BUILD.md` §2/§7/§8. Android citations are file:line in that
checkout; iOS citations are relative to this worktree.

---

## 1. Android's My Kitchen: tabs, order, empty states

My Kitchen on Android is **not a standalone screen**. The Recipes root screen
hosts a 3-way segmented pill (`RecipesMainTab { RECIPES, PACKS, COOKBOOK }`,
`app/src/main/kotlin/cooking/zap/app/ui/screen/RecipeFeedScreen.kt:111`);
"My Kitchen" (`strings.xml:286`) is the COOKBOOK segment, rendered by
`CookbookSection` (RecipeFeedScreen.kt:699–957). The drawer's "My Kitchen"
entry deep-links to COOKBOOK + SAVED (WispDrawerContent.kt:401–408 →
RecipeFeedScreen.kt:196–202). iOS instead has a dedicated `BottomTab.kitchen`
— that structural difference is already settled by the build plan (§Phase 3.2:
"retires the `.kitchen` placeholder").

Five sub-tabs in a `ScrollableTabRow`, declaration order = display order
(`CookbookSubTab`, RecipeFeedScreen.kt:120–126):

| # | Tab | Label | Account gate |
|---|-----|-------|--------------|
| 1 | SAVED | "Saved" | requiresAccount |
| 2 | MY_RECIPES | "Published" | requiresAccount |
| 3 | GROCERY | "Grocery" | requiresAccount + CanSign |
| 4 | PLANNER | "Planner" | requiresAccount + CanSign |
| 5 | NOURISH | "Nourish" | none |

Grocery/Planner are out of scope here (build doc maps them to Phase 5);
Nourish gets a placeholder slot for concern C-F. **iOS sub-tab order will be
Saved, Published, Nourish** — preserving Android's relative order with the
out-of-scope tabs omitted.

Verbatim copy to port:

- Signed-out gate (any gated tab, RecipeFeedScreen.kt:759–768, strings.xml:762):
  **"Sign in to view your recipes"**
- Saved empty (RecipeFeedScreen.kt:772–793): emoji 📖, title **"Start saving
  recipes"** (strings.xml:763), body **"Save recipes you love and organize
  them into collections."** (strings.xml:764)
- Published empty (RecipeFeedScreen.kt:849–857, strings.xml:765): single
  centered line, no emoji, no CTA: **"No published recipes yet"**. While
  loading, Android shows 12 skeleton tiles instead (RecipeFeedScreen.kt:834–848).
- Nourish entry card (RecipeFeedScreen.kt:1007–1034): emoji 🥦, title
  **"Nourish"**, body **"See how recipes nourish you — explore the catalog by
  gut health, protein, heart health, and more."**, button **"Explore
  Nourish"** (strings.xml:947–949). For 3.2 the card renders with the button
  disabled/no-op (C-F wires it).
- Dead copy confirmed: `cookbook_grocery_teaser_*` / `cookbook_planner_teaser_*`
  (strings.xml:766–767, 845–846) have zero call sites — not ported.

Two behaviors worth matching: the selected sub-tab is `rememberSaveable`
(survives navigating into a recipe and back, RecipeFeedScreen.kt:186–194),
and the create-recipe FAB is visible on every section but hidden for
watch-only accounts (RecipeFeedScreen.kt:275–282).

## 2. Published: relayed events only — no drafts, no gap

**Confirmed absence: Android has no recipe-draft persistence at all.**
`RecipeComposeViewModel.kt:33` states verbatim that v1 has no draft autosave
(web parity); ObjectBox has no draft entity (`app/.../db/` holds only
Event/Dm/Group entities). The only drafts in the app are NIP-37 kind-31234
*social-note* drafts on a separate route (`Routes.DRAFTS`,
Navigation.kt:1483–1527), unreferenced by My Kitchen.

Android's Published tab reads `RecipeRepository.authoredRecipes`
(RecipeFeedScreen.kt:823 → CookbookViewModel.kt:40–109 →
`RecipeRepository.loadAuthoredRecipes`, RecipeRepository.kt:744), an
author-scoped session fed only by (a) the ObjectBox cache of published relay
events and (b) a live REQ via `RecipeFormat.authorFeedFilter`
(RecipeRepository.kt:619–735). It is explicitly *not* built from the
kind-30004 pack (RecipeRepository.kt:635–636).

**Consequence: relayed-only Published on iOS is exact Android parity, not a
gap.** The "deferred-draft note" contemplated in the prompt is unnecessary —
the PR will state that Android shows no drafts either, with the citation above.

## 3. Edit and delete on Android — one divergence from this prompt

- **Published tile → detail only.** The tile is a plain `RecipeCard` with a
  single `onClick` (RecipeFeedScreen.kt:866–871; RecipeCard.kt:61–63). No
  long-press, no per-tile overflow — confirmed absence.
- **Edit and delete both live on the detail screen's overflow menu**
  (MoreVert, RecipeDetailScreen.kt:181–221), shown only when signer present
  and `event.pubkey == userPubkey` (Navigation.kt:3360–3389). "Edit" above
  "Delete" (error-colored). Edit navigates to the compose route prefilled at
  the original address; iOS already has this exact wiring
  (`wisp/RecipeDetailView.swift:92–107`), minus Delete.
- **Delete confirmation** — AlertDialog (RecipeDetailScreen.kt:349–374):
  title **"Delete recipe?"**, body **"Send a deletion request to relays for
  this recipe? This cannot be guaranteed, and there's no undo."**, confirm
  **"Delete"** (error color), dismiss **"Cancel"**. Failure dialog title:
  **"Couldn't delete recipe"** (RecipeDetailScreen.kt:379–386). On success
  the detail screen pops (Navigation.kt:3373).

⚠️ **Divergence to decide before Step 2.** The prompt's contract 1 names two
author-delete entry points: "recipe detail and the Published tab." Android
has **detail only** — nothing on the Published grid triggers delete. Per the
"Android is the contract" rule I plan to build **detail-only delete** (the
Published tab still satisfies contract 1: deleting from detail refreshes the
repository, so the recipe vanishes from Published without relaunch). If the
Published-tab entry point is wanted anyway (e.g. a context menu on the tile —
iOS `RecipeCardView` already has a context menu for Report/Block, so it's
cheap), say so in the go-ahead and I'll add it as an iOS-only affordance
flagged in the PR. Default: follow Android.

Delete propagation on iOS is pre-planned in the code: `RecipePublisher.delete`
publishes the blanked replacement + kind-5 but deliberately does not evict the
live coordinate; `RecipePublisher.swift:511–519`, `wisp/RecipeDetailView.swift:7–10`,
and build doc §2.4 (lines 1010–1014) all instruct: **call
`RecipeFeedViewModel.refresh()` after `delete` returns.** No callback into
`RecipePublisher` internals is needed — the `async` return is the hook. No
stop condition triggered.

## 4. Named collections: rename / delete / set-cover on Android

All in `app/src/main/kotlin/cooking/zap/app/repo/RecipeBookmarkRepository.kt`.
UI: overflow menu on each collection card in the Saved grid
(CookbookCollectionCard.kt:127–176), only when the account can sign. Menu
order: **Rename · Edit description · Choose cover · Delete**. Rename and
Delete are hidden for the default Saved list. Management exists *only* on the
Saved-grid card — the collection detail route has no manage affordances
(confirmed absence).

All metadata edits flow through one carry-forward republish helper
(`editListMetadata` :589–603 → `buildListTags` :122–181) that preserves
unknown tags — same shape as iOS's existing `buildListTags`
(`RecipeBookmarkRepository.swift:171–224`).

- **Rename** (`renameList` :510–516): changes **only the `title` tag**. The
  `d` tag is never changed (":506 — a new `d` = a different list = orphaned
  data"). Blank title, default list, unknown list, read-only → refused.
  Dialog: title "Rename", field label **"Collection name"**, Save/Cancel.
- **Set cover** (`setListCover` :536–545): changes **only the `cover` tag**,
  whose value is a member recipe's **a-coordinate** (`30023:<pubkey>:<d>`),
  not an image URL. Guard: the coordinate must already be in the list, else
  abort with no republish. Allowed on the default Saved list. Picker is a
  bottom sheet of member recipes; empty copy: **"Add recipes to this
  collection to choose a cover."** (strings.xml:959). Display resolves the
  cover URL from the referenced recipe's own image tag.
- **Edit description** (`setListDescription` :523–528): changes only the
  `summary` tag; blank clears; allowed on the default list. Not in this
  prompt's scope list, but it sits in the same Android menu and reuses the
  same builder — I plan to include it (trivial marginal cost, keeps the menu
  Android-identical). Flagging in case that's unwanted.
- **Delete is a real NIP-09 kind-5 tombstone, not a list rewrite**
  (`deleteList` :554–580): kind 5, content `""`, tags `["e", <list event id>]`
  and `["a", "30001:<pubkey>:<dTag>"]` — note **no `k` tag** on Android's
  collection delete (unlike recipe delete). Default list is never deletable.
  Android also (a) marks a **local tombstone** by id and by address+created_at
  so cache/laggard relays can't resurrect it, with a strictly-newer republish
  allowed to revive the address (:571–574, :384–400), and (b) optimistically
  removes the list locally so the grid updates immediately (:576, :606–609).
  Confirmation dialog: **"Delete collection?"** / **"Delete \"%1$s\"? This
  removes the collection but won't delete the recipes themselves."** /
  Delete (error) / Cancel (strings.xml:957–958).

iOS mapping notes: `CookbookList.coverCoord` is already parsed on iOS
(`RecipeBookmarkRepository.swift:73–82`) — nothing writes it yet. The iOS
cache (`RecipeBookmarkCache`, UserDefaults, newest-replaceable dedup) has no
tombstone concept; delete must at minimum evict the list from the per-author
cache entry and memory so a cache paint can't resurrect it in-session. All
three mutations will go through the existing guard machinery
(`resolveCarryForward`/`planMutation`) so a cold-session rename/delete/cover
against an unconfirmed relay state signs nothing — same first-save guard,
intact.

## 5. pbxproj: is the wisp app target filesystem-synchronized?

**Yes for the `wisp/` subdirectory; no for the ~300 Swift files at the repo
root.** `project.pbxproj` (objectVersion 77) has three
`PBXFileSystemSynchronizedRootGroup`s — `wisp`, `wispTests`, `wispUITests`
(pbxproj:691–707) — each attached to its target via
`fileSystemSynchronizedGroups` (wisp target pbxproj:1111–1138, wispTests
pbxproj:1139–1159). The wispTests Sources phase is **empty** (pbxproj:1605–1611):
purely synchronized, as advertised. The wisp target's Sources phase is **not**
empty — 308 explicit entries (pbxproj:1281–1596) for the root-level files
(RecipeRepository.swift, RecipePublisher.swift, etc.), which are classic
hand-registered references in the project mainGroup.

**Workflow consequence for the wave, stated plainly: any new Swift file
placed under `wisp/` (or `wispTests/`) registers itself — no pbxproj edit.
A new file at the repo root still needs four hand-added pbxproj entries.**
Existing views already live in `wisp/`, so 3.2 creates every new file there
and touches the pbxproj not at all; later concerns should do the same.
(`RecipeFormats.swift:52–58` already warns that a seventh root-level recipe
file means editing the pbxproj — the cheaper rule is: don't add root files.)

Duplicate-warning question: the pbxproj today contains **zero duplicate
build-file entries** (all 308 Sources names unique, verified by sort|uniq;
the one file with two PBXBuildFile objects, PendingShareStore.swift, belongs
to two different targets, which is correct). So the seven "Skipping duplicate
build file" warnings are gone because the duplicates themselves are gone from
the project — not a toolchain rendering difference. The sync-group structure
also makes recurrence impossible for `wisp/`-resident files, since they have
no explicit entries to collide with.

## 6. Files to create / modify

New files — all under `wisp/` or `wispTests/`, **zero pbxproj edits**:

| File | Purpose |
|---|---|
| `wisp/MyKitchenView.swift` | Hub behind `BottomTab.kitchen`: sub-tab switcher (Saved / Published / Nourish), signed-out gate, saveable selection |
| `wisp/SavedRecipesView.swift` | Saved grid: default list + named-collection cards, manage overflow, collection detail grid |
| `wisp/CollectionManageDialogs.swift` | Rename / edit-description / choose-cover sheet / delete-confirm dialogs (Android copy verbatim) |
| `wisp/PublishedRecipesView.swift` | Author-filtered grid through the repository; empty/loading states |
| `wisp/NourishPlaceholderView.swift` | Android's Nourish entry card, button inert (C-F fills it) |
| `wispTests/RecipeAuthoredFeedTests.swift` | Author-filter goldens through `RecipeRepository` incl. duplicate-coordinate tiebreaker; HiddenRecipes coordinate authored by signed-in pubkey absent from Published |
| `wispTests/RecipeCollectionManageTests.swift` | Rename / delete / set-cover against a populated remote list, 3.1 guard pattern (`mutateList_coldSession_populatedRemote_firstSaveAppends` shape) |
| `wispTests/MyKitchenLiveTests.swift` | §7.13 live gate: publish → in Published → delete → gone from Published/feed/detail; sentinel + env-var opt-in, `RelayDefaults.defaults`, key held until coordinate confirmed gone |

Modified files (root-level, already registered):

| File | Change |
|---|---|
| `RecipeRepository.swift` | New authored session (mirror of the existing tag session) using the already-implemented but unused `Nip23RecipeFormat.authorFeedFilter` (`Nip23RecipeFormat.swift:87–95`): `authoredRecipes`, `loadAuthoredFeed(author:)`, `refreshAuthoredFeed()`, cache paint; flows through the same `deduped` → inherits HiddenRecipes and the NIP-01 tiebreaker. Contract 2 is a repository query, not a view filter — no stop condition. |
| `RecipeBookmarkRepository.swift` | `renameList`, `setListDescription`, `setListCover` (membership guard), `deleteList` (kind-5 `e`+`a`, default-list refusal, local eviction incl. `RecipeBookmarkCache`), all through `buildListTags`/`planMutation` with the cold-session guard intact |
| `MainView.swift` | `case .kitchen:` renders `MyKitchenView` in a NavigationStack; retire the placeholder fall-through and the `:22–24` comment; popToRoot for kitchen |
| `wisp/RecipeDetailView.swift` | Add "Delete" beneath the existing Edit for the author (Android dialog copy); on `.deleted`, `await feedVM.refresh()` + refresh authored session, dismiss |
| `wisp/RecipeFeedViewModel.swift` | Only if needed to expose refresh to the detail delete path (likely just plumbing an existing instance; no behavioral change) |

Possible additions if implementation demands (will flag in the PR if used):
`wisp/MyKitchenViewModel.swift` / `wisp/SavedRecipesViewModel.swift` (thin
observers in the `RecipeFeedViewModel` style). Nothing else. Any file outside
this list triggers the stop condition per the prompt.

## Open questions for the go-ahead

1. **Published-tab delete entry point** (§3 above): follow Android
   (detail-only — my default) or add an iOS-only tile context-menu delete?
2. **Include "Edit description"** in the collection manage menu alongside
   rename/delete/cover, matching Android's menu exactly? (My default: yes.)
3. **No save affordance exists anywhere on iOS** — 3.1 landed the repository
   with zero UI, and no view has a bookmark/save button
   (`RecipeBookmarkRepository` is referenced only by its own tests). As
   scoped, the Saved tab can only display lists created on web/Android. A
   save toggle on recipe detail is *not* in this prompt's scope and I will
   not add it without a go-ahead — but flagging it, since Saved will
   otherwise be empty-by-construction for iOS-only users.

## Notes for Step 2 (no action yet)

- Empty-state copy verbatim from §1; watch-only accounts get the sign-in gate
  on Saved/Published per Android's `LocalCanSign` double-gate analog
  (`isWatchOnly` on iOS).
- §7.12: no new file will convert UInt64→Int64 without `Int64(exactly:)!`.
- Hermetic tests follow the established pattern: `RecipeRepository(relays: [])`,
  `seedCache:`, `await repo.inFlight?.value`, swift-testing, per-file fixture
  body constant, `Probe` environment for `RecipeBookmarkRepository`.
- Live gate follows `RecipeBookmarkLiveTests` exactly: `.liveNetwork` tag,
  `.enabled(if:)` with sentinel `.my_kitchen_live_enable` + `MY_KITCHEN_LIVE=1`
  env, `RelayDefaults.defaults`, timestamped d-tag `ios-3.2-my-kitchen-<stamp>`
  (not a `HiddenRecipes` prefix), key held until the coordinate re-queries gone.
- Baseline for the VM: 529/1 post-2.4 (530/1 if C-A's four merged first per
  the prompt's arithmetic); this concern adds its hermetic count on top.
