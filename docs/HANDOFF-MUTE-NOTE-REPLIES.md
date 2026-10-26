# Handoff: Mute Note & Replies + Mute Sweep — local build & test

Branch: `fix/mute-parity-sweep` (zapcooking/zapcooking_ios, commit `9ce8041`, based on `main` @ `0eafc5e`)
No PR yet — this is a local-testing handoff per Daniel. Build on your Mac, verify, then we PR.

## What's in it

Two related fixes in one branch, both mute:

1. **Thread mutes were a no-op on screen.** `muteThread` only updated the
   snapshot; every already-rendered row stayed visible until a refresh.
   New `sweepMutedThread` fires `ContentHide.broadcast(eventIds:)` the moment
   any mute lands, so every surface that drops blocked content drops muted
   content through the same door, instantly.

2. **Note-and-replies mute (Sidecar model).** New "Mute Note & Replies"
   overflow item on any non-root note: hides that note, its direct replies,
   and quotes of it, without muting the whole thread. Serialized as private
   `e` entries in the same NIP-51 kind-10000 list, deduped against thread
   ids, carried through republish/relay-sync/recovery.

## Files touched

- `MuteRepository.swift` — `mutedNotes` set, `muteNoteAndReplies` /
  `unmuteNoteAndReplies` / `isNoteMuted` / `isNoteAndRepliesMuted`,
  `sweepMutedThread` (async Task over `EventStore.allKind1`, then
  `ContentHide.broadcast`), notes through `apply`/`republish`/
  `adoptRecovered`/`commitChange`/`load`.
- `EventStore.swift` — new `allKind1(limit:)`: cached kind-1 + kind-22.
- `SafetyFilter.swift` — snapshot carries `mutedNotes`; `shouldDrop` matches
  note id / thread root / reply parent / quoted `q` tag in
  feed+notifications contexts only. Inside a thread nothing is dropped so
  the muted note stays visible where the mute was applied (matches web).
- `Nip51Mute.swift` — `Lists.notes`, serialization, `buildSignedMuteEvent`
  accepts `mutedNotes` (WIP commit `8f2b55f` had most of this already).
- `PostCardView.swift` — overflow menu item, skipped on the thread root.

## Build

Xcode, wisp scheme, iOS destination as usual. Nothing added to the
project file — all changes are in existing targets. No new files.

## Test checklist

**A. Thread mute sweep (the no-op fix)**
1. Open feed, let some thread rows render.
2. Overflow menu on a reply (not root) → "Mute Thread".
3. Expect: the whole thread disappears from the feed immediately, no
   pull-to-refresh. Undo via Settings mute list or unmute in menu; rows
   come back on next load (sweep is one-way by design — same as block).

**B. Note & replies mute**
1. Find a thread with a mid-chain reply (a reply to a reply visible in feed).
2. Overflow on the mid-chain note → "Mute Note & Replies" (item should NOT
   appear on a thread root — root keeps only "Mute Thread").
3. Expect: that note, its replies, and quotes of it vanish from feed +
   notifications immediately. The parent thread stays.
4. Open the parent thread: the muted note is still visible inside the
   thread (deliberate — you can undo where you applied it). Check "Unmute
   Note & Replies" shows in the menu there and works.

**C. Persistence + sync**
1. Kill and relaunch the app: note mutes survive (UserDefaults
   `muted_notes_<pk>`).
2. Mute on device A, confirm the kind-10000 republish carries the new
   private `e` entries; device B (or a relay inspection) picks them up via
   sync without clobbering threads/words/blocks.

**D. Regression**
- Block user, report note, word mute still work as before.
- Thread mute on a root from a fresh session still hides the thread in
  feed AND notifications.
- Reposts of a muted author's note still drop (kind-6 inner-author check
  untouched).

## Known limitations (say so in review, don't hide)

- The sweep is fire-and-forget (`Task` in `sweepMutedThread`); there's no
  completion signal. Fine for UI, but tests can't await it directly —
  poll or expose the task if you want deterministic tests.
- Note mutes match direct replies only (root/parent/quote tags). A reply
  to a reply of the muted note is NOT covered — that's what thread mute is
  for. Same semantics as Sidecar.
- Replies rendered inside an open thread are governed by `.thread`
  context, which deliberately ignores mutes — the note stays visible in
  its thread.
