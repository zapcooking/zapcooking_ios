# NIP-22 event-rooted comments — profile Replies tab (Android + Web spec)

iOS reference: zapcooking/zapcooking_ios#174 (branch `fix/nip22-profile-replies-tab`;
(files: `wisp/Nip22.swift` → `isEventRootedComment`, `ProfileViewModel.swift`,
`wispTests/ProfileRepliesTabTests.swift`). This doc is the handoff for porting
the same fix to `zapcooking/zap_cooking_android` and `zapcooking/frontend`.

## The problem this fixes

A user's profile has a **Replies** tab (kind-1 notes with a threading `e` tag)
and a **Comments** tab (NIP-22 kind 1111 on *external* items — `I` root, web
pages/podcasts). A kind-1111 comment made **inside a nostr thread** — the
mixed-thread case, where a conversation starts as kind-1 NIP-10 and someone's
client (Ditto is the common one) replies with a comment — fits neither:

- Replies tab queries/accepts kind 1 only.
- Comments tab lists only externally-rooted comments.

So event-rooted comments (`E` = root note, `e` = immediate parent) are
**invisible on the author's profile** — no list shows them anywhere. This is
the profile-surface sibling of the thread-subscription gap already fixed per
`ANDROID_PORT_NIP22_THREADS.md` / `WEB_PORT_NIP22_THREADS.md`: there the root
rode in the uppercase `E` that a `#e` filter can't see; here the whole kind is
missing from the tab's query and classifier.

## The predicate (the one decision that matters)

> An event-rooted comment is a **kind 1111 whose root scope tag is `E` or `A`**.

iOS helper (`Nip22.isEventRootedComment`):

```swift
static func isEventRootedComment(_ event: NostrEvent) -> Bool {
    guard isComment(event) else { return false }
    return event.tags.contains { tag in
        tag.count >= 2 && (tag[0] == "E" || tag[0] == "A") && !tag[1].isEmpty
    }
}
```

**Do NOT test for "has a lowercase `e` tag"**: a nested comment on a *web
page* also carries a lowercase `e` (pointing at its parent comment) — that
would leak external comments into the Replies tab. The root-scope tag is the
only discriminator. Case matters (`E` ≠ `e`).

Tab split after the fix:

| comment shape | root tag | profile tab |
| --- | --- | --- |
| comment on a note / in a mixed thread | `E` | **Replies** |
| comment on an article / addressable | `A` | **Replies** (iOS parity — see notes) |
| comment on a web page / podcast / ISBN | `I` | Comments (unchanged) |
| no root tag at all (malformed) | — | neither (unthreadable) |

## Android port — `zapcooking/zap_cooking_android`

All anchors verified in `UserProfileViewModel.kt`. The good news: the shared
posts subscription (`loadProfile`, `postsFilter`) **already fetches kind
1111** — only classification and pagination drop it.

1. **Classification** — in the `Nip22.KIND_COMMENT ->` branch of the shared
   subscription collector, event-rooted comments currently fall through
   silently (only `externalRoot(event) != null` and recipe/article
   `A`-roots reach `_comments`). Route comments whose root is an event to
   `_replies` instead: append + sort by `created_at` descending + update
   `oldestReplyTimestamp`, mirroring the kind-1 reply path.
2. **Helper** — add `fun isEventRootedComment(event: NostrEvent): Boolean`
   beside `eventRoot` in `nostr/Nip22.kt` (the sealed `EventRootRef.ById` /
   `.Addressable` already exist; the new predicate is just "root ref is
   ById or Addressable"). Keep one derivation so the classifier and any
   future callers can't disagree.
3. **Pagination** — `loadMoreReplies()` uses
   `Filter(kinds = listOf(1), …)`; add `Nip22.KIND_COMMENT`.
4. **Sorted modes** — `setRepliesSortMode` →
   `wss://feeds.nostrarchives.com/profiles/replies/<slug>`: same
   kinds-array update in its filter and accept 1111s in the ingest guard
   (iOS did exactly this; the curated relay treats `kinds` as OR, so it
   degrades to kind-1-only if it doesn't index 1111).
5. **Divergence note** — Android's Comments tab today also lists
   recipe/article-rooted (`A`, kind 30023) comments with a subject card.
   iOS now routes all `E`/`A` roots to Replies (its Comments tab was
   external-only already). Match iOS for parity (`E`/`A` → Replies) and
   accept losing the subject card there, or keep 30023-roots in Comments —
   but then document the split in both codebases. The *required* part of
   this issue is `E`-rooted comments on notes.
6. **Tests** — extend `nostr/Nip22Test.kt` (predicate: `E`-root in,
   nested-external-with-`e` out, unscoped out, kind-1-with-`E` out) and add
   a classifier test in `Nip22RealThreadTest.kt` using the existing
   `sidecar-thread.json` fixture chain: every comment in it is `E`-rooted
   on a kind-1 note and must land in the replies list, not comments.

## Web port — `zapcooking/frontend`

Mirror of `WEB_PORT_NIP22_THREADS.md` §1 for the profile screen:

1. The profile replies query is author-scoped and kind-1-only today —
   add 1111 to the kinds array (`{ kinds: [1, 1111], authors: [pubkey] }`);
   no sibling-filter trick needed here because the query is by author, not
   by thread tag.
2. Classify with the same predicate: root tag `E`/`A` → replies list,
   `I` → comments list. Watch the trap from §"predicate": nested external
   comments carry a lowercase `e`.
3. Rendering needs nothing new if the thread view already re-roots on `E`
   (per WEB_PORT doc §3): a tapped comment opens its conversation, and the
   card's "replying to" reads the lowercase `e`/`p` tags.
4. Tests: port `ProfileRepliesTabTests` shape — mixed-thread comment in,
   external comment out, someone else's comment out, unscoped out.

## Manual verification (any platform)

1. Live data: `nak req '{"kinds":[1111],"authors":["<pubkey>"]}' <relay>`
   for an account that replies with Ditto (their profile rows read
   `KIND 1111 · COMMENT` + "Posted via Ditto" once landed).
2. Open that profile → Replies tab: the 1111 replies must be listed
   interleaved with kind-1 replies, newest first.
3. Tap one: the thread opens re-rooted on the comment's `E` anchor with
   the whole branch rendered (the already-ported mixed-thread read path).
4. Comments tab must NOT gain event-rooted entries, and the Replies tab
   must NOT gain web-page comments (the lowercase-`e` trap).
