# FINDINGS — Issue #6: subscribe path waits for NIP-42 AUTH (Concern C-B, Phase 1)

Investigated 2026-09-01 on `main` @ `2be233f`. Source read directly; relay behavior
verified against `~/projects/member-relay` @ `3cbb019` (khatru v0.12.0 module source)
and by a **read-only live probe of `wss://pantry.zap.cooking`** (three unauthenticated
REQs, no EVENT/AUTH sent; script in session scratchpad, transcript inlined in §0).
Android reference: `~/projects/zap_cooking_android`.

---

## 0. Headline findings (what changed since the Aug 5 investigation)

**F-1. The doc's central Nourish claim is falsified.** "Pantry requires NIP-42 AUTH
on every read — even kind 1. A READ_ONLY account cannot read Nourish at all"
(`ZAPCOOKING_IOS_BUILD.md:390-391`) is no longer true. member-relay's
`rejectFilterPolicy` now has a public-Nourish carve-out
(`relay/main.go:696-703` — `isPublicNourishFilter`: authors exactly
`[nourishServicePubkey]` AND kinds exactly `[30078]`), recipes (`30023`) are always
readable (`relay/main.go:708-711`), and group metadata / public-group content are
readable unauthenticated (`relay/main.go:714-731`). Live probe of deployed pantry
confirms all three:

```
REQ {authors:[fdd263f6…], kinds:[30078], limit:2}  → EVENT 30078, EVENT 30078, EOSE   (no AUTH demanded)
REQ {kinds:[30023], limit:1}                       → EVENT 30023, EOSE                (no AUTH demanded)
REQ {kinds:[30078], limit:1}   (no authors pin)    → ["AUTH", <challenge>] then
                                                     ["CLOSED","probe1","auth-required: please authenticate"]
```

Consequence: **a correctly-shaped Nourish read needs no AUTH and no key at all** —
including for watch-only accounts. Issue #6 no longer blocks C-F for the basic
Nourish score read. It still blocks: NIP-29 member/private groups on pantry, member
app-data reads (grocery/planner: kind 30078 with `authors=[self]`,
`relay/main.go:749-751` requires the authed pubkey to match), and any future
members-only read.

**F-2. There are two subscribe stacks, and issue #6's four defects live only in one.**
`GroupRelayPool` (NIP-29/scheduler, `GroupRelayPool.swift:9`) has all four defects.
The general stack (`RelayPool` → `RelayConnectionPool` → `RelayConn`,
`RelayPool.swift:22/631/455`) independently handles AUTH and already re-fires REQs
after AUTH (`RelayPool.swift:603-612`) — it shares only a weaker form of defect 3
(marks "authed" on send, ignores the AUTH `OK`). Nourish, as a one-shot read, would
naturally ride `RelayPool.query`, **not** `GroupRelayPool` — the issue text's "Nourish
reads pantry over the same path" is stale.

**F-3. khatru never volunteers the AUTH challenge on connect.** The challenge is
generated per connection (khatru `handlers.go:71-77`) but the `AUTH` frame is only
sent by `RequestAuth` on an `auth-required:` rejection of a REQ or EVENT
(`handlers.go:265-268, 225-227, 313`; `utils.go:15-23`). Probe confirms the frame
order: **AUTH challenge, then CLOSED**, both after our REQ. Therefore
**"wait for AUTH before the first REQ" is impossible against pantry** — the first REQ
is what provokes the challenge. The correct shape (and what Android's
`AuthedRelayReader` does) is: optimistic REQ → on CLOSED auth-required, await AUTH
*acceptance* → replay, bounded. This also means `waitForAuthIfNeeded`'s
"no challenge yet → return immediately" branch (`GroupRelayPool.swift:161`) makes it
a **no-op on every fresh connection** — including `DraftsViewModel.swift:144`'s
existing call.

**F-4. The relay's `OK` for the AUTH event is correlatable but dropped on the floor
on both stacks.** khatru replies `["OK", <authEventId>, true/false]`
(`handlers.go:296-298`). iOS never retains the AUTH event id and never parses that
OK (details §4). This is the root of "set on send". Stop-condition "AUTH OK can't be
correlated" is **not** triggered — the id is right there in the signed event we build.

