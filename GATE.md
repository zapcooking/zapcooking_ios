# GATE — concern/memories (Memories, "On this day")
Port of Android `MemoriesRepository` / `MemoriesCard` / `MemoriesScreen` /
`MemoriesViewModel`. Read-only — no new event kind, nothing published, so
§7.13's live-write protocol does not apply. Off main at 563e09d (#85).
Local build only on Seth's MacBook Air; gates run on the MacinCloud box by hand.

**Frozen at this commit.** App code is frozen at **c97025b** (8b54a67 plus the
Copilot review fixes: `MemoriesViewModel` serializes load/refresh with a
generation guard and the Refresh button is disabled while busy; the refresh
notice also shows in the empty state; the teaser is mounted in the empty /
fully-filtered general feed and OnlyFood's relayMiss / wotHidden / empty states,
not only inside the two lists). The previous GATE.md (54d443d) is superseded.
This GATE.md is the only commit after c97025b and is the HEAD commit — `gate.sh`
refuses to run otherwise. A review fix re-opens the freeze: push a fresh
GATE.md last.

## What landed
- `wisp/Memories.swift` — pure top-level helpers (`memoryWindows` with the
  Feb 29 → Feb 28 fallback, in the user's time zone; `isMemoryReply`, the
  corrected NIP-10 predicate — case-insensitive `mention`, id-less `e` tags
  ignored; `shouldCacheMemories`; `memoriesLocalDateKey`), `MemoriesStore`
  (`memories_v1_<pubkey>` / `memories_dismissed_<pubkey>`, injected defaults),
  `MemoriesRelay` (`RelayDefaults.defaults` ∪ `nostr.wine`, 2026-09-19 retention
  measurement in the comment; 8s connect + 10/12/14s EOSE + 4s grace; limit 50),
  `MemoriesSubSeq` (process-wide, §7.2; CLOSE only the opened subId, §7.5),
  `MemoriesRepository` (cache-first, refresh, per-day dismissal, in-flight
  coalescing).
- **The cache rule:** cache only when EVERY window resolved via EOSE; an EOSE'd
  empty window is cacheable, a timed-out one is not; a stored partial reads as
  a miss.
- `wisp/MemoriesCard.swift` — teaser under the live rail in BOTH feed bodies via
  `FeedTabRouting.showsMemoriesTeaser` (the OnlyFood inconsistency is deliberate
  and documented there). `wisp/MemoriesView.swift` + `MemoriesViewModel.swift` —
  the full screen, drawer row next to My Polls, presented as a sheet.
- Related issues filed, NOT fixed here: zapcooking_ios #86 (shared NIP-10
  predicates; answers "would the fix make #4 pass" — no) and
  zap_cooking_android #258 (primal is a dead archive slot).

## Local (MacBook Air, Xcode 26.3, -derivedDataPath shared)
- `build-for-testing` (iPhone 17 / OS 26.2, shared DerivedData,
  `-skipPackagePluginValidation`): **green** three times on 2026-09-19 — first
  build green at once; two more to clear Swift 6 isolation warnings in the new
  files. Warnings in touched files (`MainView.swift`, `SidebarDrawerView.swift`,
  `wisp/FeedTabRouting.swift`, the four `Memories*` files, the two test files):
  **zero** at 8b54a67. Free disk 13 → 12 GB across the runs (below the 15 GB
  floor going in; incremental builds only, no DerivedData eviction needed).
- Serial run on the Air (the C-G exception form, `-parallel-testing-enabled NO`,
  `-only-testing:wispTests/MemoriesTests -only-testing:wispTests/MemoriesLiveTests`
  with the enable file touched): **37/37 passed** in 32.6 s at 8b54a67; after the
  review fixes, `build-for-testing` green again at c97025b (zero warnings in
  touched files) and `MemoriesTests` **38/38** serial. The live gate
  (jb55, default author) reported: 1y 2025-09-19 → 2 events EOSE; 2y 2024-09-19
  → 5 events EOSE; 3y 2023-09-19 → 3 events EOSE; total 10, cacheable, 10 s.
- pbxproj: no diff (three-dot). Xcode had the project open and kept re-sorting
  two `FeatureFlags.swift` lines in the working tree; reverted before every
  build and before the commit — the committed tree carries no project change.
- Gate 4 (by hand) is Seth's device pass; the Simulator cannot be driven from a
  Claude session.

