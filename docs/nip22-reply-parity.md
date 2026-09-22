# NIP-22 replies: why we follow Sidecar, not wisp-ios#470

**Decision:** adopt Sidecar's semantics for NIP-22 comments
([dmnyc/sidecar#326]), take upstream [wisp-ios#470]'s inventory of *where* to
touch, and reject #470's publish-side change outright.

Recorded 2026-09-22.

## The problem both PRs address

Kind-1111 was render-only. `ThreadViewModel` showed comments and
`ArticleViewModel` subscribed to them, but every counting and discovery path
asked for kind-1 alone:

| Site | Before |
|---|---|
| `EngagementRepository` REQ | `[1, 6, 7, 9735]` |
| `EngagementRepository` count | only `case 1:` incremented `replies` |
| `EventStore.loadReplyCounts` | `kind == 1` |
| `NotificationsViewModel` own-events / backfill / live | `[1, …]` |

A note with kind-1 replies and kind-1111 comments rendered a low count over a
thread showing all of them.

## The evidence that settled it

Sidecar captured a six-event conversation off public relays on 2026-09-17,
all signatures verified:

```
1. Gatsby  kind 1     thread parent
2. Amelia  kind 1     reply to 1
3. Gatsby  kind 1111  E=1 K=1, e=2 k=1      ← the switch
4. Amelia  kind 1111  E=1 K=1, e=3 k=1111
5. Gatsby  kind 1111  E=1 K=1, e=4 k=1111
6. Amelia  kind 1111  E=1 K=1, e=5 k=1111
```

Two things follow, and neither was obvious beforehand.

**Comments rooted on a kind-1 note are ordinary, not theoretical.** Every
comment here keeps `E` = the kind-1 root with `K: 1`. Our `Nip22` helper only
read the external (`I`) form, so events 3-6 were invisible to us — no
accessor existed for the uppercase/lowercase *event* scope at all. Sidecar
also documented that Damus and Wisp both dropped events 3-6 from their thread
views for this conversation.

**The same person can own the root note and a comment deeper down.** Gatsby
owns event 1 and events 3 and 5. Labelling every answer "replied to your
note" is wrong for events 4 and 6, which answered his *comments*.

## Where we follow Sidecar over #470

### 1. Publishing keeps the target kind

#470 makes every reply kind-1 and deletes `Nip22.buildReplyTags`. We keep
building comments.

NIP-22's own worked example titled *"A reply to a comment"* is a **kind
1111** carrying `["k", "1111"]`. A NIP-10 `e` tag cannot express the `E`/`K`
or `I`/`K` root scope, so a kind-1 answer detaches from the root the comment
was anchored to. Sidecar preserves the target kind and labels a forced kind-1
answer to a comment **nonstandard** in its own dev tooling.

This matters more here than upstream: our primary content is recipes, which
are kind 30023, and comments on addressable long-form are 1111 by
spec — `ArticleViewModel` already says so and already subscribes to them.
Adopting #470 would make this the only client in the family emitting kind-1
against its own main content type.

### 2. Labelling follows the immediate parent

`FlatNotificationItem.parentKind` carries the comment's lowercase `k` so the
caption can distinguish "replying to your comment" from "replying to your
note". #470 classifies every comment as a flat reply.

It is a field, not a new `NotificationKind`. A comment *is* a reply for
filtering, counting, sounds and haptics; only the wording differs. Adding a
case would have dropped comments out of the replies filter and the effect
table.

The parent kind cannot be recovered later — the parent event may not be in
the cache — so it is read at classification time or not at all.

### 3. The feed exclusion stands

#470 admits 1111 to the feeds, render-gated on "Include replies in feeds".
We do not, because `FeedViewModel.isFeedRenderable` already carries a
deliberate decision:

> NIP-22 comments are deliberately absent here: they surface on the profile
> Comments tab, not the timeline. Matching Jumble and Amethyst, which both
> keep external-content comments out of the feed — a comment on a blog post
> is conversation about that article, not a broadcast to the author's
> followers.

That reasoning is untouched by anything in #470 or Sidecar; Sidecar's scope
is notifications, and it takes no position on timelines. Reversing a
documented product decision is not a side effect a parity port should have,
so `relayFeedKinds` and the follows REQ are unchanged. Counts do not depend
on it — `EngagementRepository` runs its own REQ, which does ask for 1111.

## What we took from #470

The surface inventory. Sidecar is a browser sidepanel whose only surface is
notifications; we also have feed cards, reply counts, search and disk
seeding. #470's list of call sites is the useful half, minus the feed.

## Counting once

Dedup is by event id (`seenEngagementIds.insert(event.id).inserted`) before
any increment. A client that publishes both a kind-1 reply and a kind-1111
comment for the same action still counts twice — they are two signed events,
and we cannot tell that apart from two genuine replies without guessing.
Dedup here is by delivery, not by intent.

## Status of the upstream PR

[wisp-ios#470] is open, unmerged, and states it was never compiled ("no Swift
toolchain on the Linux dev box"). It also deletes ~200 lines of
`ThreadViewModel` that this fork has since diverged on. Nothing was
cherry-picked; the equivalent was written against our code.

[dmnyc/sidecar#326]: https://github.com/dmnyc/sidecar/pull/326
[wisp-ios#470]: https://github.com/barrydeen/wisp-ios/pull/470
