# Concern 3.1b — save/bookmark toggle: findings

Worktree `~/projects/zc-ios-c-c`. Remote `zapcooking/zapcooking_ios`.
Branch `concern-3.1b/save-toggle` from `origin/main` at `d40b106`
(PR **#45** `f774439` 3.2 My Kitchen is merged; it is an ancestor of
HEAD, with one later wallet fix `#17` at the tip).

No stop condition fired. Android's save UX is the detail ActionBar
tap / long-press picker shape this concern already named. The first-save
guard does not need weakening. Saved state is a repository read.

---

## 1. Where Android exposes save / unsave

### Recipe detail — yes

`zap_cooking_android/app/src/main/kotlin/cooking/zap/app/ui/screen/RecipeDetailScreen.kt`
passes `onAddToList` / `onAddToListLongPress` into
`ActionBar` (`ui/component/ActionBar.kt:310-327`).

Wiring in `Navigation.kt:3335-3341`:

- **Tap** → `FeedViewModel.toggleRecipeBookmark(eventId)` →
  `RecipeBookmarkRepository.toggle(event)` — default Saved list
  (`d=nostrcooking-bookmarks`) only.
- **Long-press** → `RecipeListChooserSheet` (named-collection
  multi-membership).

**Icon:** `Icons.Filled.Bookmark` when saved, `Icons.Outlined.BookmarkBorder`
when not. Tint `WispThemeColors.bookmarkColor` when filled, else
`onSurfaceVariant`. Size 22 dp in a 48 dp hit target.

**Copy:** accessibility `cd_add_to_list` = **"Add to List"**
(`strings.xml:396`). Same string whether filled or empty. No "Save" /
"Unsave" / "Saved" label on the detail control.

Comment at `ActionBar.kt:310`: "Single tap → default Saved toggle;
long-press → list chooser (when wired)."

Fill state (`Navigation.kt:3209-3220`) is
`recipeBookmarkRepo.bookmarkedCoordinates` (canonical `a`-coordinates)
**unioned with** legacy kind-10003 e-ids and kind-30003 note-list ids so
old Android bookmarks still render filled. iOS 3.1 did not port that
legacy 10003 path; fill state here is **canonical 30001 only**. That is
the 3.1 choice, not a new inference.

### Recipe card (Recipes grid) — no

