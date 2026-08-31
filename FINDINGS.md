# Concern 0.7b — `computeClient` precursor: Step 1 findings

Branch `concern-0.7b/compute-client` @ 28a8d34 (origin/main). Investigation
only; no source edited.

## Headline: the concern's premise is stale — `computeClient` already exists

The scope statement ("`HttpClientFactory.swift` has `generalClient` and
nothing else") does not match main. `HttpClientFactory` has **six** clients
(`imageClient`, `generalClient`, `shortTimeoutClient`, `prefetchClient`,
`mediaPrefetchClient`, `mediaClient`) **and `computeClient` already exists**
at `wisp/HttpClientFactory.swift:122-129` — 75 s request / 75 s resource,
4 connections per host, `.reloadIgnoringLocalCacheData`. It landed in
PR #14 (`e56fabc`, "Phase 0 foundation: relay role sets + ZapCookingApi +
FeatureFlags").

Two gaps remain, and they are the whole of what 0.7b can still deliver:

- **Zero call sites.** `computeClient` is referenced only in a doc comment
  (`wisp/ZapCookingApi.swift:11`); every request path defaults to
  `generalClient` (`ZapCookingApi.post`, line 144). Consistent with this
  concern's "no consumers get wired" — nothing to do here.
- **No tests.** No test file covers `HttpClientFactory` at all.

**Proposed revised Step 2:** tests only — no production change. If that is
not worth a PR, the alternative is closing 0.7b as already satisfied by #14.

## 1. What §2 states

`ZAPCOOKING_IOS_BUILD.md:313-316`: "every AI endpoint needs a
**long-timeout client (~75s)**, not the general 15s one … Build
`HttpClientFactory.computeClient` on day one of the API work." The existing
implementation (75/75) matches the ~75 s figure. No doc correction needed;
the "build … on day one" phrasing is already satisfied.

## 2. What the web frontend actually uses

**No explicit timeout on any Sous Chef or Cheffy call** — they all rely on
the browser's default fetch timeout (~300 s in Chromium):

- Sous Chef import: `fetch('/api/extract-recipe', …)` at
  `src/routes/souschef/+page.svelte:422` — no `signal`, no timeout.
- Cheffy chat: `fetch('/api/zappy', …)` at
  `src/lib/stores/cheffyChat.ts:264` — no `signal`, no timeout.
- Meal plan: `fetch('/api/zappy/meal-plan', …)` at
  `src/lib/mealplan/cheffyPlanClient.ts:64` — no `signal`, no timeout.

Repo-wide, `AbortController`/`AbortSignal.timeout` usage exists only on
unrelated surfaces (NIP-05 checks, link previews, blossom upload, etc.).
The "frontend wins" rule cannot apply — the frontend specifies no value to
win with. §2's ~75 s stands as the only explicit figure, and the shipped
`computeClient` already matches it. **No conflict, no stop condition.**

## 3. How `generalClient` is constructed

`wisp/HttpClientFactory.swift:40-46`: bare `URLSessionConfiguration.default`
+ `timeoutIntervalForRequest = 10`, `timeoutIntervalForResource = 15`,
`httpMaximumConnectionsPerHost = 4`. That is all. **No shared headers, no
custom User-Agent, no NIP-89 tag anywhere in the factory** — `Content-Type`
and `Authorization` are set per-request in `ZapCookingApi`
(`wisp/ZapCookingApi.swift:148,158-160`). The only common configuration
between `generalClient` and `computeClient` is
`httpMaximumConnectionsPerHost = 4`; `computeClient` additionally sets
`requestCachePolicy = .reloadIgnoringLocalCacheData` (sensible for
POST-only AI endpoints, but a divergence a shared-config test should
acknowledge, not flag).

## 4. Existing ad-hoc timeout constructions (reported, not fixed)

None is a workaround for a missing long-timeout client — no AI endpoint
call site exists yet. For the record:

- `RecipePublisher.swift:368-380` — `downloadCapped` builds an ephemeral
  session per call, 20 s (capped remote-image download; matches Android's
  `callTimeout`, deliberate).
- `ExchangeRateService.swift:81` — per-request `timeoutInterval = 15`.
- `ComposeViewModel.swift:739` — per-request `timeoutInterval = 10`.
- `RelayPool.swift:219-221, 672-680` and `GroupRelayPool.swift:189` —
  WebSocket sessions, out of scope for the HTTP factory.

## 5. Test file and pbxproj

No test file exists (`HttpClientFactory` appears nowhere under `wispTests/`
or in `project.pbxproj`). New file: `wispTests/HttpClientFactoryTests.swift`.
**No pbxproj registration is needed**: `wispTests` is a
`PBXFileSystemSynchronizedRootGroup` (`project.pbxproj:697-699`), so files
on disk are picked up automatically. The concern will not touch pbxproj.

## Local-toolchain note: warning baseline on this machine (re-baselined)

The "seven known 'Skipping duplicate build file' warnings" expectation
describes the cloud Mac (Xcode 26.6); it does not hold on this machine
(Xcode 26.3, Build 17C529). A full build of main at 28a8d34 with the
mandatory local command produces **zero** duplicate-build-file warnings and
**538 warning lines** of pre-existing Swift 6 concurrency diagnostics
(main-actor isolation / Sendable) across ~30 files untouched by this branch.

**Rule for this machine going forward:** zero warnings in files the branch
touches, and the total elsewhere unchanged from main. This branch complies:
`HttpClientFactoryTests.swift` compiles with zero diagnostics, and no other
file differs from main.

## Planned tests (on go-ahead)

1. `computeClient` timeouts are 75/75 (the §2-documented values).
2. `computeClient` timeouts differ from `generalClient`'s (10/15).
3. Shared config: both clients use `httpMaximumConnectionsPerHost = 4`
   (the one genuinely common knob), catching future divergence.
