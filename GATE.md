# GATE — concern-c-h/onlyfood-compose @ ca2cdcb
Concern C-H: kind-1 composer on the OnlyFood tab (FAB → app-level ComposePresenter,
editor seeded with a visible, removable `#foodstr`; optimistic insert of the
user's own note). Local build only on Seth's MacBook Air; gates run on the
MacinCloud box by hand. This file is frozen at "ready for gates"; results are
recorded in the PR description.

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build` (generic iOS Simulator) and `build-for-testing` (iPhone 17 Pro): green.
- Warnings in touched files identical to origin/main (faca9f7) built on the same
  DerivedData: one pre-existing "reference to captured var 'self'" in
  OnlyFoodFeedViewModel (main line 519, now 574). Zero new.
- pbxproj: no diff. New files: wisp/OnlyFoodCompose.swift,
  wispTests/ComposeSeedTests.swift, wispTests/OnlyFoodComposeTests.swift,
  wispTests/OnlyFoodOwnPublishTests.swift, wispTests/OnlyFoodComposeLiveTests.swift.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout concern-c-h/onlyfood-compose && git pull --ff-only
~/gate.sh
```
Expected: main's failure set exactly (#4 FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
plus the three SafetyTests) and +20 new passes:
ComposeSeedTests (4), OnlyFoodComposeTests (6), OnlyFoodOwnPublishTests (10).
OnlyFoodComposeLiveTests is skipped unless the sentinel below exists.

## Gate 2 — FAB visibility (simulator, by hand)
1. Launch, OnlyFood tab: pencil FAB bottom-right (accessibility id `new-food-post`),
   same spot as the Recipes "+" FAB; shifts up when the mini audio player is showing.
2. Swipe the drawer open from the left edge: FAB gone. Close it: FAB back.
3. Sign in watch-only (npub): no FAB on OnlyFood (nor on Home / Recipes).
4. Tap the FAB: composer opens with `#foodstr` on the first line, a `#foodstr` chip
   above the editor, caret on the third line. Delete the text: chip disappears.

## Gate 3 + 4 — live publish-verify-delete (§7.13, MacinCloud)
Sentinel: `wispTests/.onlyfood_compose_live_enable` (or `ONLYFOOD_COMPOSE_LIVE=1`).
No key file needed — the test mints an ephemeral keypair, never prints it, and
holds it until the kind-5 is accepted and a re-query by id on every relay that
served the note comes back empty. Content marker `iOS C-H OnlyFood live gate <ts>`
is not a recipe d-tag and is on no hide list.
```sh
cd /Users/user301940/Development/zapcooking_ios
touch wispTests/.onlyfood_compose_live_enable
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/OnlyFoodComposeLiveTests \
  2>&1 | tee ~/c-h-live.log | grep -E "OnlyFoodCompose live:|Test Suite|passed|failed|error:"
rm wispTests/.onlyfood_compose_live_enable
```
Expected lines in ~/c-h-live.log:
- `publishAccepted=[...]` non-empty (gate 3).
- No failure on "defaults did not echo the note through the OnlyFood #t filter";
  the echo passes `FoodHashtags.hasFoodTag` and `OnlyFoodFilter.live().decideKind1 == .accept`
  (gate 4: the note is exactly what the feed's REQ + accept chain admits).
- `searchRelayIndexedAfter=<s>` or `NOT_WITHIN_<n>s` — finding, not assertion. In-app
  visibility does not depend on it: the optimistic insert paints the note
  immediately, and after a relaunch the Global cache paint seeds from the
  EventStore row PostPublisher persisted. If the archive has not indexed it, the
  note is absent from a *cold-install* Global until it does; record the number.
- `deleteAccepted=[...]` non-empty and no "still served after delete" failure.
  A hang or runner death before that line is a leak: the key is gone with the
  process. Do not add a hide-list prefix; report the id from `id=` instead.

## Gate 5 — pbxproj
`git diff origin/main --stat -- wisp.xcodeproj` → empty.

## Results
Pending — recorded in the PR description after Seth's run.