**F-5. Severity calibration (important for a right-sized fix).** For a *signing
member* account, the current `GroupRelayPool` code usually recovers, with churn:
cold connect and reconnect both go REQ → (AUTH+CLOSED) → sign-on-AUTH-frame →
2s-sleep replay → served (khatru validates in websocket order, so the AUTH sent
while the CLOSED was still queued is processed first). The *silently-empty-forever*
cases are: (a) watch-only / signing failure — no AUTH ever sent, CLOSED→replay→CLOSED
loops forever with no surfaced error; (b) AUTH rejected (`OK false`: clock skew,
relay-URL mismatch vs `ServiceURL`) — client believes it authed, loops forever;
(c) `CLOSED restricted:` (authed non-member) — see F-6. The fix's value is bounded
recovery + an explicit watch-only/failure state, not "reads never worked."

**F-6. New defect found (not in the issue's four): `CLOSED` with a non-auth reason
replays in a hot loop.** `GroupRelayPool.swift:305-318` replays on **every** CLOSED;
`needsAuth` only controls the 2s sleep. A `restricted: membership required`
rejection (member-relay `relay/main.go:754`, and khatru re-CLOSEs every replay)
produces an unbounded REQ/CLOSED ping-pong **with no sleep at all**, at network RTT
rate, forever. A throwaway signing key joined to a pantry group hits exactly this.

---

## 1. The subscribe path today

### Pools and entry points

| Entry point | Location | Transport |
|---|---|---|
| `GroupRelayPool.subscribe(relayUrl:filter:subId:)` | `GroupRelayPool.swift:94-110` | own socket-per-relay (`RelayState`) |
| `RelayPool.subscribe(relays:filter:id:)` | `RelayPool.swift:180-192` | `RelayConnectionPool`/`RelayConn` |
| `RelayPool.subscribe(queries:id:)` (outbox) | `RelayPool.swift:197-210` | same |
| `RelayPool.stream(queries:)` (one-shot) | `RelayPool.swift:136-173` | same |
| `RelayPool.query`/`queryDetailed` (one-shot) | `RelayPool.swift:77-130` | same |

`GroupRelayPool.subscribe` call sites — exactly two:
- `GroupListViewModel.swift:86` (five subs per group: msg/meta/admins/members/react, built at `:74-96`; `ensureRelay` first at `:70`).
- `DraftsViewModel.swift:152` (scheduled posts against `wss://scheduler.nostrarchives.com`, `DraftsViewModel.swift:16`; preceded by the no-op-on-fresh-connect `waitForAuthIfNeeded` at `:144`, then a fixed 10s collect window `:161`).

Other `GroupRelayPool` users (not subscribe): `ComposeViewModel.swift:1261-1262` and
`DraftsViewModel.swift:180-181` (`ensureRelay` + `publishWithAuthRetry`),
`GroupRoomViewModel.swift:116,180` (`publish`), `AppDataWipe.swift:24` (`shutdownAll`).

`RelayPool.subscribe` call sites (blast radius only if `RelayConn` is touched — §6):
`FeedViewModel.swift:865,1190`, `MessagesViewModel.swift:54` (DMs),
`DmConversationViewModel.swift:156`, `NotificationsViewModel.swift:560-618` (5 subs),
`MuteRepository.swift:226`, `ThreadViewModel.swift:968,1119`,
`NwcWallet.swift:138` (**wallet**), `PollTallyRepository.swift:399`,
`EngagementRepository.swift:457`, `ArticleViewModel.swift:109-110`,
`wisp/Live/LiveStreamViewModel.swift:64-74`, `wisp/Live/LiveStreamCoordinator.swift:30-38`.

**Which pool will Nourish go through:** Nourish (3.5) is unbuilt; nothing binds it to
`GroupRelayPool`. As a bounded one-shot read it fits `RelayPool.query`/`queryDetailed`
— and given F-1, that path already works today, unauthenticated, provided the filter
pins `authors=[NOURISH_SERVICE_PUBKEY]` and `kinds=[30078]` **exclusively** (the relay
rejects any broader shape back to auth-gated). Recommendation: 3.5 should use
`RelayPool.queryDetailed` with a relay-side-public filter; issue #6's fix is then for
groups + member app-data, not a Nourish prerequisite.

### `subscribe` → REQ on the wire (GroupRelayPool)

1. `subscribe` requires `relays[relayUrl]` to already exist (`:95-97`); otherwise it
   returns an **already-finished empty stream** — a second silent-empty hazard for
   any caller that forgets `ensureRelay`. (Both current callers call it.)
2. Registers `SubscriptionState` + filter JSON (`:99-102`), then `sendREQ`
   **immediately** (`:103` → `:346-353`) — fire-and-forget `socket.send`, no auth
   consult, no connect-state consult (URLSession queues sends made while connecting;
   if `state.socket` is nil the payload is **silently dropped**, `:351`).

### Every write to `isAuthenticated` (GroupRelayPool)

| Line | Value | Trigger |
|---|---|---|
| `GroupRelayPool.swift:187` | `false` | `connect()` (fresh or reconnect) |
| `GroupRelayPool.swift:215` | `false` | `tearDown()` (release/shutdown) |
| `GroupRelayPool.swift:235` | `false` | `scheduleReconnect()` |
| `GroupRelayPool.swift:336` | `true` | `authenticate()` — immediately after the AUTH frame is **enqueued** (fire-and-forget send; not even send-completion, let alone the relay's `OK`). Also resumes all `authCompletionContinuations`. |

Believed claim confirmed, with one precision fix: for **watch-only** accounts
`authenticate` does *not* bail on the `guard let keypair` (`:330`) — watch-only is
`Keypair(privkey: "", pubkey:)` (`NostrKey.swift:70-76`), which is present in
`state.keypair`. The failure is `Schnorr.sign` throwing on the empty key
(`Nip42.swift:17-18` → `NostrEvent.swift:110` → `Schnorr.swift:7`), caught at
`GroupRelayPool.swift:339-341`. Net effect identical (no AUTH, no error surfaced),
but the doc/issue wording "bails on a missing keypair" is imprecise.

### The CLOSED handler (GroupRelayPool.swift:305-318)

- Detects auth by substring `reason.contains("auth-required")` (`:311`). Does not
  recognize `restricted:` (see F-6) — every CLOSED replays.
- auth-required → unstructured `Task` sleeps a fixed 2s, then `replayREQ` (`:361-365`,
  guarded only on subscription existence — not on socket identity or auth state, so a
  replay can land on a fresh unauthed or dead socket).
- **Replay is not bounded**: khatru re-sends the AUTH challenge and re-CLOSEs on every
  rejected replay (`utils.go:15-23`), so a never-succeeding AUTH is an infinite
  2s-period loop; a `restricted:` rejection is an infinite zero-delay loop.

## 2. The write path (which works)

- `GroupRelayPool.publishWithAuthRetry` (`:141-153`): `waitForAuthIfNeeded(5s)` →
  `publish(10s)` → on `.authRequired` wait again and retry once (bounded: 1 retry).
- `publish` (`:119-137`) awaits **the relay's `OK` for the published event**,
  correlated via `pendingPublishes[event.id]` (`:123`, resolved in the OK handler
  `:280-298`), with a real timeout task. This per-event-id OK correlation is exactly
  the machinery the AUTH `OK` needs and doesn't have.
- `waitForAuthIfNeeded` (`:158-173`): returns immediately if `isAuthenticated`
  (set-on-send, so lies) **or if no challenge has arrived** (`:161`) — per F-3 that
  makes it a no-op on every fresh khatru connection. The write path actually works
  because `publish` observes the per-event `OK false auth-required` *after* the
  challenge exchange has been provoked, then retries — not because the wait works.
- Reusable by reads? The awaiting primitive (`authCompletionContinuations` +
  `awaitAuth`, `:175-180`) is read-usable as-is and embeds no write-only assumptions
  — but it resumes on *send*, inheriting defect 3. Fixing when it resumes (on `OK`)
  fixes both paths at once. The `RelayPool.publish` one-shot AUTH dance
  (`RelayPool.swift:255-289`) is per-event/ephemeral-socket and not reusable.

## 3. Reconnect (GroupRelayPool)

Torn down vs. survives on a drop (`scheduleReconnect`, `:228-243`): socket/session
destroyed; `isAuthenticated`/`lastChallenge` cleared (good — Android's stale-flag bug
is not present); `subscriptions` and `subscriptionFilters` **survive** (streams stay
open); `pendingPublishes` survive (die by their own timeouts). Backoff 2^n capped 30s.
Full `tearDown` (`:209-226`, release/logout only) finishes every stream and resumes
all auth waiters unconditionally — note a watch-only caller awaiting auth is resumed
*successfully-looking* here; nothing distinguishes "authed" from "gave up".

Actual reconnect order (`connect`, `:184-207`):

```
socket created + resume()                        :189-193
  └─ REQ replay for EVERY filter (synchronous)   :196-198   ← before reader exists
reader task started                              :200-204
  └─ relay: ["AUTH", challenge] then ["CLOSED", subId, "auth-required…"] per sub
       ├─ AUTH frame  → sign + send + isAuthenticated=true (on send)   :329-342
       └─ CLOSED      → unstructured Task: sleep 2s → replayREQ        :305-318
            └─ khatru processed our AUTH in-order first ⇒ replay served
               (unless OK was false ⇒ loop forever, F-5b)
```

So defect 4 confirmed: **filter replay always precedes AUTH** by construction — but
note khatru *cannot* challenge before a REQ (F-3), so the fix is not "AUTH first,
then REQ" literally; it is "REQ may provoke; replay only after AUTH acceptance."

Races: all mutations are actor-isolated (no data race), but the CLOSED replay
`Task` (`:312`) is unstructured and can interleave with a concurrent reconnect —
firing a replay onto a fresh unauthed socket (converges only via relay re-challenge)
or a nil socket (silently dropped, `:351`), and can duplicate `connect()`'s own
replay of the same subId. On `RelayConn` the equivalent ordering is: fresh socket →
replay all REQs (`RelayPool.swift:537`) → AUTH frame → sign/send → replay all REQs
again (`:611`); serial receive loop, no task race; CLOSED auth-required is ignored
(sub kept, `:590-597`) — which works against khatru's AUTH-before-CLOSED frame order,
observed in the probe.

One extra note: `ensureRelay` refreshes `state.keypair` (`:64`) but an already-open
socket keeps its relay-side authed pubkey; on account switch, if the pool is not
`shutdownAll`'d, subsequent activity rides the *old* identity's auth. (Logout wipes
via `AppDataWipe.swift:24`; account-switch path not verified — flagging, not owning.)

## 4. AUTH `OK` handling

- **Not parsed on either stack.** `GroupRelayPool`'s OK handler (`:280-298`) only
  consults `pendingPublishes` keyed by *published* event id; `authenticate()`
  discards the signed AUTH event after sending, so the id is never retained and the
  relay's `["OK", authEventId, …]` matches nothing and is dropped. `RelayConn`
  ignores OK frames entirely on the sub path (`RelayPool.swift:614-615`), and
  `respondToAuthChallenge` returns send-success (`:61-73`).
- Correlation is straightforward: `Nip42.buildAuthEvent` returns the signed event
  (`Nip42.swift:11-20`) — retain `event.id`, resolve on the matching OK. khatru
  guarantees the OK, true or false (`handlers.go:296-298`). Confirmed root of
  "set on send".

## 5. Android reference

- `collectAuthCompleted` (`GroupListViewModel.kt:121-134`): collects the
  `RelayPool.authCompleted` `SharedFlow` (`RelayPool.kt:244-246`); on an emission for
  a relay hosting joined groups, re-sends all group REQs (`sendGroupReqs`).
- **What it awaits — precision:** Android emits `authCompleted` and adds to
  `authenticatedRelays` immediately after the AUTH event is *sent*
  (`RelayPool.kt:592-595` tier-1, `:608-611` tier-2) — **Android also marks on send,
  not on `OK`**. Issue #6's "do not mark authed until accepted" goes beyond the
  Android reference; it's still the right call (khatru OKs the auth event, and
  `OK false` is the invisible failure mode), but the report should not claim Android
  does it. Android *does* clear `authenticatedRelays` on every disconnect
  (`RelayPool.kt:569,1049,1143,1202,1261`).
- Android's actual pantry-read machinery is `AuthedRelayReader`
  (`relay/AuthedRelayReader.kt`): bounded loop (`maxAttempts=3`) of
  await-connected → REQ → race(EOSE | CLOSED-auth | timeout); on auth-CLOSED, poll
  `isAuthenticated` up to 8s then retry the REQ; on timeout, retry only if
  `reconnectGeneration` changed. Note `isAuthRequired` treats **`restricted`** the
  same as `auth-required` (`:121-123`).
- **Watch-only on Android:** no signer registered → `collectAuthChallenges` drops the
  challenge (`RelayPool.kt:580` — `authSigner ?: return@collect`); relay-layer result
  is the same silent empty as iOS. Android avoids the UX hole one layer up by gating
  Nourish/publish/NIP-98 features on "account has a signing key" (doc Gate 0-D).

## 6. Blast radius

Direct (consumers of `GroupRelayPool.subscribe` — affected by the fix):

| Consumer | Effect of subscribe-awaits-AUTH | Immediate-REQ reliance |
|---|---|---|
| `GroupListViewModel.swift:86` (NIP-29 groups) | Intended beneficiary. No spinner keyed on first event found — stream-fed UI. **Caveat:** public groups are readable *without* auth (`relay/main.go:719-731`), so watch-only must NOT be pre-emptively refused by account type; `.authUnavailable` may only surface when the relay actually auth-gates the filter. | none |
| `DraftsViewModel.swift:143-162` (scheduled posts) | Has a **fixed 10s collect window** after subscribe; an unbounded await inside `subscribe` would silently eat the window. The await must be bounded and the existing `waitForAuthIfNeeded` call at `:144` (currently a no-op, F-3) should become meaningful or be removed. | fixed-window collect |
| `GroupRoomViewModel`, `ComposeViewModel` | publish-only (`publishWithAuthRetry`) — untouched; benefits indirectly from a truthful `isAuthenticated`. | — |

Indirect (only if the fix also touches `RelayConn` — **recommend it does not**, this PR):
every `RelayPool.subscribe/query/stream` consumer listed in §1, including
**`NwcWallet.swift:138`** (NWC wallet subscriptions ride `RelayConn`) and the DM
inbox (`MessagesViewModel.swift:54`, NIP-17 relays incl. AUTH-required
`wss://auth.nostr1.com` — currently recovers per the 0-H analysis, verified against
`RelayPool.swift:590-612`). Touching `RelayConn` would put wallet and DM behavior in
scope — brushing two stop conditions. `RelayConn`'s shared send-vs-accept weakness
should be a documented follow-up issue, not part of this diff. The 3.1b/3.2 sessions
(`RecipeBookmarkRepository.swift:398,807`, `NoteListRepository.swift:28`,
`RecipeRepository` queries) are all one-shot `RelayPool.query*` — unaffected.
Spam-filter inputs (`SafetyFilter`/NSpam) consume events post-delivery; no REQ-timing
dependency.

**Confirmed the fix does not need to touch** `SparkWallet` (Spark SDK, no relay
pool), the zap/NIP-57 path (`ZapSender` uses one-shot `RelayPool.publish`), `Nip98`
(HTTP), or `RecipePublisher` (publish path; its pantry mirror is 30023, which
pantry's write gate exempts from AUTH — `relay/main.go:487-515`, and
`RecipePublisher.swift:68-70` documents it). No stop condition triggered.

## 7. Proposed design (proposal only — nothing implemented)

Per-relay auth state machine (replaces `isAuthenticated: Bool` + `lastChallenge`):

```
                 ┌── socket opens ──────────────────────────────┐
 disconnected ──►│ connected(unauthed)                          │
                 │   │  AUTH challenge frame                    │
                 │   ▼                                          │
                 │ challenged ── sign+send, retain authEventId ─► authPending(id)
                 │   │ sign throws (watch-only/bad key)         │   │ OK(id,true)   ▼
                 │   ▼                                          │   ▼          authenticated
                 │ authUnavailable (terminal per connection)    │ OK(id,false) → authFailed(reason)
                 └── any disconnect → disconnected (clear challenge, id, state) ──┘
```

- **`isAuthenticated` ⇒ `.authenticated`, flipped only on `OK(authEventId, true)`.**
  `authenticate()` retains the AUTH event id; the OK handler resolves it (reusing the
  `pendingPublishes`-style correlation). Auth waiters resume on `authenticated`,
  `authFailed`, or `authUnavailable` — with a *distinguishable* outcome, unlike
  today's `tearDown` blanket resume.
- **`subscribe` stays optimistic** (F-3: the REQ provokes the challenge) but becomes
  outcome-aware: on `CLOSED auth-required` → if `authUnavailable`, finish the stream
  with an explicit `.authUnavailable`; else await auth completion (event-driven on
  the OK, bounded ~10s), then replay — **bounded total replays (3, matching
  Android's `maxAttempts`), no fixed 2s sleep**. `CLOSED restricted:*` → surface
  `.closed(reason)`, **never replay** (fixes F-6). Relays that never challenge
  behave exactly as today.
- **Reconnect:** `connect()` no longer replays filters unconditionally before the
  reader exists. Order: open socket → start reader → send REQs (provokes challenge
  where needed) → on `OK(auth, true)` replay all filters once. The post-OK replay is
  the recovery mechanism and is ordered after acceptance on the actor — no race with
  the CLOSED path because CLOSED no longer self-replays on a timer.
- **Surface / watch-only hook:** `subscribe` returns a stream of a small enum
  (working name `GroupSubEvent`: `.event(NostrEvent)`, terminal
  `.authUnavailable`, terminal `.closed(reason)`) — or equivalently
  `AsyncStream<NostrEvent>` plus a completion reason; exact shape amendable. The
  classification mirrors `RecipeSaveGate` (`wisp/BookmarkActionTarget.swift:24`):
  the pool reports transport truth; the feature layer maps `.authUnavailable` to the
  established `.needsKey` toast pattern (`RecipeSaveActions.needsKeyMessage` family)
  rather than inventing a parallel watch-only state. Determination is **by relay
  response, not by account type** (public groups must keep working watch-only). This
  is the hook for Gate 0-D and for any future members-only read; basic Nourish reads
  don't need it (F-1).

### Tests

Hermetic (require a transport seam — `GroupRelayPool` currently hardwires
`URLSession`; injecting a socket protocol is Phase 2 work, `#require` throughout):

1. `authSend_withoutOK_doesNotAuthenticate` — pre-fix fails: flag is true at `:336`
   before any OK.
2. `authOKFalse_yieldsAuthFailed_andStopsReplaying` — pre-fix fails: OK false is
   ignored; replay loops.
3. `closedAuthRequired_awaitsAcceptThenReplays_bounded` — pre-fix fails: replay fires
   after a wall-clock 2s regardless of auth state, unboundedly.
4. `closedRestricted_neverReplays_surfacesReason` — pre-fix fails: hot replay loop
   (F-6).
5. `reconnect_replaysFiltersOnlyAfterAuthOK` — pre-fix fails: `connect()` replays at
   `:196-198` before the reader exists.
6. `watchOnly_authGatedSub_yieldsAuthUnavailable` — pre-fix fails: stream stays open
   and silently empty.
7. `watchOnly_publicFilter_stillDelivers` — guards against the wrong fix (pre-emptive
   refusal by account type); passes pre-fix, must still pass post-fix.

Live gates (cloud VM, sentinel-file pattern, I write / VM runs):
- Throwaway signing key vs `wss://pantry.zap.cooking` member-gated filter → sequence
  logged REQ → AUTH → OK(true) → replay → `CLOSED restricted` → explicit terminal
  state, ≤3 replays. (A throwaway key *can* AUTH; it fails on membership — the
  explicit-state assertion is on `restricted`, and `.authUnavailable` is exercised by
  the watch-only variant with no key material at all.)
- Member key → subscribe delivers events; challenge → AUTH → OK → replay-REQ sequence
  in the log. **Member key supply:** read at runtime from an env var / VM-local
  keychain item named in the sentinel shell block Seth writes; the test skips (not
  fails) when unset; never in the repo, never in `GATE.md`.
- Socket killed mid-subscription → reconnect log matches the §7 ordering.
- Each live gate would fail pre-fix on: unbounded replays (1), missing post-OK replay
  ordering (2, 3), no explicit terminal state (1).

### Doc corrections Phase 2 owes (`ZAPCOOKING_IOS_BUILD.md`)

- `:390-391` and `:1156-1157`: pantry no longer AUTH-gates public-Nourish or recipe
  reads (member-relay `feat/open-writes` + `isPublicNourishFilter`; probe-verified).
  Issue #6 is a member-content/groups prerequisite, not a Nourish-read blocker.
- §7.1: "authenticate bails on a missing keypair" → actually present-but-empty
  privkey; the sign throws (`:339`). Same effect, different mechanism.
- §5 Android reference: `collectAuthCompleted` re-fires on AUTH **send**, not accept
  — "mark on OK" is an iOS improvement over Android, not a port.
- `:249` inherited-capabilities row still oversells "NIP-42 with auth-required
  retry" (writes only — §7.1 already says so; the table row should cross-reference).

---

**Stop-condition review:** none triggered. No wallet/zap/NIP-98/publisher change
needed (recommended scope excludes `RelayConn`); the two subscribe paths are now
mapped and Nourish's is clear (`RelayPool.query`, public filter); the AUTH OK is
correlatable by event id; DM behavior is untouched; no pbxproj involvement
(all edits in existing root files + new tests under `wispTests/`).

**Open question for go-ahead (doesn't block):** should `RelayConn`'s send-vs-accept
weakness become its own tracked issue now, so the PR description can point at it?