`ui/component/RecipeCard.kt` is title-only. Comment at lines 45-47:
"the full engagement bar (zap/react/repost) lives on the detail screen."
Zero bookmark / save parameters. iOS `wisp/RecipeCardView.swift` already
matches that ("Title-only — the engagement bar lives on the detail
screen"). **iOS stays detail-only.**

The only card-level recipe bookmark is onboarding
`OnboardingSaveRecipesScreen.kt:160-190`: a filled/border bookmark
overlay, copy **"Saved to My Kitchen"** / **"Save to My Kitchen"**.
That is Concern **3.4**, not the Recipes grid. Do not put it on
`RecipeCardView`.

### Unsave on detail

Same control as save: tap the filled bookmark. **No confirm dialog.**
No AlertDialog, no "Remove from collection?" copy anywhere on this
path. `toggle()` publishes the replaceable list without membership.

---

## 2. Android's picker

**Reached by long-pressing the detail bookmark**
(`Navigation.kt:3338-3340`, `showRecipeListChooser`). Not a toolbar
item, not a Saved-tab action.

File: `ui/component/RecipeListChooserSheet.kt`.

| Question | Android |
|---|---|
| Default list one-tap? | **Yes, but not in the picker.** ActionBar tap is the one-tap default-list toggle. The picker lists the default Saved row as a **checkbox like any other list**. |
| Create collection inline? | **Yes.** "New list" row (`recipe_list_chooser_new`) expands an `OutlinedTextField` ("Collection name") + Cancel / Create. `onCreateList` → `FeedViewModel.createRecipeListAndSave` → `RecipeBookmarkRepository.createList(title, seedEvent)`. **In scope.** |
| No named collections? | If `lists.isEmpty()`: body copy **"No collections yet"** (`recipe_list_chooser_empty`). The **New list** row still renders below the divider. If the user has only the default Saved list, the picker shows that one row (title "Saved" + recipe count). |
| Title | **"Save to collection"** (`recipe_list_chooser_title`) |
| Membership | Multi-select checkboxes. A recipe can sit in several lists at once. Tap row or checkbox → `toggleRecipeInList(dTag, eventId)`. |

Android's picker is **not** `CookbookCollectionCard`. It is a checklist
sheet. iOS 3.2 already documented `CookbookCollectionCard` /
`collectionGrid` as the 3.1b picker seam (`wisp/SavedRecipesView.swift:21-23`,
card comment at 248-249): injected `onTap` / `menu`. Reuse that card
with `menu: nil` and a membership overlay; do **not** write a second
collection list. The "New list" field is an extra control under the
grid, matching Android's divider + create row — not a second list.

That checklist-vs-card visual difference does **not** change scope: same
entry (long-press), same membership toggle, same inline create.

---

## 3. Unsave confirm, and unsave from the Saved tab

**Confirm:** Android does not confirm unsave. iOS must not add a
dialog.

**Saved tab:** unsave is **absent**.

- Saved grid (`RecipeFeedScreen.kt` COOKBOOK / Saved):
  `CookbookCollectionCard` tap → collection detail; overflow is
  rename / description / cover / delete only.
- Collection detail (`Navigation.kt:3611-3640`) reuses
  `RecipePackDetailScreen` — a poster grid. Tap a recipe → recipe
  detail. **No swipe, no context menu, no remove.**
- iOS `RecipeCollectionDetailView` (`SavedRecipesView.swift:329-330`)
  already documents this: "No manage affordances here — management
  lives on the Saved grid cards (Android parity)."

Unsave on iOS is therefore **detail bookmark tap** (and unchecking a
list in the picker). Do not add swipe-to-unsave on the Saved tab.

---

## 4. How Android derives saved state; cold session

**Source of truth:** `RecipeBookmarkRepository.bookmarkedCoordinates`
(`StateFlow`), rebuilt from the in-memory default list in
`publishListsState()` (`RecipeBookmarkRepository.kt:927`).
`isRecipeBookmarked(event)` is `coordinateForEvent` ∈ that set.
Not a separate UI cache. Detail hydrates with
`feedViewModel.loadRecipeBookmarks()` (`paintFromCache` then `load`)
on appear (`Navigation.kt:3199-3200`).

**While still loading (cold session):**

- `paintFromCache` applies on-device kind-30001 events if any.
- If cache is empty, `bookmarkedCoordinates` is empty → icon renders
  **unfilled** until `load()` / a streamed list arrives. Android does
  **not** disable the icon and does **not** show a spinner on it.
- A tap in that window is still safe. `mutateList` (`kt:669-704`)
  ignores the empty memory/cache as "create": it runs
  `confirmListOnRelays`. Found → carry forward; confirmed absent →
  create; **unconfirmed → reject, sign nothing**, emit
  `WRITE_UNCONFIRMED_MESSAGE` ("Couldn't reach your relays to check
  your saved list — nothing was saved. Try again in a moment.") as a
  global Toast (`Navigation.kt:1047-1054`).
- Onboarding comment (`Navigation.kt:4722-4724`) states this
  explicitly: toggles may render before load completes; the write
  mutex + relay check run before any publish.

**Optimistic apply:** after a **successful sign**, Android
`applyLocal` then `sendToWriteRelays` (`kt:696-700`). The icon flips
when the repository set updates — after the guard has passed, not
before. During the confirm wait (up to the confirm timeout) the icon
stays on the last repository read. There is **no pending spinner**.

**iOS tension (report, do not weaken the guard):** this concern
requires a **pending** in-flight state and forbids an optimistic flip
that can lie. That is stricter than Android's icon (no pending) and
matches the guard: wait through `confirmList`, keep showing the last
repository membership (or a pending overlay), never flip to "saved"
on an unconfirmed cold session. `RecipeBookmarkRepository.writeBusy`
is currently private; the UI needs a published `isWriting` (or
equivalent) so pending is a repository fact, not a local guess.
Do **not** bypass `mutateList` / `planMutation`.

**Watch-only / signed-out (match Android, do not invent):**

- Android **READ_ONLY** (`signer == null`): ActionBar bookmark still
  **renders**. `toggle()` returns current membership and signs
  nothing (`kt:415`). **No Toast, no sign-in sheet.** Silent no-op.
- `"Sign in to view your recipes"` (`cookbook_sign_in`) is **only**
  the Saved/Published tab body when `userPubkey.isNullOrBlank()`
  (`RecipeFeedScreen.kt:759-767`). It is **not** the bookmark-tap
  gate.
- iOS has no signed-out-without-keypair state (login always yields a
  `Keypair`; watch-only is the READ_ONLY analogue). That string is
  **not used anywhere on iOS today**. Watch-only tap = same silent
  no-op as Android (`toggle(..., keypair: nil)` already returns
  current membership at `RecipeBookmarkRepository.swift:452`).
- Do **not** route the detail bookmark to a sign-in alert Android
  does not show. The prompt's "sign-in gate copy" maps to the Saved
  tab, which 3.2 already paints for any pubkey (watch-only can
  **view** lists; `canManage` hides the overflow).

**iOS leftover:** `RecipeDetailView.swift:269` hides the **entire**
`ArticleActionBar` for watch-only. Android always shows `ActionBar`
once the recipe event exists. This concern requires the **save
affordance present** for watch-only. Other engagement slots stay as
they are unless showing the bar is the cheapest way to host the
bookmark.

**Current iOS bug this concern closes:** `ArticleActionBar`
(`wisp/ArticleView.swift:510-542`) bookmarks into
`NoteListRepository` / `AddToNoteListSheet` (kind **30003**). Android
explicitly does **not** use that path for recipes
(`Navigation.kt:3335-3336`). Recipe detail must drive
`RecipeBookmarkRepository` (kind **30001**), not the inherited note
bookmark sheet.

**HiddenRecipes:** Android `RecipeBookmarkRepository` does **not**
refuse a hidden coordinate on write. Hide-list drop is render-side
via `RecipeRepository`. This concern still requires iOS to refuse
saving a hidden coordinate at the toggle (stated in the implement
step). That is an iOS-only write guard; say so in the PR. 3.1 already
drops hidden members at `resolvedRecipes`.

---

## 5. Files to create or modify

All new files under `wisp/` or `wispTests/` (self-register). Existing
root files are already in the target. **Zero `project.pbxproj` diff
expected.**

### Create

| File | Why |
|---|---|
| `wisp/RecipeListChooserSheet.swift` | Long-press picker: 3.2 `CookbookCollectionCard` grid (`menu: nil`), Android copy ("Save to collection" / "No collections yet" / "New list"), tap → `toggleRecipeInList`. |
| `wispTests/RecipeSaveToggleTests.swift` | Hermetic: fill state from repository fixtures (present / absent / unconfirmed); save/unsave 30001 shape through 3.1 `mutateList`/`toggle`; cold-session guard through the UI/controller path; hidden coordinate refused. |
| `wispTests/RecipeSaveToggleLiveTests.swift` | Opt-in VM gate, sentinel `wispTests/.save_toggle_live_enable` (same pattern as `MyKitchenLiveTests`), `RelayDefaults.defaults`, throwaway key, §7.13: save coordinate → list carries it → unsave → gone → kind-5 `e`+`a`+`k` → confirmed gone. Print timings. **Write, do not run here.** 3.1's `RecipeBookmarkLiveTests` already covers cold append/unsave on a **seeded** default list; this gate is the throwaway-recipe round-trip + list delete the prompt named. |

`FINDINGS.md` is this file (stripped before the final PR commit).

### Modify

| File | Why |
|---|---|
| `wisp/RecipeDetailView.swift` | Save toggle for any signed-in user (not author-only). State = `RecipeBookmarkRepository.isRecipeBookmarked` / `bookmarkedCoordinates`. Pending while `isWriting`. Hydrate `paintFromCache` + `load`. Long-press → picker. Watch-only: affordance visible, tap no-op. Surface `lastWriteError` (Android Toast). Do not hide the bookmark with the rest of the watch-only action bar. |
| `wisp/ArticleView.swift` (`ArticleActionBar`) | Inject recipe-bookmark tap / long-press / filled / pending so recipe detail does not open `AddToNoteListSheet`. Articles stay on the 30003 path. |
| `RecipeBookmarkRepository.swift` | Expose `isWriting` for pending UI. Refuse `HiddenRecipes.isHidden(coordinate:)` in `toggle` / `toggleRecipeInList` / `setRecipeInList` / `createList` seed (sign nothing). No guard weakening. |
| `wisp/SavedRecipesView.swift` | Only if the card needs a picker membership cue (checkmark overlay) via an existing injected handler. **No unsave on the Saved tab.** Do not duplicate the grid. |
| `wispTests/RecipeAuthoredFeedTests.swift` | (1) Add a strictly-older `createdAt` recipe fixture after `removeRecipe` (list-side twin: `RecipeCollectionManageTests.swift:296` reapplies at `1_700_000_000` against stamp `1_700_000_001`). (2) **Remove** `authorFeedFilter_comesFromTheFormatSeam` — it only re-asserts `RecipeFormats.authorFeedFilter` already covered in `Nip23RecipeFormatTests`. Replacement that would have failed on pre-3.2 main: assert revival through `ingestAuthored` (reviewer note 4b-i), in the same `removeRecipe` test. |
| `wispTests/RecipeBookmarkRepositoryTests.swift` | Hidden-coordinate write refused (the existing test only covers `resolvedRecipes` drop). |

### Do not touch

- `wisp/RecipeCardView.swift` — Android grid card has no save.
- `project.pbxproj`
- First-save `planMutation` / `confirmList` logic except the HiddenRecipes
  refuse at the public toggle entry.
- Collection rename / cover / delete (3.2).

### Tests the implement step named (mapping)

- Toggle state from repository fixtures (present, absent, unconfirmed) →
  `RecipeSaveToggleTests`
- Save/unsave write the correct 30001 shape through the 3.1 path → same,
  asserting tags (`d`, no `t` on default, `a` coordinates)
- Cold-session guard holds through the UI path → controller/helper calls
  `toggle` against an unconfirmed `Environment`; `signed` stays empty;
  filled state unchanged
- Hidden coordinate refused → repository + UI path
- `#45` follow-ups → `RecipeAuthoredFeedTests.swift` only

---

## Implementation notes (for step 2, not done)

- Pending = last repository membership + in-flight overlay; never
  `bookmarkedCoordinates.insert` before `mutateList` returns.
- `writeUnconfirmedMessage` already matches Android; reuse it.
- Picker create-new is in scope (finding 2).
- Unsave from Saved tab is out of scope (finding 3).
- Card save is out of scope (finding 1).