## Gate 1 — hermetic, serial (MacinCloud)
```sh
cd /Users/user301940/Development/zapcooking_ios
git fetch origin && git checkout concern/memories && git pull --ff-only
cp ci_scripts/gate.sh ~/gate.sh && chmod +x ~/gate.sh
~/gate.sh concern/memories
```
Expected verdict line: `gate: PASS — failure set is exactly the known set (4/4);
N tests ran on concern/memories @ <this commit>`, with the four known failures
(#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` plus the three
`SafetyTests`, issue #57) and no `NEW` line. `MemoriesLiveTests` is `.enabled(if:)`
off unless the enable file exists, so it does not run here.

**Count.** This branch has **899** `@Test` declarations (`git grep -cE
'^[[:space:]]*@Test' -- 'wispTests/*.swift'`); main (563e09d) has 860; the delta
is **+39** (`MemoriesTests` 38, `MemoriesLiveTests` 1).

## Gate 2 — unit coverage for the four pure helpers
Covered inside Gate 1 by `MemoriesTests`: windows (Jan 1, Dec 31, Feb 29 → Feb 28
in 2023/2022/2021, Feb 28 stays Feb 28, NY vs Tokyo day boundaries), the reply
predicate (root/reply/unmarked/relay-hint/unknown marker → reply; `mention`,
`Mention`, `MENTION`, `q` quotes, bare `["e"]`, `["e", ""]` → not a reply; mention
+ reply → reply; two control assertions pin the shared helper's current wrong
behaviour for #86), the cache rule (all-EOSE cacheable even when empty; any
timeout — including the frozen-3-year case and a timeout WITH events — refused;
empty list refused), the date key (padding, time zone). Plus the store round
trip, stored-partial-as-miss, per-day dismissal, and the repository's gating with
an injected fetch (complete cached → one relay round per day; partial returned
but not cached → re-fetched next open; refresh keeps the cache when not
authoritative; concurrent opens coalesce; subIds unique across instances).

To run only this suite on the box:
```sh
cd /Users/user301940/Development/zapcooking_ios
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/MemoriesTests
```

## Gate 3 — LIVE, read-only (MacinCloud)
No §7.13 protocol: the gate only READs kind-1 history for a public author and
publishes nothing. Default author is jb55 (`32e18276…`, posts most days since
2022). To run it against your own key instead, put your hex pubkey in the
`MEMORIES_LIVE_PUBKEY` variable below (hosted tests do not receive `TEST_RUNNER_`
env, so the enable is the file; the pubkey override IS read from the
environment when present — if it does not reach the process the default author
runs, which still satisfies the gate).
```sh
cd /Users/user301940/Development/zapcooking_ios
touch wispTests/.memories_live_enable
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/MemoriesLiveTests \
  -resultBundlePath ~/memories-live.xcresult 2>&1 | grep -E 'MEMORIES_LIVE|✔|✘'
rm -f wispTests/.memories_live_enable
```
Expected: three `MEMORIES_LIVE window=…` lines, one per window, each with an
`events=N` count and `resolved=EOSE` or `resolved=TIMEOUT`; the test passes when
all three windows are present, at least one resolved via EOSE, and the total
event count is > 0. Report the three lines in the PR. On the Air today: 2 / 5 / 3
events, all EOSE, 10 s.

## Gate 4 — by hand (Seth's device)
1. Sign in with an account that has notes on today's date 1–3 years back (or
   set the device date). Open the feed: the Memories teaser sits under the
   live rail, on OnlyFood and on Follows alike, with "N notes · YYYY, YYYY".
   It is also there when the feed itself is empty (a fresh account with no
   follows, or OnlyFood's "No food posts yet" / relay-miss / WoT-hidden states).
2. Tap the card body → the Memories sheet opens, grouped "1 year ago / 2 years
   ago / 3 years ago" with the date under each; a tap on a note dismisses the
   sheet and pushes the thread on the feed stack.
3. Tap ✕ → the card is replaced by "Memories hidden · Undo" for 5 s, then
   disappears. Switch feed kind and back, background and foreground, kill and
   relaunch: it stays hidden for the rest of the day.
4. Drawer → Memories (next to My Polls) opens the same sheet; Refresh is
   disabled until the first load lands, then re-queries relays and, if a
   window times out, shows "Couldn't refresh — showing cached memories." while
   keeping the list (or in the empty state).
5. Next calendar day the teaser returns.

## Gate 5 — no pbxproj diff (three-dot)
```sh
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Expected: no output. New files are under `wisp/` and `wispTests/` and
self-register.
